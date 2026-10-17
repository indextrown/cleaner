import AppKit
import Darwin
import Foundation
import Synchronization

public struct DeletionResult: Sendable {
    public enum Status: Sendable, Equatable {
        case removed
        case movedToTrash(to: String)
        case commandSucceeded
        case skipped(SkipReason)
        /// 지우다 실패했다. 디렉터리를 지우던 중이면 일부만 지워졌을 수 있다.
        case failed(String)
    }

    public enum SkipReason: Sendable, Equatable {
        case blocked(PlannedDeletion.Blocker)
        case alreadyGone
        /// 계획한 뒤에 다른 디렉터리나 심볼릭 링크로 바뀌었다.
        case identityChanged
        /// 경로 중간의 디렉터리가 심볼릭 링크로 바뀌었다.
        case pathChanged
        case cancelled
        /// 로그를 쓰지 못해 더 진행하지 않았다.
        case loggingFailed
    }

    public let item: PlannedDeletion
    public let status: Status
    public let duration: Duration
}

public struct DeletionReport: Sendable {
    public let results: [DeletionResult]
    public let freeBytesBefore: Int64
    public let freeBytesAfter: Int64
    /// 로그 파일 경로. 로그를 남기지 않았으면 nil.
    public let logPath: String?

    /// 실제로 늘어난 여유 공간. 같은 시간에 다른 프로그램이 디스크를 쓰면 그만큼 어긋난다.
    public var reclaimedBytes: Int64 { freeBytesAfter - freeBytesBefore }
}

public protocol Trashing: Sendable {
    /// 휴지통으로 옮기고, 옮겨진 경로를 돌려준다.
    func moveToTrash(_ path: String) throws -> String
}

public struct SystemTrash: Trashing {
    public init() {}

    public func moveToTrash(_ path: String) throws -> String {
        var destination: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &destination)
        return destination?.path ?? ""
    }
}

/// Finder를 거쳐 휴지통으로 옮긴다. 쓰기 권한이 없으면 Finder가 관리자 암호를 묻는다.
/// 앱의 메인 스레드가 돌고 있어야 하며, 메인 스레드에서 부르면 안 된다(완료를 기다리며 막힌다).
public struct WorkspaceTrash: Trashing {
    public init() {}

    public func moveToTrash(_ path: String) throws -> String {
        precondition(!Thread.isMainThread, "WorkspaceTrash는 메인 스레드 밖에서 불러야 한다")
        let url = URL(fileURLWithPath: path)
        let outcome = Mutex<Result<String, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            NSWorkspace.shared.recycle([url]) { trashed, error in
                outcome.withLock {
                    $0 = error.map { .failure($0) } ?? .success(trashed[url]?.path ?? "")
                }
                finished.signal()
            }
        }
        finished.wait()
        return try outcome.withLock { $0! }.get()
    }
}

/// 계획을 실행한다. 항목마다 지우기 직전에 경로와 inode를 다시 확인하고, 결과를 로그에 남긴다.
public struct Deleter: Sendable {
    public static let defaultLogDirectory = NSHomeDirectory() + "/Library/Logs/Cleaner"

    public var policy: DeletionPolicy
    public var trash: any Trashing
    /// 쓰기 권한이 없는 항목을 휴지통으로 옮길 때 쓴다. nil이면 그런 항목은 실패한다.
    public var authorizedTrash: (any Trashing)?
    public var commandResolver: CommandResolver
    /// nil이면 로그를 남기지 않는다.
    public var logDirectory: String?

    public init(
        policy: DeletionPolicy = .cleanup(),
        trash: any Trashing = SystemTrash(),
        authorizedTrash: (any Trashing)? = nil,
        commandResolver: CommandResolver = CommandResolver(),
        logDirectory: String? = Deleter.defaultLogDirectory
    ) {
        self.policy = policy
        self.trash = trash
        self.authorizedTrash = authorizedTrash
        self.commandResolver = commandResolver
        self.logDirectory = logDirectory
    }

