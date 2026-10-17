import Darwin
import Foundation

/// 정리 후보 하나.
public struct CleanupCandidate: Sendable, Identifiable {
    public enum Group: Sendable, Hashable {
        /// 프로젝트 폴더 안의 산출물. `root`는 가장 가까운 git 저장소이고, 저장소가 없으면 산출물의 부모 디렉터리다.
        case project(root: String, isGitRepository: Bool)
        /// 위치 규칙으로 찾은 전역 캐시. 도구 이름으로 묶는다.
        case tool(String)
    }

    public let node: DirectoryNode
    public let path: String
    /// 이 후보를 찾은 스캔의 볼륨 장치 번호. 지우기 직전에 같은 디렉터리인지 확인할 때 쓴다.
    public let device: Int32
    public let rule: CleanupRule
    public let group: Group
    /// 보통 규칙의 등급이다. git이 추적하는 파일이 들어 있으면 `GitTrackedFilter`가 `.review`로 내린다.
    public internal(set) var grade: CleanupGrade
    /// 후보로 본 근거. 예: "옆에 package.json"
    public let evidence: String
    /// 원본 Xcode 프로젝트·워크스페이스 경로. `rule.linksWorkspace`이고 기록이 남아 있을 때만 있다.
    public let workspacePath: String?
    /// 원본 프로젝트·워크스페이스가 더 이상 없다.
    public let isWorkspaceMissing: Bool
    /// 이 디렉터리 안에서 git이 추적하는 파일 수. `GitTrackedFilter`를 거쳐야 채워진다.
    public internal(set) var trackedFileCount = 0

    public var id: String { path }
    public var bytes: Int64 { node.totalBytes }
    public var unsharedBytes: Int64 { node.totalUnsharedBytes }
}

/// 이름은 규칙과 맞았지만 후보에서 뺀 디렉터리.
public struct RejectedMatch: Sendable {
    public enum Reason: Sendable, Equatable {
        /// 규칙이 요구하는 마커가 없다.
        case missingMarker
        /// macOS가 관리하는 항목이다.
        case systemManaged
    }

    public let node: DirectoryNode
    public let path: String
    public let reason: Reason
}

public struct CleanupReport: Sendable {
    /// 등급 순, 같은 등급에서는 큰 것부터.
    public internal(set) var candidates: [CleanupCandidate]
    /// 큰 것부터.
    public internal(set) var rejected: [RejectedMatch]

    init(candidates: [CleanupCandidate], rejected: [RejectedMatch]) {
        self.candidates = candidates.sorted {
            $0.grade != $1.grade ? $0.grade < $1.grade : $0.bytes > $1.bytes
        }
        self.rejected = rejected.sorted { $0.node.totalBytes > $1.node.totalBytes }
    }

    /// 여러 스캔에서 나온 보고서를 하나로 합친다. 같은 경로가 겹치면 먼저 나온 것을 남긴다.
    public init(merging reports: [CleanupReport]) {
        var seen = Set<String>()
        let candidates = reports.flatMap(\.candidates).filter { seen.insert($0.path).inserted }
        self.init(candidates: candidates, rejected: reports.flatMap(\.rejected))
    }
}

/// 스캔 트리에 규칙을 적용해 정리 후보를 고른다.
///
/// 프로젝트 규칙은 `projectRoots` 아래에서만 적용한다. 홈 전체에 적용하면 `~/.vscode/extensions/*/node_modules`나
/// 전역 npm 패키지처럼 다시 만들 수 없는 설치물까지 후보가 된다. 위치 규칙은 트리 안 어디에 있든 적용한다.
///
/// 스캔 트리에는 작은 파일의 이름이 남지 않으므로, 마커는 이름이 규칙과 맞은 디렉터리에서만 파일 시스템을 직접 확인한다.
public struct CleanupRuleEngine: Sendable {
    public var rules: [CleanupRule]
    public var homeDirectory: String

    public init(rules: [CleanupRule] = .defaults, homeDirectory: String = NSHomeDirectory()) {
        self.rules = rules
        self.homeDirectory = homeDirectory
    }

    public func evaluate(_ scan: ScanResult, projectRoots: [String]) -> CleanupReport {
        var evaluation = Evaluation(engine: self, root: scan.root, device: scan.device)
        evaluation.applyLocationRules()
        for projectRoot in projectRoots {
            evaluation.applyProjectRules(under: projectRoot)
        }
        return evaluation.report()
    }

    /// 위치 규칙의 경로 중 `rootPath` 트리 밖에 있어 따로 스캔해야 하는 곳.
    /// `/var/folders/…/C`나 `/Library/Developer/CoreSimulator/Caches`처럼 홈 밖에 있는 캐시가 여기에 든다.
    public func locationPaths(outside rootPath: String) -> [String] {
        locationPaths(outside: [rootPath])
    }

