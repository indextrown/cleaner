import AppKit
import CleanerCore
import Foundation
import Observation

/// 정리 화면의 섹션. 등급과 같고, 도구에 물어서 찾은 시스템 항목만 따로 모은다.
enum CleanupSection: Int, CaseIterable, Identifiable {
    case buildArtifact
    case cache
    case review
    case system

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .buildArtifact: "빌드 산출물"
        case .cache: "캐시"
        case .review: "판단 필요"
        case .system: "시스템 항목"
        }
    }

    var subtitle: String {
        switch self {
        case .buildArtifact: "다시 빌드하면 생김"
        case .cache: "다시 내려받거나 앱을 실행하면 생김"
        case .review: "지우기 전에 확인이 필요해 기본으로 고르지 않음"
        case .system: "도구 명령으로 정리"
        }
    }

    var systemImage: String {
        switch self {
        case .buildArtifact: "hammer.fill"
        case .cache: "archivebox.fill"
        case .review: "exclamationmark.triangle.fill"
        case .system: "gearshape.2.fill"
        }
    }
}

/// 정리 후보를 찾는 단계. 진행 화면에 차례로 보여 준다.
enum CleanupPhase: Int, CaseIterable {
    case projects
    case locations
    case simulators

    var title: String {
        switch self {
        case .projects: "프로젝트 폴더의 빌드 산출물"
        case .locations: "캐시 위치"
        case .simulators: "시뮬레이터·Homebrew 항목"
        }
    }
}

/// 화면에 보여 줄 정리 항목 하나. 규칙으로 찾은 후보이거나 도구가 알려 준 시스템 항목이다.
struct CleanupEntry: Identifiable {
    let id: String
    let section: CleanupSection
    let groupID: String
    let groupTitle: String
    /// 묶음 옆에 붙는 짧은 표시. 예: "git"
    let groupNote: String?
    /// 프로젝트 묶음이면 그 폴더 경로. 아이콘을 보여 줄 때 쓴다.
    let groupPath: String?
    var title: String
    let detail: String
    /// 지우면 어떻게 되는지. 규칙에 적힌 되살리는 방법이다.
    let restore: String?
    /// 크기가 범위로 보일 때(복제본이 데이터를 공유할 때) 왜 크게 보이는지 설명한다.
    let sizeNote: String?
    let bytes: Int64
    let unsharedBytes: Int64
    /// 이 항목을 쓰는 것으로 보이는 실행 중인 앱 이름.
    let runningApplication: String?
    let candidate: CleanupCandidate?
    let systemItem: SystemItem?

    func deletionTarget(moveToTrash: Bool) -> DeletionTarget? {
        if let candidate { return DeletionTarget(candidate: candidate, moveToTrash: moveToTrash) }
        if let systemItem { return DeletionTarget(systemItem: systemItem) }
        return nil
    }
}

struct CleanupGroup: Identifiable {
    let id: String
    let title: String
    let note: String?
    let path: String?
    let entries: [CleanupEntry]

    var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    var unsharedBytes: Int64 { entries.reduce(0) { $0 + $1.unsharedBytes } }
}

enum SelectionState {
    case none
    case some
    case all
}

@Observable
@MainActor
final class CleanupModel {
    private static let projectRootsKey = "projectRoots"

    /// 프로젝트 규칙(node_modules 등)을 찾을 폴더. 사용자가 고르고, 앱을 다시 켜도 남는다.
    var projectRoots: [String] {
        didSet { UserDefaults.standard.set(projectRoots, forKey: Self.projectRootsKey) }
    }
    private(set) var entries: [CleanupEntry] = []
    private(set) var leftoverAssets: [LeftoverRuntimeAsset] = []
    var selection: Set<CleanupEntry.ID> = []
    var moveToTrash = false

    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var phase = CleanupPhase.projects
    /// 지금 스캔하는 프로젝트 폴더.
    private(set) var phaseDetail = ""
    /// 홈이 있는 데이터 볼륨의 사용량. 찾기와 정리가 끝날 때마다 다시 읽는다.
    private(set) var volume = VolumeUsage(path: NSHomeDirectory())
    private(set) var progress = ExplorerModel.Progress()
    private(set) var hasFullDiskAccess = PrivacyProtection.hasFullDiskAccess
    /// 권한이 없어 건너뛴 프로젝트 폴더.
    private(set) var skippedRoots: [String] = []
    private(set) var isCleaning = false
    var lastActionMessage: String?

