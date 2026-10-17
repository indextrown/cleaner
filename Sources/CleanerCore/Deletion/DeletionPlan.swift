import AppKit
import Darwin

/// 계획한 삭제 하나와 미리 확인한 문제.
public struct PlannedDeletion: Sendable, Identifiable {
    /// 실행하면 건너뛸 이유.
    public enum Blocker: Sendable, Equatable {
        case policy(DeletionPolicy.Violation)
        /// 쓰기 권한이 없다. 관리자 권한으로 지워야 한다.
        case requiresAdministrator
        case commandNotFound(String)
        /// 관련 앱이 실행 중이다. 앱을 종료한 뒤 다시 계획해야 한다.
        case applicationRunning(bundleIdentifier: String)
    }

    /// 실행은 하지만 알려 줄 점.
    public enum Warning: Sendable, Equatable {
        /// 이 항목을 쓰는 앱이 실행 중이다.
        case applicationRunning(bundleIdentifier: String)
        /// 휴지통을 비우기 전에는 공간이 생기지 않는다.
        case spaceFreedOnlyAfterEmptyingTrash
        /// 쓰기 권한이 없어 Finder가 관리자 암호를 묻는다.
        case requiresAuthorization
    }

    public let target: DeletionTarget
    public let blocker: Blocker?
    public let warnings: [Warning]

    public var id: String { target.id }
}

public struct DeletionPlan: Sendable {
    public let items: [PlannedDeletion]

    public init(items: [PlannedDeletion]) {
        self.items = items
    }

    /// 막힌 것 없이 실행할 항목.
    public var runnable: [PlannedDeletion] { items.filter { $0.blocker == nil } }
    public var blocked: [PlannedDeletion] { items.filter { $0.blocker != nil } }
    /// 실행할 항목의 할당 크기 합계. 비워질 수 있는 최대치다.
    public var allocatedBytes: Int64 { runnable.reduce(0) { $0 + $1.target.allocatedBytes } }
    /// 실행할 항목의 공유 제외 크기 합계. 확실히 비워지는 최소치다. 휴지통으로 옮기는 항목은 0으로 센다.
    public var unsharedBytes: Int64 {
        runnable.reduce(0) { $0 + ($1.target.method == .moveToTrash ? 0 : $1.target.unsharedBytes) }
    }
}

/// 실행 파일 이름을 절대 경로로 찾는다.
public struct CommandResolver: Sendable {
    public var searchPaths: [String]

    public init(searchPaths: [String] = CommandResolver.defaultSearchPaths) {
        self.searchPaths = searchPaths
    }

    /// 현재 PATH에 Homebrew 기본 위치를 더한다. 앱으로 실행하면 셸의 PATH를 물려받지 못하기 때문이다.
    public static var defaultSearchPaths: [String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return path.split(separator: ":").map(String.init) + extra
    }

    public func resolve(_ executable: String) -> String? {
        if executable.contains("/") {
            return access(executable, X_OK) == 0 ? executable : nil
        }
        return searchPaths.lazy
            .map { $0 + "/" + executable }
            .first { access($0, X_OK) == 0 }
    }
}

/// 삭제 대상을 미리 확인해 계획을 만든다. 파일 시스템을 바꾸지 않는다.
public struct DeletionPlanner: Sendable {
    public var policy: DeletionPolicy
    public var commandResolver: CommandResolver
    public var isApplicationRunning: @Sendable (String) -> Bool
    /// true면 쓰기 권한이 없는 휴지통 이동을 막지 않고 `requiresAuthorization`으로 표시한다.
    /// 실행할 때 `Deleter.authorizedTrash`(Finder 인증)가 있어야 한다.
    public var authorizesTrash: Bool

    public init(
        policy: DeletionPolicy = .cleanup(),
        commandResolver: CommandResolver = CommandResolver(),
        isApplicationRunning: @escaping @Sendable (String) -> Bool = DeletionPlanner.isRunning,
        authorizesTrash: Bool = false
    ) {
        self.policy = policy
        self.commandResolver = commandResolver
        self.isApplicationRunning = isApplicationRunning
        self.authorizesTrash = authorizesTrash
    }

    public static let isRunning: @Sendable (String) -> Bool = { bundleIdentifier in
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    public func plan(_ targets: [DeletionTarget]) -> DeletionPlan {
        DeletionPlan(items: targets.map(check))
    }

    private func check(_ target: DeletionTarget) -> PlannedDeletion {
        var blocker: PlannedDeletion.Blocker?
        var warnings: [PlannedDeletion.Warning] = []
        if let violation = policy.violation(for: target) {
            blocker = .policy(violation)
        } else {
            switch target.method {
            case .remove, .moveToTrash:
                if !Self.isWritable(target.path) {
                    if target.method == .moveToTrash && authorizesTrash {
                        warnings.append(.requiresAuthorization)
                    } else {
                        blocker = .requiresAdministrator
                    }
                }
            case .command(let command):
                if commandResolver.resolve(command.executable) == nil {
                    blocker = .commandNotFound(command.executable)
                }
            }
        }

        let running = target.conflictingApplications.filter(isApplicationRunning)
        if target.blocksWhileRunning, let bundleIdentifier = running.first {
            blocker = blocker ?? .applicationRunning(bundleIdentifier: bundleIdentifier)
        } else {
            warnings += running.map { .applicationRunning(bundleIdentifier: $0) }
        }
        if target.method == .moveToTrash {
            warnings.append(.spaceFreedOnlyAfterEmptyingTrash)
        }
        return PlannedDeletion(target: target, blocker: blocker, warnings: warnings)
    }

    /// 지우거나 옮기려면 대상과 부모 모두에 쓰기 권한이 있어야 한다. 디렉터리를 다른 부모로 옮기면 `..`도 바뀌기 때문이다.
    static func isWritable(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return access(parent, W_OK) == 0 && access(path, W_OK) == 0
    }
}
