import Darwin
import Foundation

/// 앱을 지운 뒤에도 `~/Library`에 남는 파일·폴더.
public struct ApplicationLeftover: Sendable, Identifiable {
    public enum Match: Sendable, Equatable {
        /// 이름이 번들 ID에서 나왔다. 그 앱의 데이터일 가능성이 높다.
        case bundleIdentifier
        /// 이름이 앱 이름과 같을 뿐이다. 다른 앱의 데이터일 수도 있어 자동으로 고르지 않는다.
        case appName
    }

    public let path: String
    /// `~/Library` 아래 어느 폴더에서 찾았는지. 예: "Caches"
    public let location: String
    public let identity: FileIdentity
    public let isDirectory: Bool
    public let allocatedBytes: Int64
    public let unsharedBytes: Int64
    public let match: Match
    /// 권한 등으로 크기를 다 재지 못했다.
    public let isPartiallyMeasured: Bool

    public var id: String { path }
}

/// 앱이 `~/Library`에 남긴 데이터를 번들 ID와 앱 이름으로 찾는다.
public struct LeftoverFinder: Sendable {
    /// 앱 데이터가 남는 `~/Library` 아래 폴더. `byName`이면 앱 이름과 같은 항목도 찾는다.
    static let locations: [(folder: String, byName: Bool)] = [
        ("Application Support", true),
        ("Caches", true),
        ("Logs", true),
        ("Preferences", false),
        ("Preferences/ByHost", false),
        ("Containers", false),
        ("Group Containers", false),
        ("Application Scripts", false),
        ("Saved Application State", false),
        ("HTTPStorages", false),
        ("WebKit", false),
        ("Cookies", false),
        ("LaunchAgents", false),
    ]

    public var homeDirectory: String
    public var scanner: DiskScanner
    /// false면 Containers·Group Containers 안은 크기를 재지 않는다. 전체 디스크 접근 권한이 없는 앱이
    /// 그 안을 읽으면 macOS가 "다른 앱의 데이터에 접근하려고 합니다" 창을 띄우기 때문이다.
    public var measuresProtectedFolders: Bool

    public init(
        homeDirectory: String = NSHomeDirectory(),
        scanner: DiskScanner = DiskScanner(options: ScanOptions(threadCount: 4)),
        measuresProtectedFolders: Bool = true
    ) {
        self.homeDirectory = homeDirectory
        self.scanner = scanner
        self.measuresProtectedFolders = measuresProtectedFolders
    }

    /// `otherBundleIdentifiers`는 함께 설치된 다른 앱의 번들 ID다. `com.example.foo`와
    /// `com.example.foo.pro`처럼 접두어가 겹치면, 더 구체적인 앱의 파일을 빼는 데 쓴다.
    public func leftovers(
        for application: InstalledApplication,
        otherBundleIdentifiers: Set<String> = []
    ) async -> [ApplicationLeftover] {
        guard let bundleIdentifier = application.bundleIdentifier, bundleIdentifier.contains(".") else { return [] }
        let id = bundleIdentifier.lowercased()
        let moreSpecific = otherBundleIdentifiers.map { $0.lowercased() }.filter { $0.hasPrefix(id + ".") }
        // 애플 앱은 이름이 흔하고("Notes" 등) 시스템이 같은 이름을 쓰는 경우가 많아 이름으로 찾지 않는다.
        let names: Set<String> = id.hasPrefix("com.apple.") ? [] : Set(
            [application.name, ((application.path as NSString).lastPathComponent as NSString).deletingPathExtension]
                .filter { $0.count >= 3 }
                .map { $0.lowercased() }
        )

        var found: [ApplicationLeftover] = []
        for (folder, byName) in Self.locations {
            let directory = homeDirectory + "/Library/" + folder
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries {
                let lowered = entry.lowercased()
                let match: ApplicationLeftover.Match
                if Self.name(lowered, belongsTo: id, in: folder),
                   !moreSpecific.contains(where: { Self.name(lowered, belongsTo: $0, in: folder) }) {
                    match = .bundleIdentifier
                } else if byName, names.contains(lowered) {
                    match = .appName
                } else {
                    continue
                }
                if let leftover = await measure(directory + "/" + entry, location: folder, match: match) {
                    found.append(leftover)
                }
            }
        }
        return found.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }

    /// 소문자로 바꾼 항목 이름이 번들 ID의 데이터인지 본다.
    static func name(_ name: String, belongsTo id: String, in folder: String) -> Bool {
        switch folder {
        case "Preferences/ByHost":
            // <번들 ID>.<호스트 UUID>.plist
            guard name.hasPrefix(id + "."), name.hasSuffix(".plist") else { return false }
            let host = name.dropFirst(id.count + 1).dropLast(".plist".count)
            return UUID(uuidString: String(host)) != nil
        case "Group Containers":
            // <팀 ID>.<번들 ID> 또는 group.<번들 ID>
            return name == id || name.hasSuffix("." + id)
        case "LaunchAgents":
            return name.hasPrefix(id + ".") && name.hasSuffix(".plist")
        default:
            return [id, id + ".plist", id + ".savedstate", id + ".binarycookies"].contains(name)
        }
    }

    private func measure(_ path: String, location: String, match: ApplicationLeftover.Match) async -> ApplicationLeftover? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let identity = FileIdentity(device: info.st_dev, fileID: info.st_ino)

        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            let skipsMeasuring = !measuresProtectedFolders && PrivacyProtection.protectedLibraryFolders.contains(location)
            let result = skipsMeasuring ? nil : try? await scanner.scan(path)
            return ApplicationLeftover(
                path: path,
                location: location,
                identity: identity,
                isDirectory: true,
                allocatedBytes: result?.root.totalBytes ?? 0,
                unsharedBytes: result?.root.totalUnsharedBytes ?? 0,
                match: match,
                isPartiallyMeasured: result.map { !$0.issues.isEmpty || $0.root.status != .scanned } ?? true
            )
        case S_IFREG:
            let bytes = Int64(info.st_blocks) * 512
            return ApplicationLeftover(
                path: path,
                location: location,
                identity: identity,
                isDirectory: false,
                allocatedBytes: bytes,
                unsharedBytes: bytes,
                match: match,
                isPartiallyMeasured: false
            )
        default:
            // 심볼릭 링크 등은 다른 곳을 가리킬 수 있어 다루지 않는다.
            return nil
        }
    }
}
