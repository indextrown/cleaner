import CleanerCore
import Darwin
import Foundation
import Observation

/// 탐색 표의 한 줄.
struct ExplorerRow: Identifiable {
    let entry: DirectoryNode.Entry
    let name: String
    let bytes: Int64
    let unsharedBytes: Int64
    /// 지금 보는 폴더 전체에서 차지하는 비율(0...1).
    let share: Double
    /// 폴더 안의 파일 수. 파일이면 nil.
    let fileCount: Int?
    /// 다른 볼륨, 읽기 실패처럼 크기에 문제가 있는 이유.
    let note: String?

    var id: String { entry.id }

    var isDirectory: Bool {
        if case .directory = entry { true } else { false }
    }

    var canOpen: Bool {
        if case .directory(let node) = entry { node.status == .scanned } else { false }
    }

    var canMoveToTrash: Bool {
        if case .smallFiles = entry { false } else { true }
    }
}

@Observable
@MainActor
final class ExplorerModel {
    enum Root: Hashable {
        case home
        case dataVolume
        case folder(String)

        var path: String {
            switch self {
            case .home: NSHomeDirectory()
            case .dataVolume: "/System/Volumes/Data"
            case .folder(let path): path
            }
        }

        var title: String {
            switch self {
            case .home: "홈 폴더"
            case .dataVolume: "디스크 전체"
            case .folder(let path): (path as NSString).lastPathComponent
            }
        }
    }

    struct Progress {
        var directories = 0
        var files = 0
        var bytes: Int64 = 0
        var currentPaths: [String] = []
    }

    private(set) var root: Root?
    private(set) var result: ScanResult?
    private(set) var volume: VolumeUsage?
    private(set) var isScanning = false
    private(set) var progress = Progress()
    private(set) var errorMessage: String?
    /// 마지막으로 확인한 전체 디스크 접근 권한. 없으면 보호 폴더를 빼고 스캔한다.
    private(set) var hasFullDiskAccess = PrivacyProtection.hasFullDiskAccess
    /// 루트부터 지금 보는 폴더까지.
    private(set) var trail: [DirectoryNode] = []
    /// DirectoryNode는 관찰 대상이 아니라서, 트리를 고친 뒤 이 값을 올려 화면을 다시 그린다.
    private(set) var revision = 0
    var lastActionMessage: String?

    private var scanTask: Task<Void, Never>?

    var current: DirectoryNode? { trail.last }

    /// 권한 문제(EACCES, EPERM)로 읽지 못한 곳 수.
    var permissionIssueCount: Int {
        result?.issues.filter { $0.errno == EACCES || $0.errno == EPERM }.count ?? 0
    }

