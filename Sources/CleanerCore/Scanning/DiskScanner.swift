import Darwin
import Foundation
import Synchronization

public struct ScanOptions: Sendable {
    /// M 시리즈 14코어 맥에서 `~/Library/Developer`(디렉터리 62만 개)를 스캔해 고른 값이다.
    /// 4개 15.8초, 8개 12.9초, 14개 19.7초, 24개 25.8초였다. 시간 대부분이 커널에서 쓰이고,
    /// 스레드가 8개를 넘으면 커널 안 경합으로 오히려 느려진다.
    public static let defaultThreadCount = min(8, ProcessInfo.processInfo.activeProcessorCount)

    /// 디렉터리를 동시에 읽을 스레드 수.
    public var threadCount: Int
    /// 이 크기 이상인 파일만 노드에 이름을 남긴다. 나머지는 디렉터리 합계에만 더한다.
    public var largeFileThreshold: Int64
    /// 들어가지 않을 절대 경로. 심볼릭 링크를 푼 경로로 적는다.
    public var excludedPaths: Set<String>
    /// 디렉터리 하나를 읽는 데 이보다 오래 걸리면 "응답 없음"(ETIMEDOUT)으로 표시하고 넘어간다.
    /// `~/Library/Caches/com.apple.Music`처럼 macOS가 권한 확인 창을 띄우는 폴더는 사용자가 답할 때까지 열리지 않는다.
    public var directoryTimeout: Duration
    /// 테스트용. 디렉터리를 읽기 직전에 경로를 넘겨 부른다.
    var beforeReading: (@Sendable (String) -> Void)?

    public init(
        threadCount: Int = ScanOptions.defaultThreadCount,
        largeFileThreshold: Int64 = 1 << 20,
        excludedPaths: Set<String> = [],
        directoryTimeout: Duration = .seconds(15)
    ) {
        self.threadCount = threadCount
        self.largeFileThreshold = largeFileThreshold
        self.excludedPaths = excludedPaths
        self.directoryTimeout = directoryTimeout
    }
}

public enum ScanError: Error, Equatable {
    case cannotAccess(path: String, errno: Int32)
    case notADirectory(path: String)
}

/// 읽지 못한 디렉터리나 항목. 대부분 권한 문제(EACCES, EPERM)다.
public struct ScanIssue: Sendable, Hashable {
    public let path: String
    public let errno: Int32
}

public struct ScanResult: Sendable {
    public let root: DirectoryNode
    /// 스캔한 볼륨의 장치 번호. 트리의 모든 노드가 이 볼륨에 있다.
    public let device: Int32
    public let duration: Duration
    public let issues: [ScanIssue]
    /// 하드링크로 두 번 이상 나타나 한 번만 센 바이트.
    public let skippedHardLinkBytes: Int64
}

/// 스캔 중에 다른 스레드가 읽을 수 있는 누적 카운터.
public final class ScanProgress: Sendable {
    private static let slotCount = 64

    private let directoryCount = Atomic<Int>(0)
    private let fileCount = Atomic<Int>(0)
    private let byteCount = Atomic<Int64>(0)
    /// 워커마다 지금 읽고 있는 디렉터리. 칸을 나눠 두어 워커끼리 잠금을 다투지 않는다.
    private final class Slot: Sendable {
        let path = Mutex<String?>(nil)
    }
    private let readingPaths: [Slot] = (0..<ScanProgress.slotCount).map { _ in Slot() }

    public init() {}

    public var directories: Int { directoryCount.load(ordering: .relaxed) }
    public var files: Int { fileCount.load(ordering: .relaxed) }
    public var bytes: Int64 { byteCount.load(ordering: .relaxed) }

    /// 지금 읽고 있는 디렉터리들. 한 경로에 오래 머물면 권한 확인 창 등을 기다리는 중일 수 있다.
    public var currentPaths: [String] {
        readingPaths.compactMap { slot in slot.path.withLock { $0 } }
    }

    func setReading(_ path: String?, worker: Int) {
        guard worker < Self.slotCount else { return }
        readingPaths[worker].path.withLock { $0 = path }
    }

    func record(files: Int, bytes: Int64) {
        directoryCount.add(1, ordering: .relaxed)
        fileCount.add(files, ordering: .relaxed)
        byteCount.add(bytes, ordering: .relaxed)
    }
}