    /// 항목을 순서대로 처리한다. 로그 파일을 만들 수 없으면 아무것도 지우지 않고 오류를 던진다.
    public func execute(
        _ plan: DeletionPlan,
        onResult: (@Sendable (DeletionResult) -> Void)? = nil
    ) async throws -> DeletionReport {
        let log = try logDirectory.map { try DeletionLog(directory: $0) }
        let freeBytesBefore = Self.freeBytes()
        try log?.write(StartRecord(date: Date(), freeBytes: freeBytesBefore, itemCount: plan.items.count))

        var results: [DeletionResult] = []
        var loggingFailed = false
        for item in plan.items {
            let result: DeletionResult
            if loggingFailed {
                result = DeletionResult(item: item, status: .skipped(.loggingFailed), duration: .zero)
            } else if Task.isCancelled {
                result = DeletionResult(item: item, status: .skipped(.cancelled), duration: .zero)
            } else if let blocker = item.blocker {
                result = DeletionResult(item: item, status: .skipped(.blocked(blocker)), duration: .zero)
            } else {
                result = await perform(item)
            }
            results.append(result)
            do {
                try log?.write(ItemRecord(result))
            } catch {
                loggingFailed = true
            }
            onResult?(result)
        }

        let freeBytesAfter = Self.freeBytes()
        try? log?.write(FinishRecord(
            date: Date(),
            freeBytes: freeBytesAfter,
            reclaimedBytes: freeBytesAfter - freeBytesBefore
        ))
        return DeletionReport(
            results: results,
            freeBytesBefore: freeBytesBefore,
            freeBytesAfter: freeBytesAfter,
            logPath: log?.path
        )
    }

