import Foundation

extension DeletionPolicy {
    /// 앱 제거용 정책. 앱 폴더와 `~/Library` 아래만 허용하고, 앱 데이터가 모이는 폴더 자체는 지우지 않는다.
    public static func applications(homeDirectory: String = NSHomeDirectory()) -> DeletionPolicy {
        let library = homeDirectory + "/Library"
        let protectedPaths = ["/Applications", "/Applications/Utilities", homeDirectory + "/Applications", library]
            + LeftoverFinder.locations.map { library + "/" + $0.folder }
        return DeletionPolicy(
            allowedRoots: ["/Applications", homeDirectory + "/Applications", library],
            protectedPaths: Set(protectedPaths)
        )
    }
}

extension DeletionTarget {
    /// 앱 번들을 휴지통으로 옮긴다. 앱이 실행 중이면 건너뛴다.
    public init(application: InstalledApplication) {
        self.init(
            path: application.path,
            identity: application.identity,
            method: .moveToTrash,
            title: application.name,
            allocatedBytes: application.allocatedBytes,
            unsharedBytes: application.unsharedBytes,
            conflictingApplications: application.bundleIdentifier.map { [$0] } ?? [],
            blocksWhileRunning: true
        )
    }

    /// 앱이 남긴 데이터를 휴지통으로 옮긴다. 앱이 실행 중이면 쓰고 있는 파일일 수 있어 건너뛴다.
    public init(leftover: ApplicationLeftover, of application: InstalledApplication) {
        self.init(
            path: leftover.path,
            identity: leftover.identity,
            method: .moveToTrash,
            title: "\(application.name) · \(leftover.location)",
            allocatedBytes: leftover.allocatedBytes,
            unsharedBytes: leftover.unsharedBytes,
            isDirectory: leftover.isDirectory,
            conflictingApplications: application.bundleIdentifier.map { [$0] } ?? [],
            blocksWhileRunning: true
        )
    }
}