/// 디렉터리 트리를 병렬로 훑어 할당 크기를 집계한다.
///
/// 디렉터리 하나를 작업 하나로 보고, 워커 스레드들이 공유 스택에서 꺼내 읽는다. 스택(LIFO)이라 깊이 우선에
/// 가깝게 진행되어 대기 중인 작업 수가 트리 너비만큼 불어나지 않는다. 합계는 모든 디렉터리를 읽은 뒤
/// 후위 순회로 낸다. 시작한 볼륨 밖(마운트 지점)으로는 나가지 않고, 심볼릭 링크는 따라가지 않으며,
/// 하드링크는 한 번만 센다.
///
/// 워커는 Swift 동시성의 협력 스레드 풀이 아니라 전용 스레드에서 돈다. 디렉터리 읽기는 블로킹 시스템 콜이라
/// 협력 풀에서 돌리면 앱의 다른 async 작업까지 막기 때문이다.
public struct DiskScanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    public func scan(_ path: String, progress: ScanProgress = ScanProgress()) async throws -> ScanResult {
        let root = try Self.resolveRoot(path)
        let job = ScanJob(rootPath: root.path, device: root.device, options: options, progress: progress)
        job.root.fileID = root.fileID
        let start = ContinuousClock.now

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                job.start { continuation.resume() }
            }
        } onCancel: {
            job.cancel()
        }
        if job.wasCancelled { throw CancellationError() }

        job.markTimedOutDirectories()
        job.root.aggregateTotals()
        return ScanResult(
            root: job.root,
            device: root.device,
            duration: ContinuousClock.now - start,
            issues: job.issues,
            skippedHardLinkBytes: job.skippedHardLinkBytes
        )
    }

    private static func resolveRoot(_ path: String) throws(ScanError) -> (path: String, device: dev_t, fileID: UInt64) {
        guard let resolved = realpath(path, nil) else {
            throw .cannotAccess(path: path, errno: errno)
        }
        defer { free(resolved) }
        let rootPath = String(cString: resolved)

        var info = stat()
        guard lstat(rootPath, &info) == 0 else {
            throw .cannotAccess(path: rootPath, errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw .notADirectory(path: rootPath)
        }
        return (rootPath, info.st_dev, info.st_ino)
    }
}

/// 스캔 한 번이 공유하는 상태.
///
/// `condition`이 `pending`, `outstanding`, `inFlight`, `cancelled`, `finished`, `completion`을 보호한다.
/// 워커는 디렉터리를 읽는 동안 노드를 고치지 않고, 읽기가 끝나면 `inFlight`에서 자기 작업을 "가져간" 뒤에만
/// 노드에 결과를 쓴다. 감시 스레드가 오래 걸리는 작업을 먼저 포기 처리하면 워커는 가져가지 못하고 결과를 버린다.
/// 그래서 한 노드에는 한 스레드만 쓰고, `outstanding`이 0이 된 뒤에는 아무도 노드를 고치지 않는다.
final class ScanJob: @unchecked Sendable {
    private struct WorkItem {
        let node: DirectoryNode
        let path: String
    }

    /// 디렉터리 하나를 읽은 결과. 작업을 가져간 뒤에 노드에 반영한다.
    private struct Contents {
        var status: DirectoryNode.Status = .scanned
        var children: [DirectoryNode] = []
        var subdirectories: [WorkItem] = []
        var largeFiles: [FileEntry] = []
        var fileCount = 0
        var fileBytes: Int64 = 0
        var unsharedBytes: Int64 = 0
        var issues: [ScanIssue] = []
    }

    /// 멈춘 스레드 대신 새로 띄울 수 있는 최대 수. 이보다 많이 멈추면 더 띄우지 않는다.
    private static let maximumReplacementWorkers = 32

    let root: DirectoryNode
    private let device: dev_t
    private let options: ScanOptions
    private let progress: ScanProgress

    private let condition = NSCondition()
    private var pending: [WorkItem]
    /// 스택에 있거나 읽고 있는 디렉터리 수. 0이 되면 스캔이 끝난다.
    private var outstanding = 1
    /// 워커 번호 → 지금 읽고 있는 작업과 시작 시각.
    private var inFlight: [Int: (item: WorkItem, start: ContinuousClock.Instant)] = [:]
    /// 시간 안에 끝나지 않아 포기한 디렉터리.
    private var timedOut: [WorkItem] = []
    private var cancelled = false
    private var finished = false
    private var waitingThreads = 0
    private var nextWorkerIndex = 0
    private var replacementWorkers = 0
    private var completion: (@Sendable () -> Void)?

