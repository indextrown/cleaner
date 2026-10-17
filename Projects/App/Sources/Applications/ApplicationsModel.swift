import CleanerCore
import Darwin
import Foundation
import Observation

@Observable
@MainActor
final class ApplicationsModel {
    private(set) var applications: [InstalledApplication] = []
    var sortOrder = [ApplicationComparator(.size, order: .reverse)]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// 실행 중인 앱의 번들 ID. 목록을 읽을 때와 제거 창을 열 때 새로 확인한다.
    private(set) var runningIdentifiers: Set<String> = []
    var lastActionMessage: String?

    var totalBytes: Int64 { applications.reduce(0) { $0 + $1.allocatedBytes } }

    var bundleIdentifiers: Set<String> { Set(applications.compactMap(\.bundleIdentifier)) }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            applications = try await BackgroundActivity.run("앱 목록 읽기") {
                try await ApplicationInventory().applications()
            }
            .sorted(using: sortOrder)
            refreshRunning()
        } catch {
            errorMessage = Format.describe(error)
        }
    }

    func applySort() {
        applications.sort(using: sortOrder)
    }

    func refreshRunning() {
        runningIdentifiers = Set(applications.compactMap(\.bundleIdentifier).filter(DeletionPlanner.isRunning))
    }

    func isRunning(_ application: InstalledApplication) -> Bool {
        application.bundleIdentifier.map(runningIdentifiers.contains) ?? false
    }

    /// 앱이나 앱이 든 폴더에 쓰기 권한이 없다. App Store 앱은 보통 root 소유라 Finder가 암호를 묻는다.
    func needsPassword(_ application: InstalledApplication) -> Bool {
        let parent = (application.path as NSString).deletingLastPathComponent
        // @Observable이 만드는 access(keyPath:)와 구분하려고 모듈 이름을 붙인다.
        return Darwin.access(application.path, W_OK) != 0 || Darwin.access(parent, W_OK) != 0
    }

    /// 휴지통으로 옮긴 앱을 목록에서 뺀다.
    func finish(_ report: DeletionReport) {
        let moved = Set(report.results.filter(\.status.succeeded).map(\.item.target.path))
        applications.removeAll { moved.contains($0.path) }
        lastActionMessage = report.summary + " · 휴지통을 비우면 공간이 생깁니다."
    }
}