    /// 위치 규칙의 경로 중 `rootPaths` 어느 트리에도 들지 않는 곳. `excludedPaths` 안에 있는 경로는 뺀다.
    public func locationPaths(outside rootPaths: [String], excludedPaths: Set<String> = []) -> [String] {
        let dataVolume = "/System/Volumes/Data"
        func isWithin(_ path: String, _ folders: some Sequence<String>) -> Bool {
            folders.contains { folder in
                [path, dataVolume + path].contains { $0 == folder || $0.hasPrefix(folder + "/") }
            }
        }
        var paths = Set<String>()
        for rule in rules {
            let path: String
            switch rule.scope {
            case .location(let location), .contentsOf(let location, _), .nestedContentsOf(let location, _):
                path = location.hasPrefix("/") ? location : homeDirectory + "/" + location
            case .project, .projectContents:
                continue
            }
            var info = stat()
            if !isWithin(path, rootPaths), !isWithin(path, excludedPaths),
               lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                paths.insert(path)
            }
        }
        // 다른 경로 안에 든 경로는 바깥 경로를 스캔하면 함께 들어오므로 뺀다.
        return paths.filter { path in !paths.contains { path != $0 && path.hasPrefix($0 + "/") } }.sorted()
    }

    /// `rootPath` 밖에 있는 위치 규칙의 경로만 골라 스캔하고 후보를 찾는다. 프로젝트 규칙은 적용하지 않는다.
    public func evaluateLocations(outside rootPath: String, scanner: DiskScanner) async -> CleanupReport {
        await evaluateLocations(outside: [rootPath], scanner: scanner)
    }

    /// `rootPaths` 밖에 있는 위치 규칙의 경로만 골라 스캔한다. 스캐너가 제외하는 경로(권한이 없는 보호 폴더 등)
    /// 안에 있는 위치는 스캔하지 않는다. 그 안을 읽으면 macOS가 권한 창을 띄울 수 있기 때문이다.
    public func evaluateLocations(
        outside rootPaths: [String],
        scanner: DiskScanner,
        progress: ScanProgress = ScanProgress()
    ) async -> CleanupReport {
        var scanner = scanner
        scanner.options.excludedPaths.formUnion(skippedChildren())
        var reports: [CleanupReport] = []
        for path in locationPaths(outside: rootPaths, excludedPaths: scanner.options.excludedPaths) {
            guard let scan = try? await scanner.scan(path, progress: progress) else { continue }
            reports.append(evaluate(scan, projectRoots: []))
        }
        return CleanupReport(merging: reports)
    }

    /// 후보에서 어차피 빠지는 하위 폴더(`~/Library/Caches/com.apple.*` 등). 이 안을 읽으면 macOS가 권한 확인 창을
    /// 띄우는 곳도 있어서(`com.apple.Music` 등) 위치 스캔에서는 아예 열지 않는다.
    private func skippedChildren() -> Set<String> {
        func absolute(_ location: String) -> String {
            location.hasPrefix("/") ? location : homeDirectory + "/" + location
        }
        // 다른 규칙이 직접 가리키는 경로(예: `/var/folders/…/C/com.apple.dt.Instruments`)는 건너뛰면 안 된다.
        let targets: [String] = rules.compactMap { rule in
            switch rule.scope {
            case .location(let location), .contentsOf(let location, _), .nestedContentsOf(let location, _):
                absolute(location)
            case .project, .projectContents:
                nil
            }
        }
        var paths = Set<String>()
        for rule in rules {
            guard case .contentsOf(let location, let prefixes) = rule.scope, !prefixes.isEmpty else { continue }
            let container = absolute(location)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: container)) ?? []
            for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
                let path = container + "/" + name
                if !targets.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) {
                    paths.insert(path)
                }
            }
        }
        return paths
    }
}

/// 한 번의 평가가 쓰는 상태와 파일 시스템 확인 결과 캐시.
private struct Evaluation {
    /// `/System/Volumes/Data`를 스캔하면 트리 경로가 `/Users/...`가 아니라 이 접두어로 시작한다.
    private static let dataVolume = "/System/Volumes/Data"
    /// 프로젝트가 들어 있지 않은 묶음 디렉터리. 앱 번들 안의 node_modules 같은 것을 건드리지 않게 한다.
    private static let bundleSuffixes = [
        ".app", ".framework", ".xcframework", ".bundle", ".xcarchive",
        ".xcodeproj", ".xcworkspace", ".playground", ".photoslibrary",
    ]

    let engine: CleanupRuleEngine
    let root: DirectoryNode
    let device: Int32
    /// 이름 → 그 이름을 다루는 프로젝트 규칙(규칙 목록 순서).
    private let projectRulesByName: [String: [CleanupRule]]
    private let contentRules: [CleanupRule]
    /// 프로젝트 규칙으로 들어가지 않을 시스템·앱 데이터 위치.
    private let protectedPaths: Set<String>