    func scan(_ root: Root) {
        scanTask?.cancel()
        self.root = root
        isScanning = true
        errorMessage = nil
        lastActionMessage = nil
        result = nil
        trail = []
        progress = Progress()

        // 권한 없이 보호 폴더를 읽으면 macOS가 폴더마다 허용 여부를 묻고, 답할 때까지 스캔이 멈춘다.
        hasFullDiskAccess = PrivacyProtection.hasFullDiskAccess
        let options = ScanOptions(excludedPaths: hasFullDiskAccess ? [] : PrivacyProtection.protectedPaths())
        let scanProgress = ScanProgress()
        scanTask = Task {
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    progress = Progress(
                        directories: scanProgress.directories,
                        files: scanProgress.files,
                        bytes: scanProgress.bytes,
                        currentPaths: scanProgress.currentPaths
                    )
                }
            }
            defer { poller.cancel() }
            do {
                let result = try await BackgroundActivity.run("디스크 스캔") {
                    try await DiskScanner(options: options).scan(root.path, progress: scanProgress)
                }
                self.result = result
                trail = [result.root]
                volume = VolumeUsage(path: result.root.name)
                writeScanReportIfRequested(result)
            } catch is CancellationError {
                self.root = nil
            } catch {
                errorMessage = Format.describe(error)
            }
            isScanning = false
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = PrivacyProtection.hasFullDiskAccess
    }

    func open(_ node: DirectoryNode) {
        guard node.status == .scanned else { return }
        trail.append(node)
    }

    func goUp() {
        if trail.count > 1 { trail.removeLast() }
    }

    func go(toDepth depth: Int) {
        guard depth < trail.count else { return }
        trail = Array(trail.prefix(depth + 1))
    }

    func rows(sortedBy sortOrder: [KeyPathComparator<ExplorerRow>]) -> [ExplorerRow] {
        _ = revision
        guard let current else { return [] }
        let total = max(current.totalBytes, 1)
        return current.entries.map { entry in
            switch entry {
            case .directory(let node):
                ExplorerRow(
                    entry: entry, name: node.name, bytes: node.totalBytes, unsharedBytes: node.totalUnsharedBytes,
                    share: Double(node.totalBytes) / Double(total), fileCount: node.totalFileCount,
                    note: Self.note(for: node.status)
                )
            case .file(let file):
                ExplorerRow(
                    entry: entry, name: file.name, bytes: file.allocatedBytes, unsharedBytes: file.unsharedBytes,
                    share: Double(file.allocatedBytes) / Double(total), fileCount: nil, note: nil
                )
            case .smallFiles(let count, let bytes, let unsharedBytes):
                ExplorerRow(
                    entry: entry, name: "작은 파일 \(count.formatted())개", bytes: bytes, unsharedBytes: unsharedBytes,
                    share: Double(bytes) / Double(total), fileCount: count, note: nil
                )
            }
        }
        .sorted(using: sortOrder)
    }

    func path(of row: ExplorerRow) -> String? {
        guard let current else { return nil }
        switch row.entry {
        case .directory(let node): return node.path
        case .file(let file): return current.path + "/" + file.name
        case .smallFiles: return nil
        }
    }

    // MARK: - 휴지통

    /// 고른 줄을 휴지통으로 옮기는 계획. 홈과 시뮬레이터 폴더 밖, 홈의 주요 폴더는 막힌다.
    func trashPlan(for rows: [ExplorerRow]) -> DeletionPlan {
        guard let result, let current else { return DeletionPlan(items: []) }
        let targets = rows.compactMap { row -> DeletionTarget? in
            switch row.entry {
            case .directory(let node):
                return DeletionTarget(
                    path: node.path, identity: FileIdentity(device: result.device, fileID: node.fileID),
                    method: .moveToTrash, title: node.name,
                    allocatedBytes: node.totalBytes, unsharedBytes: node.totalUnsharedBytes
                )
            case .file(let file):
                // 큰 파일은 스캔 때 inode를 남기지 않으므로 지금 확인한 것을 쓴다.
                let path = current.path + "/" + file.name
                var info = stat()
                guard lstat(path, &info) == 0 else { return nil }
                return DeletionTarget(
                    path: path, identity: FileIdentity(device: info.st_dev, fileID: info.st_ino),
                    method: .moveToTrash, title: file.name,
                    allocatedBytes: file.allocatedBytes, unsharedBytes: file.unsharedBytes, isDirectory: false
                )
            case .smallFiles:
                return nil
            }
        }
        return DeletionPlanner(policy: .cleanup()).plan(targets)
    }

    func moveToTrash(_ plan: DeletionPlan) async {
        guard let current else { return }
        do {
            let report = try await BackgroundActivity.run("휴지통으로 옮기기") {
                try await Deleter(policy: .cleanup()).execute(plan)
            }
            for result in report.results where result.status.succeeded {
                let name = (result.item.target.path as NSString).lastPathComponent
                if result.item.target.isDirectory, let node = current.children.first(where: { $0.name == name }) {
                    current.removeChild(node)
                } else {
                    current.removeLargeFile(named: name)
                }
            }
            revision += 1
            lastActionMessage = report.summary + " · 휴지통을 비우면 공간이 생깁니다."
        } catch {
            lastActionMessage = "옮기지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// 개발·확인용: 실행 인자 `-scanReport <경로>`가 있으면 스캔 요약을 JSON으로 남긴다.
    private func writeScanReportIfRequested(_ result: ScanResult) {
        guard let path = UserDefaults.standard.string(forKey: "scanReport") else { return }
        let components = result.duration.components
        let report: [String: Any] = [
            "root": result.root.name,
            "seconds": Double(components.seconds) + Double(components.attoseconds) / 1e18,
            "hasFullDiskAccess": hasFullDiskAccess,
            "totalBytes": result.root.totalBytes,
            "unsharedBytes": result.root.totalUnsharedBytes,
            "files": result.root.totalFileCount,
            "issues": result.issues.count,
            "volumeUsedBytes": volume?.usedBytes ?? 0,
            "containerUsedBytes": volume?.containerUsedBytes ?? 0,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
    }

    private static func note(for status: DirectoryNode.Status) -> String? {
        switch status {
        case .scanned: nil
        case .otherVolume: "다른 볼륨"
        case .excluded: "권한 필요"
        case .cloudOnly: "클라우드 전용"
        case .unreadable(let code):
            switch code {
            case EACCES, EPERM: "권한 없음"
            // 권한 확인 창을 기다리는 폴더 등은 시간 안에 열리지 않아 건너뛴다.
            case ETIMEDOUT: "응답 없음"
            default: "읽기 실패"
            }
        }
    }
}