    private let issueStore = Mutex<[ScanIssue]>([])
    private let seenHardLinks = Mutex<Set<UInt64>>([])
    private let skippedHardLinkByteCount = Atomic<Int64>(0)

    init(rootPath: String, device: dev_t, options: ScanOptions, progress: ScanProgress) {
        self.root = DirectoryNode(name: rootPath, parent: nil)
        self.device = device
        self.options = options
        self.progress = progress
        self.pending = [WorkItem(node: root, path: rootPath)]
    }

    var issues: [ScanIssue] { issueStore.withLock { $0 } }
    var skippedHardLinkBytes: Int64 { skippedHardLinkByteCount.load(ordering: .relaxed) }

    var wasCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    /// 워커와 감시 스레드를 띄운다. 남은 작업이 0이 되거나 취소되면 `completion`을 한 번 부른다.
    func start(completion: @escaping @Sendable () -> Void) {
        condition.lock()
        // 시작하기 전에 취소됐으면 띄울 것 없이 바로 알린다. 그렇지 않으면 기다리는 쪽이 영영 깨어나지 않는다.
        guard !finished else {
            condition.unlock()
            completion()
            return
        }
        self.completion = completion
        condition.unlock()
        for _ in 0..<max(1, options.threadCount) {
            spawnWorker()
        }
        let watchdog = Thread { [self] in watch() }
        watchdog.name = "CleanerCore.scan.watchdog"
        watchdog.start()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        let completion = finishLocked()
        condition.unlock()
        completion?()
    }

    /// 완료를 한 번만 알린다. 잠금 안에서 부르고, 돌려받은 클로저는 잠금 밖에서 부른다.
    private func finishLocked() -> (@Sendable () -> Void)? {
        guard !finished else { return nil }
        finished = true
        condition.broadcast()
        defer { completion = nil }
        return completion
    }

    /// 포기한 디렉터리를 "응답 없음"으로 표시한다. 완료 뒤 한 스레드에서 부른다.
    func markTimedOutDirectories() {
        condition.lock()
        let items = timedOut
        condition.unlock()
        for item in items {
            item.node.status = .unreadable(errno: ETIMEDOUT)
            record(ScanIssue(path: item.path, errno: ETIMEDOUT))
        }
    }