    private var scanTask: Task<Void, Never>?

    init() {
        projectRoots = UserDefaults.standard.stringArray(forKey: Self.projectRootsKey) ?? []
    }

    // MARK: - 찾기

    func refresh() {
        scanTask?.cancel()
        isScanning = true
        lastActionMessage = nil
        phase = .projects
        phaseDetail = ""
        progress = ExplorerModel.Progress()
        hasFullDiskAccess = PrivacyProtection.hasFullDiskAccess

        let roots = projectRoots
        let fullDiskAccess = hasFullDiskAccess
        let scanProgress = ScanProgress()
        scanTask = Task {
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    progress = ExplorerModel.Progress(
                        directories: scanProgress.directories,
                        files: scanProgress.files,
                        bytes: scanProgress.bytes,
                        currentPaths: scanProgress.currentPaths
                    )
                }
            }
            defer { poller.cancel() }
            await BackgroundActivity.run("정리 후보 찾기") {
                await find(projectRoots: roots, fullDiskAccess: fullDiskAccess, progress: scanProgress)
            }
            isScanning = false
            hasScanned = true
        }
    }

    func cancel() {
        scanTask?.cancel()
    }

    private func find(projectRoots roots: [String], fullDiskAccess: Bool, progress: ScanProgress) async {
        // 권한 없이 보호 폴더를 읽으면 macOS가 폴더마다 허용 여부를 묻고 답할 때까지 멈춘다.
        let excluded = fullDiskAccess ? [] : PrivacyProtection.protectedPaths()
        let scanner = DiskScanner(options: ScanOptions(excludedPaths: excluded))
        let engine = CleanupRuleEngine()

        var reports: [CleanupReport] = []
        var scannedRoots: [String] = []
        var skipped: [String] = []
        for root in roots {
            guard let resolved = Self.realPath(root) else { continue }
            if excluded.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
                skipped.append(resolved)
                continue
            }
            phase = .projects
            phaseDetail = Self.abbreviate(resolved)
            guard let scan = try? await scanner.scan(resolved, progress: progress) else { continue }
            if Task.isCancelled { return }
            reports.append(await GitTrackedFilter().apply(to: engine.evaluate(scan, projectRoots: [scan.root.name])))
            scannedRoots.append(scan.root.name)
        }

        phase = .locations
        phaseDetail = ""
        reports.append(await engine.evaluateLocations(outside: scannedRoots, scanner: scanner, progress: progress))
        if Task.isCancelled { return }

        phase = .simulators
        let systemItems = await SystemItems.find()
        leftoverAssets = await SimulatorItems.leftoverRuntimeAssets()

        skippedRoots = skipped
        entries = Self.entries(report: CleanupReport(merging: reports), systemItems: systemItems)
        selection = Set(entries.filter(Self.isSelectedByDefault).map(\.id))
        volume = VolumeUsage(path: NSHomeDirectory())
        writeReportIfRequested()
    }

    /// 개발·확인용: 실행 인자 `-cleanupReport <경로>`가 있으면 찾은 결과 요약을 JSON으로 남긴다.
    private func writeReportIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "cleanupReport") else { return }
        var sections: [String: Any] = [:]
        for section in CleanupSection.allCases {
            let members = entries.filter { $0.section == section }
            sections["\(section)"] = [
                "count": members.count,
                "bytes": members.reduce(0) { $0 + $1.bytes },
                "selected": members.filter { selection.contains($0.id) }.count,
                "groups": groups(in: section).count,
            ]
        }
        let report: [String: Any] = [
            "hasFullDiskAccess": hasFullDiskAccess,
            "projectRoots": projectRoots,
            "skippedRoots": skippedRoots,
            "sections": sections,
            "leftoverAssets": leftoverAssets.map { "\($0.platform) \($0.version)" },
            "runningApplicationEntries": entries.compactMap { entry in
                entry.runningApplication.map { "\($0): \(entry.title)" }
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
    }

    private static func isSelectedByDefault(_ entry: CleanupEntry) -> Bool {
        guard entry.runningApplication == nil else { return false }
        switch entry.section {
        case .buildArtifact, .cache: return true
        case .review: return false
        case .system: return entry.systemItem?.grade == .cache
        }
    }

    // MARK: - 화면용 항목

    private static func entries(report: CleanupReport, systemItems: [SystemItem]) -> [CleanupEntry] {
        let runningApplications = NSWorkspace.shared.runningApplications
        // 이미 비어 있는 폴더(0KB)는 지워도 얻는 게 없으므로 보여 주지 않는다.
        var entries = report.candidates.filter { $0.bytes > 0 }.map { candidate in
            let section: CleanupSection = switch candidate.grade {
            case .buildArtifact: .buildArtifact
            case .cache: .cache
            case .review: .review
            }
            var notes: [String] = []
            if candidate.trackedFileCount > 0 {
                notes.append("git이 추적하는 파일 \(candidate.trackedFileCount.formatted())개 포함")
            }
            if let workspace = candidate.workspacePath {
                notes.append("원본 \(abbreviate(workspace))" + (candidate.isWorkspaceMissing ? " (지금은 없음)" : ""))
            }
            let groupID: String
            let groupTitle: String
            let groupNote: String?
            let groupPath: String?
            let title: String
            var detail: String
            switch candidate.group {
            case .project(let root, let isGitRepository):
                groupID = "\(section.rawValue)/project/\(root)"
                groupTitle = abbreviate(root)
                groupNote = isGitRepository ? "git" : nil
                groupPath = root
                title = String(candidate.path.dropFirst(root.count + 1))
                detail = ([candidate.rule.title, candidate.evidence] + notes).joined(separator: " · ")
            case .tool(let name):
                groupID = "\(section.rawValue)/tool/\(name)"
                groupTitle = name
                groupNote = nil
                groupPath = nil
                // 도구 위치 규칙의 근거는 경로 그 자체라서, 경로는 설명 줄에 한 번만 쓴다.
                if case .location = candidate.rule.scope {
                    // 고정 경로 하나를 가리키는 규칙은 폴더 이름(Caches 등)보다 규칙 이름이 뜻을 잘 알려 준다.
                    title = candidate.rule.title
                    detail = ([abbreviate(candidate.path)] + notes).joined(separator: " · ")
                } else if candidate.rule.id == "apps.containerCache", let bundle = containerBundleIdentifier(candidate.path) {
                    // 컨테이너 캐시는 폴더 이름이 모두 Caches라서 앱 이름(없으면 번들 ID)을 제목으로 쓴다.
                    title = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                        .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                        ?? bundle
                    detail = ([candidate.rule.title, abbreviate(candidate.path)] + notes).joined(separator: " · ")
                } else if candidate.rule.id == "apps.updateLeftovers" {
                    // `com.anthropic.claudefordesktop.ShipIt.Jwg7rwX1` → "Claude 업데이트" (설치된 앱이 없으면 번들 ID)
                    let folder = (candidate.path as NSString).lastPathComponent
                    let bundle = folder.components(separatedBy: ".ShipIt").first ?? folder
                    let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                        .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                    title = "\(name ?? bundle) 업데이트"
                    detail = ([candidate.rule.title, abbreviate(candidate.path)] + notes).joined(separator: " · ")
                } else if candidate.rule.id == "claude.projects" {
                    // Claude Code는 프로젝트 경로의 /를 -로 바꾼 이름을 쓴다. 홈 부분은 떼고 보여 준다.
                    let folder = (candidate.path as NSString).lastPathComponent
                    let homePrefix = NSHomeDirectory().replacingOccurrences(of: "/", with: "-") + "-"
                    title = folder.hasPrefix(homePrefix) ? "~/" + folder.dropFirst(homePrefix.count) : folder
                    detail = ([candidate.rule.title, abbreviate(candidate.path)] + notes).joined(separator: " · ")
                } else {
                    let folder = (candidate.path as NSString).lastPathComponent
                    let owner = ((candidate.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                    title = candidate.rule.id == "apps.electronCache" ? "\(owner) · \(folder)" : folder
                    detail = ([candidate.rule.title, abbreviate(candidate.path)] + notes).joined(separator: " · ")
                }
            }
            let deviceCount = simulatorDeviceRules.contains(candidate.rule.id)
                ? simulatorDeviceCount(at: candidate.path) : nil
            if let deviceCount {
                detail += " · 시뮬레이터 \(deviceCount)대"
            }
            return CleanupEntry(
                id: candidate.path,
                section: section,
                groupID: groupID,
                groupTitle: groupTitle,
                groupNote: groupNote,
                groupPath: groupPath,
                title: title,
                detail: detail,
                restore: candidate.rule.restore,
                sizeNote: sizeNote(minimum: candidate.unsharedBytes, maximum: candidate.bytes, deviceCount: deviceCount),
                bytes: candidate.bytes,
                unsharedBytes: candidate.unsharedBytes,
                runningApplication: runningApplication(for: candidate, in: runningApplications),
                candidate: candidate,
                systemItem: nil
            )
        }
        entries += systemItems.map { item in
            CleanupEntry(
                id: item.id,
                section: .system,
                groupID: "\(CleanupSection.system.rawValue)/tool/\(item.tool)",
                groupTitle: item.tool,
                groupNote: nil,
                groupPath: nil,
                title: item.title,
                detail: item.detail,
                restore: nil,
                sizeNote: nil,
                bytes: item.bytes,
                unsharedBytes: item.bytes,
                runningApplication: nil,
                candidate: nil,
                systemItem: item
            )
        }
        return distinguishingDuplicateTitles(entries)
    }

    /// `~/Library/Containers/<번들 ID>/Data/Library/Caches` → 번들 ID
    private static func containerBundleIdentifier(_ path: String) -> String? {
        let components = path.split(separator: "/")
        guard let index = components.lastIndex(of: "Containers"), index + 1 < components.count else { return nil }
        return String(components[index + 1])
    }

    /// 시뮬레이터 기기 묶음(device set)을 가리키는 규칙.
    private static let simulatorDeviceRules: Set<String> = [
        "xcode.testDevices", "xcode.previews", "xcode.ibSupport", "xcode.playgroundDevices",
    ]

    /// device set 안의 시뮬레이터 수. 기기 폴더는 바로 아래나 `Simulator Devices` 아래에 `device.plist`와 함께 있다.
    private static func simulatorDeviceCount(at path: String) -> Int? {
        let fileManager = FileManager.default
        for directory in [path, path + "/Simulator Devices"] {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            let count = names.filter { fileManager.fileExists(atPath: "\(directory)/\($0)/device.plist") }.count
            if count > 0 { return count }
        }
        return nil
    }

    private static func sizeNote(minimum: Int64, maximum: Int64, deviceCount: Int?) -> String? {
        guard Format.isRange(minimum: minimum, maximum: maximum) else { return nil }
        let subject = deviceCount.map { "시뮬레이터 \($0)대가 원본과 같은 데이터를 함께 쓰는 APFS 복제본이라" }
            ?? "다른 파일과 데이터를 함께 쓰는 APFS 복제본이 들어 있어"
        return "\(subject) 하나씩 따로 세면 \(Format.bytes(maximum))이지만, 지우면 실제로 비워지는 건 \(Format.bytes(minimum)) 정도입니다."
    }

    /// 같은 묶음 안에서 제목이 겹치면(예: `~/Library/Caches/com.foo`와 `/var/folders/…/C/com.foo`)
    /// 상위 폴더 경로를 덧붙여 구분한다.
    private static func distinguishingDuplicateTitles(_ entries: [CleanupEntry]) -> [CleanupEntry] {
        let counts = Dictionary(grouping: entries) { "\($0.groupID)\n\($0.title)" }.mapValues(\.count)
        return entries.map { entry in
            guard counts["\(entry.groupID)\n\(entry.title)", default: 0] > 1,
                  let path = entry.candidate?.path ?? entry.systemItem?.path
            else { return entry }
            var entry = entry
            entry.title += " · " + abbreviate((path as NSString).deletingLastPathComponent)
            return entry
        }
    }

    /// 실행 중인 앱의 캐시인지 이름으로 추정한다. Electron 캐시는 `Application Support/<앱 이름>/Cache`,
    /// 앱 캐시는 `Caches/<번들 ID>` 꼴이라 각각 앱 이름과 번들 ID로 맞춰 본다.
    private static func runningApplication(
        for candidate: CleanupCandidate,
        in applications: [NSRunningApplication]
    ) -> String? {
        let folder = (candidate.path as NSString).lastPathComponent.lowercased()
        switch candidate.rule.id {
        case "apps.electronCache":
            let owner = ((candidate.path as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
            return applications.first { $0.localizedName?.lowercased() == owner }?.localizedName
        case "apps.containerCache":
            guard let bundle = containerBundleIdentifier(candidate.path)?.lowercased() else { return nil }
            return applications.first { $0.bundleIdentifier?.lowercased() == bundle }?.localizedName
        case "apps.cache", "system.userCaches":
            return applications.first { application in
                guard let bundleIdentifier = application.bundleIdentifier?.lowercased() else { return false }
                return folder == bundleIdentifier || folder.hasPrefix(bundleIdentifier + ".")
            }?.localizedName
        default:
            return nil
        }
    }

    // MARK: - 묶음과 선택

    func groups(in section: CleanupSection) -> [CleanupGroup] {
        let sectionEntries = entries.filter { $0.section == section }
        return Dictionary(grouping: sectionEntries, by: \.groupID)
            .map { id, members in
                CleanupGroup(
                    id: id,
                    title: members[0].groupTitle,
                    note: members[0].groupNote,
                    path: members[0].groupPath,
                    entries: members.sorted { $0.bytes > $1.bytes }
                )
            }
            .sorted { $0.bytes > $1.bytes }
    }

    func selectionState(of ids: [CleanupEntry.ID]) -> SelectionState {
        let selectedCount = ids.filter(selection.contains).count
        if selectedCount == 0 { return .none }
        return selectedCount == ids.count ? .all : .some
    }

    /// 모두 골라져 있으면 모두 풀고, 아니면 모두 고른다.
    func toggle(_ ids: [CleanupEntry.ID]) {
        if selectionState(of: ids) == .all {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    var selectedEntries: [CleanupEntry] {
        entries.filter { selection.contains($0.id) }
    }

    // MARK: - 정리

    func plan() -> DeletionPlan {
        let targets = selectedEntries.compactMap { $0.deletionTarget(moveToTrash: moveToTrash) }
        return DeletionPlanner(policy: .cleanup()).plan(targets)
    }

    func clean(_ plan: DeletionPlan) async {
        isCleaning = true
        defer { isCleaning = false }
        do {
            let report = try await BackgroundActivity.run("정리") {
                try await Deleter(policy: .cleanup()).execute(plan)
            }
            let succeeded = Set(report.results.filter(\.status.succeeded).map(\.item.target.path))
            entries.removeAll { entry in
                let path = entry.candidate?.path ?? entry.systemItem?.path
                return path.map(succeeded.contains) ?? false
            }
            selection.formIntersection(entries.map(\.id))

            var message = "정리 완료 · \(report.summary) · 여유 공간 \(Format.bytes(report.freeBytesAfter))"
            let inBackground = report.results.contains { result in
                guard result.status.succeeded, case .command(let command) = result.item.target.method else { return false }
                return command.completesInBackground
            }
            if inBackground {
                message += " · 일부는 도구가 뒤에서 마저 지우므로 몇 분 뒤 공간이 더 늘어납니다"
            }
            lastActionMessage = message
            volume = VolumeUsage(path: NSHomeDirectory())
        } catch {
            lastActionMessage = "정리하지 못했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - 경로

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath((path as NSString).expandingTildeInPath, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