    /// 디렉터리 삭제와 명령 실행은 블로킹이라 협력 스레드 풀 밖에서 돌린다.
    private func perform(_ item: PlannedDeletion) async -> DeletionResult {
        let start = ContinuousClock.now
        let status = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: performBlocking(item.target))
            }
        }
        return DeletionResult(item: item, status: status, duration: ContinuousClock.now - start)
    }

    private func performBlocking(_ target: DeletionTarget) -> DeletionResult.Status {
        if let rejection = verify(target) {
            return rejection
        }
        switch target.method {
        case .remove:
            if let code = Self.removeTree(target.path) {
                return .failed(String(cString: strerror(code)))
            }
            return .removed
        case .moveToTrash:
            let trash = if let authorizedTrash, !DeletionPlanner.isWritable(target.path) {
                authorizedTrash
            } else {
                self.trash
            }
            do {
                return .movedToTrash(to: try trash.moveToTrash(target.path))
            } catch {
                return .failed(error.localizedDescription)
            }
        case .command(let command):
            return run(command)
        }
    }

    /// 계획한 그 디렉터리(또는 파일)가 그대로 있는지 확인한다. 문제가 있으면 건너뛸 이유를 돌려준다.
    func verify(_ target: DeletionTarget) -> DeletionResult.Status? {
        if let violation = policy.violation(for: target) {
            return .skipped(.blocked(.policy(violation)))
        }

        // 부모 경로에 심볼릭 링크가 끼어들면 같은 이름으로 엉뚱한 곳을 지우게 된다.
        let parent = (target.path as NSString).deletingLastPathComponent
        guard let resolved = realpath(parent, nil) else {
            return errno == ENOENT ? .skipped(.alreadyGone) : .failed(String(cString: strerror(errno)))
        }
        defer { free(resolved) }
        guard String(cString: resolved) == parent else {
            return .skipped(.pathChanged)
        }

        var info = stat()
        guard lstat(target.path, &info) == 0 else {
            return errno == ENOENT ? .skipped(.alreadyGone) : .failed(String(cString: strerror(errno)))
        }
        guard
            info.st_mode & S_IFMT == (target.isDirectory ? S_IFDIR : S_IFREG),
            info.st_dev == target.identity.device,
            info.st_ino == target.identity.fileID
        else {
            return .skipped(.identityChanged)
        }
        return nil
    }

    /// `rm -rx`처럼 지운다. 심볼릭 링크를 따라가지 않고(FTS_PHYSICAL), 다른 볼륨으로 내려가지 않는다(FTS_XDEV).
    /// 프로세스의 작업 디렉터리를 바꾸지 않도록 FTS_NOCHDIR을 쓴다. 실패하면 처음 만난 errno를 돌려준다.
    static func removeTree(_ path: String) -> Int32? {
        guard let rootPath = strdup(path) else { return ENOMEM }
        defer { free(rootPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return errno }
        defer { fts_close(fts) }

        var firstError: Int32?
        while let entry = fts_read(fts) {
            let accessPath = entry.pointee.fts_accpath
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                continue
            case FTS_DP:
                // 다른 볼륨이 마운트된 디렉터리는 FTS_XDEV로 들어가지 않으므로 여기서 비어 있지 않아 실패한다.
                if rmdir(accessPath) != 0 { firstError = firstError ?? errno }
            case FTS_DNR, FTS_ERR, FTS_NS:
                firstError = firstError ?? entry.pointee.fts_errno
            default:
                if unlink(accessPath) != 0 { firstError = firstError ?? errno }
            }
        }
        // fts_read는 끝까지 읽으면 errno를 0으로, 도중에 실패하면 원인으로 설정하고 nil을 돌려준다.
        if errno != 0 {
            firstError = firstError ?? errno
        }
        return firstError
    }

    private func run(_ command: CleanupCommand) -> DeletionResult.Status {
        guard let executable = commandResolver.resolve(command.executable) else {
            return .skipped(.blocked(.commandNotFound(command.executable)))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        // pnpm처럼 `#!/usr/bin/env node`로 시작하는 명령이 node를 찾을 수 있게 한다.
        environment["PATH"] = commandResolver.searchPaths.joined(separator: ":")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        let errorOutput = Pipe()
        process.standardError = errorOutput

        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let message = String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let lastLine = message.split(separator: "\n").last.map { ": \($0)" } ?? ""
            return .failed("종료 코드 \(process.terminationStatus)\(lastLine)")
        }
        return .commandSucceeded
    }

    static func freeBytes(at path: String = NSHomeDirectory()) -> Int64 {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}

extension PlannedDeletion.Blocker {
    public var explanation: String {
        switch self {
        case .policy(.outsideAllowedRoots): "허용한 위치 밖이라 지우지 않음"
        case .policy(.protectedPath): "보호하는 폴더라 지우지 않음"
        case .requiresAdministrator: "쓰기 권한이 없음 (관리자 권한 필요)"
        case .commandNotFound(let executable): "\(executable) 명령을 찾지 못함"
        case .applicationRunning(let bundleIdentifier): "\(bundleIdentifier) 실행 중 — 먼저 종료해야 함"
        }
    }
}

extension PlannedDeletion.Warning {
    public var explanation: String {
        switch self {
        case .applicationRunning(let bundleIdentifier): "\(bundleIdentifier) 실행 중"
        case .spaceFreedOnlyAfterEmptyingTrash: "휴지통을 비워야 공간이 생김"
        case .requiresAuthorization: "Finder가 관리자 암호를 물어봄"
        }
    }
}

extension DeletionResult.SkipReason {
    public var explanation: String {
        switch self {
        case .blocked(let blocker): blocker.explanation
        case .alreadyGone: "이미 없음"
        case .identityChanged: "계획한 뒤 다른 폴더로 바뀜"
        case .pathChanged: "경로 중간이 심볼릭 링크로 바뀜"
        case .cancelled: "취소됨"
        case .loggingFailed: "로그를 쓰지 못해 중단함"
        }
    }
}