    private var candidates: [CleanupCandidate] = []
    private var rejected: [RejectedMatch] = []
    /// 이미 후보나 제외 목록에 올랐거나, 위치 규칙이 차지한 노드.
    private var visited: Set<ObjectIdentifier> = []
    private var gitRoots: [String: Bool] = [:]
    private var listings: [String: [String]] = [:]

    init(engine: CleanupRuleEngine, root: DirectoryNode, device: Int32) {
        self.engine = engine
        self.root = root
        self.device = device

        var rulesByName: [String: [CleanupRule]] = [:]
        for rule in engine.rules {
            guard case .project(let names, _) = rule.scope else { continue }
            for name in names {
                rulesByName[name, default: []].append(rule)
            }
        }
        projectRulesByName = rulesByName
        contentRules = engine.rules.filter {
            if case .projectContents = $0.scope { true } else { false }
        }

        let paths = [
            engine.homeDirectory + "/Library", "/Library", "/System", "/Applications",
            "/private", "/usr", "/opt", "/bin", "/sbin", "/Volumes", "/cores",
        ]
        protectedPaths = Set(paths + paths.map { Self.dataVolume + $0 })
    }

    func report() -> CleanupReport {
        CleanupReport(candidates: candidates, rejected: rejected)
    }

    // MARK: - 위치 규칙

    mutating func applyLocationRules() {
        for rule in engine.rules {
            switch rule.scope {
            case .project, .projectContents:
                continue
            case .location(let path):
                guard let (node, nodePath) = locate(absolutePath(path)), node.status == .scanned else { continue }
                guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
                candidates.append(locationCandidate(node, path: nodePath, rule: rule, evidence: "\(displayPath(path)) 위치"))
            case .contentsOf(let path, let skippingPrefixes):
                guard let (container, containerPath) = locate(absolutePath(path)) else { continue }
                visited.insert(ObjectIdentifier(container))
                for child in container.children {
                    guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                    let childPath = Self.join(containerPath, child.name)
                    // macOS가 관리하는 폴더는 스캔에서 아예 빼기도 하므로(.excluded) 상태와 상관없이 제외 목록에 남긴다.
                    if skippingPrefixes.contains(where: { child.name.hasPrefix($0) }) {
                        rejected.append(RejectedMatch(node: child, path: childPath, reason: .systemManaged))
                        continue
                    }
                    guard child.status == .scanned else { continue }
                    let evidence = "\(displayPath(path)) 아래"
                    candidates.append(locationCandidate(child, path: childPath, rule: rule, evidence: evidence))
                }
            case .nestedContentsOf(let path, let names):
                guard let (container, containerPath) = locate(absolutePath(path)) else { continue }
                for owner in container.children where owner.status == .scanned {
                    for child in owner.children where child.status == .scanned && names.contains(child.name) {
                        guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                        let childPath = Self.join(Self.join(containerPath, owner.name), child.name)
                        let evidence = "\(displayPath(path))/\(owner.name) 아래"
                        candidates.append(locationCandidate(child, path: childPath, rule: rule, evidence: evidence))
                    }
                }
            }
        }
    }

    private func locationCandidate(
        _ node: DirectoryNode,
        path: String,
        rule: CleanupRule,
        evidence: String
    ) -> CleanupCandidate {
        var workspacePath: String?
        if rule.linksWorkspace {
            workspacePath = Self.workspacePath(inDerivedData: path)
        }
        return CleanupCandidate(
            node: node,
            path: path,
            device: device,
            rule: rule,
            group: .tool(rule.tool),
            grade: rule.grade,
            evidence: evidence,
            workspacePath: workspacePath,
            isWorkspaceMissing: workspacePath.map { !FileManager.default.fileExists(atPath: $0) } ?? false
        )
    }

    /// Xcode는 DerivedData 하위 폴더마다 `info.plist`에 원본 워크스페이스 경로를 남긴다.
    private static func workspacePath(inDerivedData path: String) -> String? {
        guard
            let data = FileManager.default.contents(atPath: path + "/info.plist"),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["WorkspacePath"] as? String
    }

    // MARK: - 프로젝트 규칙