    private func spawnWorker() {
        condition.lock()
        let index = nextWorkerIndex
        nextWorkerIndex += 1
        condition.unlock()
        let thread = Thread { [self] in work(worker: index) }
        thread.name = "CleanerCore.scan.\(index)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func work(worker: Int) {
        // iCloud·File Provider처럼 내용이 클라우드에만 있는(dataless) 항목을 읽다가 내려받지 않게 한다.
        // 정책은 부모 프로세스에서 상속되므로 스레드마다 명시적으로 끈다.
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )
        let reader = DirectoryReader()
        var entries: [DirectoryEntry] = []
        while let item = nextItem(worker: worker) {
            progress.setReading(item.path, worker: worker)
            options.beforeReading?(item.path)
            let contents = read(item, with: reader, buffer: &entries)
            // 그사이 감시 스레드가 포기 처리했으면 결과를 버리고 물러난다. 대신할 워커가 이미 떠 있다.
            guard claim(worker: worker) else { break }
            apply(contents, to: item.node)
            complete(discovered: contents.subdirectories)
        }
        progress.setReading(nil, worker: worker)
    }

    /// 다음 디렉터리를 꺼내 읽기 시작 시각을 남긴다. 끝났거나 취소되면 nil을 돌려준다.
    private func nextItem(worker: Int) -> WorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && !finished {
            waitingThreads += 1
            condition.wait()
            waitingThreads -= 1
        }
        if finished { return nil }
        let item = pending.removeLast()
        inFlight[worker] = (item, ContinuousClock.now)
        return item
    }

    /// 읽던 작업을 가져간다. 감시 스레드가 이미 포기 처리했으면 false.
    private func claim(worker: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return inFlight.removeValue(forKey: worker) != nil && !finished
    }

    private func complete(discovered: [WorkItem]) {
        condition.lock()
        pending.append(contentsOf: discovered)
        outstanding += discovered.count - 1
        var completion: (@Sendable () -> Void)?
        if outstanding == 0 {
            completion = finishLocked()
        } else {
            // 새로 생긴 작업 수만큼만 깨운다. 모두 깨우면 스레드가 많을수록 잠금 경합으로 느려진다.
            for _ in 0..<min(discovered.count, waitingThreads) {
                condition.signal()
            }
        }
        condition.unlock()
        completion?()
    }

    /// 디렉터리를 여는 데서 멈춘 워커를 찾는다. 권한 확인 창을 기다리거나(TCC) 응답 없는 네트워크 위치를 읽으면
    /// open()이 끝나지 않는다. 그런 디렉터리는 포기 처리하고, 멈춘 워커 대신 새 워커를 띄워 나머지를 계속 읽는다.
    private func watch() {
        condition.lock()
        while !finished {
            _ = condition.wait(until: Date().addingTimeInterval(0.5))
            if finished { break }
            let now = ContinuousClock.now
            let stuck = inFlight.filter { now - $0.value.start > options.directoryTimeout }
            var replacements = 0
            for (worker, flight) in stuck {
                inFlight[worker] = nil
                timedOut.append(flight.item)
                outstanding -= 1
                if replacementWorkers < Self.maximumReplacementWorkers {
                    replacementWorkers += 1
                    replacements += 1
                }
            }
            if outstanding == 0 {
                let completion = finishLocked()
                condition.unlock()
                completion?()
                return
            }
            if replacements > 0 {
                condition.unlock()
                for _ in 0..<replacements { spawnWorker() }
                condition.lock()
            }
        }
        condition.unlock()
    }

    /// 디렉터리 하나를 읽는다. 노드는 고치지 않고 결과만 돌려준다.
    private func read(_ item: WorkItem, with reader: DirectoryReader, buffer entries: inout [DirectoryEntry]) -> Contents {
        var contents = Contents()
        entries.removeAll(keepingCapacity: true)
        do {
            try reader.read(path: item.path, device: device, into: &entries)
        } catch {
            switch error {
            case .otherVolume:
                contents.status = .otherVolume
            case .open(EDEADLK), .read(EDEADLK):
                // dataless 항목을 내려받지 않게 해 둔 상태에서 클라우드 전용 디렉터리를 읽으면 EDEADLK가 난다.
                contents.status = .cloudOnly
            case .open(let code), .read(let code):
                contents.status = .unreadable(errno: code)
                contents.issues.append(ScanIssue(path: item.path, errno: code))
            }
            return contents
        }

        for entry in entries {
            if entry.error != 0 {
                contents.issues.append(ScanIssue(path: Self.join(item.path, entry.name), errno: entry.error))
                continue
            }

            if entry.kind == .directory {
                let child = DirectoryNode(name: entry.name, parent: item.node)
                child.fileID = entry.fileID
                contents.children.append(child)
                let childPath = Self.join(item.path, entry.name)
                if entry.isVolumeBoundary {
                    child.status = .otherVolume
                } else if options.excludedPaths.contains(childPath) {
                    child.status = .excluded
                } else {
                    contents.subdirectories.append(WorkItem(node: child, path: childPath))
                }
                continue
            }

            var bytes = entry.allocatedBytes
            var unshared = entry.unsharedBytes
            if entry.kind == .file, entry.linkCount > 1, !claimHardLink(entry.fileID) {
                skippedHardLinkByteCount.add(bytes, ordering: .relaxed)
                bytes = 0
                unshared = 0
            }
            contents.fileCount += 1
            contents.fileBytes += bytes
            contents.unsharedBytes += unshared
            if bytes >= options.largeFileThreshold {
                contents.largeFiles.append(FileEntry(name: entry.name, allocatedBytes: bytes, unsharedBytes: unshared))
            }
        }
        return contents
    }

    private func apply(_ contents: Contents, to node: DirectoryNode) {
        node.status = contents.status
        node.children = contents.children
        node.largeFiles = contents.largeFiles
        node.ownFileCount = contents.fileCount
        node.ownFileBytes = contents.fileBytes
        node.ownUnsharedBytes = contents.unsharedBytes
        contents.issues.forEach(record)
        if contents.status == .scanned {
            progress.record(files: contents.fileCount, bytes: contents.fileBytes)
        }
    }

    /// 하드링크된 파일을 처음 본 것이면 true. 같은 볼륨 안에서만 돌므로 inode 번호만으로 구분한다.
    private func claimHardLink(_ fileID: UInt64) -> Bool {
        seenHardLinks.withLock { $0.insert(fileID).inserted }
    }

    private func record(_ issue: ScanIssue) {
        issueStore.withLock { $0.append(issue) }
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }
}
