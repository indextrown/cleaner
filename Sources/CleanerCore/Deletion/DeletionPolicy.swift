import Foundation

/// 어디까지 지울 수 있는지 정한 경계. 계획할 때와 지우기 직전에 두 번 확인한다.
public struct DeletionPolicy: Sendable {
    public enum Violation: Sendable, Equatable {
        /// 허용한 루트 아래가 아니다.
        case outsideAllowedRoots
        /// 그 자체를 지우면 안 되는 경로다(홈, ~/Library 등).
        case protectedPath
    }

    /// 이 경로들보다 아래에 있는 것만 지운다. 루트 자체는 지우지 않는다.
    public var allowedRoots: [String]
    /// 허용한 루트 아래에 있더라도 그 자체는 지우지 않는 경로.
    public var protectedPaths: Set<String>

    public init(allowedRoots: [String], protectedPaths: Set<String>) {
        self.allowedRoots = allowedRoots
        self.protectedPaths = protectedPaths
    }

    /// 정리 후보용 기본 정책. 홈, 시뮬레이터 폴더, 사용자 캐시 폴더(`/var/folders/…/C`) 아래만 허용하고,
    /// 그 폴더들과 홈의 주요 폴더 자체는 지우지 않는다.
    public static func cleanup(
        homeDirectory: String = NSHomeDirectory(),
        userCacheDirectory: String? = UserDirectories.cacheDirectory
    ) -> DeletionPolicy {
        let homeFolders = [
            "", "/Library", "/Library/Caches", "/Library/Application Support", "/Library/Developer",
            "/Library/Developer/Xcode", "/Library/Developer/CoreSimulator", "/Library/Containers",
            "/Library/Group Containers", "/Library/Mobile Documents", "/Library/CloudStorage",
            "/Library/Preferences", "/Documents", "/Desktop", "/Downloads", "/Pictures", "/Movies",
            "/Music", "/Applications", "/.Trash",
        ]
        let userCache = userCacheDirectory.map { [$0] } ?? []
        return DeletionPolicy(
            allowedRoots: [homeDirectory, "/Library/Developer/CoreSimulator"] + userCache,
            protectedPaths: Set(homeFolders.map { homeDirectory + $0 } + userCache)
        )
    }

    /// 공식 명령은 경로를 직접 지우지 않고 도구가 정한 것만 정리하므로 허용 범위를 보지 않는다.
    /// 명령은 코드에 적힌 규칙에서만 오고, 경로는 표시와 "계획한 그대로인지" 확인에만 쓴다.
    public func violation(for target: DeletionTarget) -> Violation? {
        if case .command = target.method { return nil }
        return violation(for: target.path)
    }

    public func violation(for path: String) -> Violation? {
        let path = Self.normalized(path)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        // 절대 경로가 아니거나 `..`, `.`, 빈 요소가 섞이면 접두어 비교를 믿을 수 없다.
        guard path.hasPrefix("/"), !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return .outsideAllowedRoots
        }
        if protectedPaths.contains(path) {
            return .protectedPath
        }
        guard allowedRoots.contains(where: { path.hasPrefix($0 + "/") }) else {
            return .outsideAllowedRoots
        }
        return nil
    }

    /// 데이터 볼륨을 스캔하면 경로가 `/System/Volumes/Data/Users/...`로 나온다. 정책은 `/Users/...` 기준으로 본다.
    static func normalized(_ path: String) -> String {
        let dataVolume = "/System/Volumes/Data"
        return path.hasPrefix(dataVolume + "/") ? String(path.dropFirst(dataVolume.count)) : path
    }
}