    mutating func applyProjectRules(under projectRoot: String) {
        guard
            let resolved = Self.realPath(projectRoot),
            let (start, startPath) = locate(resolved)
        else { return }

        var stack = [(node: start, path: startPath)]
        while let (node, path) = stack.popLast() {
            for child in node.children where child.status == .scanned {
                guard !visited.contains(ObjectIdentifier(child)) else { continue }
                let childPath = Self.join(path, child.name)

                // 산출물 이름을 가진 디렉터리는 마커가 없어도 들어가지 않는다. node_modules 안 패키지의
                // package.json 옆 node_modules처럼 의존성 트리 내부가 따로 걸리지 않게 하기 위해서다.
                if let rules = projectRulesByName[child.name] {
                    visited.insert(ObjectIdentifier(child))
                    if let (rule, evidence) = firstMatch(rules, node: child, path: childPath, parentPath: path) {
                        addProjectCandidate(child, path: childPath, rule: rule, evidence: evidence, parentPath: path, projectRoot: startPath)
                    } else {
                        rejected.append(RejectedMatch(node: child, path: childPath, reason: .missingMarker))
                    }
                    continue
                }

                let rulesForContents = contentRules.filter { rule in
                    guard case .projectContents(let required, _) = rule.scope else { return false }
                    return required.allSatisfy { name in child.children.contains { $0.name == name } }
                }
                if let (rule, evidence) = firstMatch(rulesForContents, node: child, path: childPath, parentPath: path) {
                    visited.insert(ObjectIdentifier(child))
                    addProjectCandidate(child, path: childPath, rule: rule, evidence: evidence, parentPath: path, projectRoot: startPath)
                    continue
                }

                if shouldDescend(into: child, path: childPath) {
                    stack.append((child, childPath))
                }
            }
        }
    }

    private mutating func addProjectCandidate(
        _ node: DirectoryNode,
        path: String,
        rule: CleanupRule,
        evidence: String,
        parentPath: String,
        projectRoot: String
    ) {
        candidates.append(CleanupCandidate(
            node: node,
            path: path,
            device: device,
            rule: rule,
            group: projectGroup(forParent: parentPath, within: projectRoot),
            grade: rule.grade,
            evidence: evidence,
            workspacePath: nil,
            isWorkspaceMissing: false
        ))
    }

    private func shouldDescend(into node: DirectoryNode, path: String) -> Bool {
        !node.name.hasPrefix(".")
            && !Self.bundleSuffixes.contains(where: { node.name.hasSuffix($0) })
            && !protectedPaths.contains(path)
    }

    private mutating func firstMatch(
        _ rules: [CleanupRule],
        node: DirectoryNode,
        path: String,
        parentPath: String
    ) -> (CleanupRule, String)? {
        for rule in rules {
            let markers: [CleanupRule.Marker]
            switch rule.scope {
            case .project(_, let projectMarkers), .projectContents(_, let projectMarkers):
                markers = projectMarkers
            case .contentsOf, .location, .nestedContentsOf:
                continue
            }
            if markers.isEmpty {
                return (rule, "이름이 \(node.name)")
            }
            for marker in markers {
                switch marker {
                case .sibling(let name):
                    if Self.exists(Self.join(parentPath, name)) { return (rule, "옆에 \(name)") }
                case .siblingSuffix(let suffix):
                    if let name = listing(of: parentPath).first(where: { $0.hasSuffix(suffix) }) {
                        return (rule, "옆에 \(name)")
                    }
                case .inside(let name):
                    if Self.exists(Self.join(path, name)) { return (rule, "안에 \(name)") }
                }
            }
        }
        return nil
    }

    /// 산출물이 속한 프로젝트. 부모부터 프로젝트 폴더까지 올라가며 가장 가까운 git 저장소를 찾는다.
    private mutating func projectGroup(forParent parentPath: String, within projectRoot: String) -> CleanupCandidate.Group {
        var current = parentPath
        while true {
            if isGitRepository(current) {
                return .project(root: current, isGitRepository: true)
            }
            if current == projectRoot || current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return .project(root: parentPath, isGitRepository: false)
    }

    /// `.git`은 보통 디렉터리지만 서브모듈과 워크트리에서는 파일이다.
    private mutating func isGitRepository(_ path: String) -> Bool {
        if let cached = gitRoots[path] { return cached }
        let result = Self.exists(Self.join(path, ".git"))
        gitRoots[path] = result
        return result
    }

    private mutating func listing(of path: String) -> [String] {
        if let cached = listings[path] { return cached }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        listings[path] = names
        return names
    }

    // MARK: - 경로

    private func absolutePath(_ path: String) -> String {
        path.hasPrefix("/") ? path : Self.join(engine.homeDirectory, path)
    }

    private func displayPath(_ path: String) -> String {
        path.hasPrefix("/") ? path : "~/" + path
    }

    /// 트리 안에서 절대 경로의 노드와, 트리 기준 경로를 찾는다.
    private func locate(_ path: String) -> (DirectoryNode, String)? {
        if let node = root.descendant(atPath: path) {
            return (node, path)
        }
        let dataVolumePath = Self.dataVolume + path
        if let node = root.descendant(atPath: dataVolumePath) {
            return (node, dataVolumePath)
        }
        return nil
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }
}
