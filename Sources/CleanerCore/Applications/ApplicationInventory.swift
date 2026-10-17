import CoreServices
import Darwin
import Foundation

/// `/Applications`와 `~/Applications`에서 앱 번들을 찾고 크기와 날짜를 읽는다.
///
/// 크기는 폴더마다 한 번 스캔해서 앱 노드의 합계를 쓴다. Safari처럼 시스템 볼륨을 가리키는 심볼릭 링크는
/// 지울 수 없으므로 스캐너가 디렉터리로 보지 않고, 목록에도 나오지 않는다.
public struct ApplicationInventory: Sendable {
    public var searchRoots: [String]
    /// `Utilities`처럼 앱이 아닌 폴더를 몇 단계까지 들어가 볼지.
    public var folderDepth: Int
    /// 테스트처럼 Spotlight 색인이 없는 곳에서는 끈다.
    public var readsSpotlight: Bool
    public var scanner: DiskScanner

    public init(
        searchRoots: [String] = ["/Applications", NSHomeDirectory() + "/Applications"],
        folderDepth: Int = 2,
        readsSpotlight: Bool = true,
        scanner: DiskScanner = DiskScanner()
    ) {
        self.searchRoots = searchRoots
        self.folderDepth = folderDepth
        self.readsSpotlight = readsSpotlight
        self.scanner = scanner
    }

    public func applications(progress: ScanProgress = ScanProgress()) async throws -> [InstalledApplication] {
        var applications: [InstalledApplication] = []
        for root in searchRoots {
            var info = stat()
            guard lstat(root, &info) == 0 else { continue }
            let result = try await scanner.scan(root, progress: progress)

            var stack = [(node: result.root, path: result.root.name, depth: 0)]
            while let (node, path, depth) = stack.popLast() {
                for child in node.children where child.status == .scanned {
                    let childPath = path + "/" + child.name
                    if child.name.lowercased().hasSuffix(".app") {
                        applications.append(application(child, path: childPath, device: result.device))
                    } else if depth < folderDepth, !child.name.hasPrefix(".") {
                        stack.append((child, childPath, depth + 1))
                    }
                }
            }
        }
        return applications
    }

    private func application(_ node: DirectoryNode, path: String, device: Int32) -> InstalledApplication {
        let url = URL(fileURLWithPath: path)
        // Bundle(url:)은 번들을 프로세스가 끝날 때까지 캐시하므로 Info.plist를 직접 읽는다.
        let info = (try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }

        var name = FileManager.default.displayName(atPath: path)
        if name.lowercased().hasSuffix(".app") {
            name = String(name.dropLast(4))
        }

        return InstalledApplication(
            path: path,
            name: name,
            bundleIdentifier: info?["CFBundleIdentifier"] as? String,
            version: info?["CFBundleShortVersionString"] as? String,
            identity: FileIdentity(device: device, fileID: node.fileID),
            allocatedBytes: node.totalBytes,
            unsharedBytes: node.totalUnsharedBytes,
            addedDate: (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate,
            lastUsedDate: readsSpotlight ? Self.lastUsedDate(of: url) : nil,
            isFromAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
        )
    }

    private static func lastUsedDate(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
