import Darwin
import Foundation
import Testing
@testable import CleanerCore

@Suite struct ApplicationTests {
    /// Info.plist와 실행 파일을 가진 가짜 앱 번들을 만든다.
    private func makeApp(
        _ fixture: Fixture,
        _ relativePath: String,
        id: String,
        version: String = "1.0",
        bytes: Int = 100_000,
        appStore: Bool = false
    ) throws {
        let name = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        try fixture.file("\(relativePath)/Contents/MacOS/\(name)", bytes: bytes)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": version],
            format: .xml,
            options: 0
        )
        try info.write(to: URL(fileURLWithPath: fixture.path("\(relativePath)/Contents/Info.plist")))
        if appStore {
            try fixture.file("\(relativePath)/Contents/_MASReceipt/receipt", bytes: 100)
        }
    }

    private func inventory(_ fixture: Fixture) -> ApplicationInventory {
        ApplicationInventory(
            searchRoots: [fixture.path("Applications"), fixture.path("home/Applications")],
            readsSpotlight: false,
            scanner: DiskScanner(options: ScanOptions(threadCount: 2))
        )
    }

    private func application(
        _ name: String,
        bytes: Int64 = 0,
        unshared: Int64 = 0,
        added: Date? = nil,
        used: Date? = nil
    ) -> InstalledApplication {
        InstalledApplication(
            path: "/Applications/\(name).app", name: name, bundleIdentifier: nil, version: nil,
            identity: FileIdentity(device: 0, fileID: 0), allocatedBytes: bytes, unsharedBytes: unshared,
            addedDate: added, lastUsedDate: used, isFromAppStore: false
        )
    }

    @Test func findsAppsInFoldersButNotInsideBundles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeApp(fixture, "Applications/Foo.app", id: "com.example.foo", version: "1.2", bytes: 300_000)
        try makeApp(fixture, "Applications/Foo.app/Contents/Helpers/Helper.app", id: "com.example.foo.helper")
        try makeApp(fixture, "Applications/Utilities/Bar.app", id: "com.example.bar", appStore: true)
        try makeApp(fixture, "Applications/Vendor/Suite/Deep.app", id: "com.example.deep")
        try makeApp(fixture, "Applications/Vendor/Suite/Extras/TooDeep.app", id: "com.example.toodeep")
        try makeApp(fixture, "Applications/.hidden/Hidden.app", id: "com.example.hidden")
        try makeApp(fixture, "home/Applications/Baz.app", id: "com.example.baz")
        #expect(symlink(fixture.path("Applications/Foo.app"), fixture.path("Applications/Linked.app")) == 0)
        try fixture.file("Applications/notes.txt", bytes: 10)

        let applications = try await inventory(fixture).applications()

        #expect(Set(applications.map(\.name)) == ["Foo", "Bar", "Deep", "Baz"])
        let foo = try #require(applications.first { $0.name == "Foo" })
        #expect(foo.bundleIdentifier == "com.example.foo")
        #expect(foo.version == "1.2")
        #expect(foo.addedDate != nil)
        #expect(!foo.isFromAppStore)
        let fooScan = try await DiskScanner().scan(fixture.path("Applications/Foo.app"))
        #expect(foo.allocatedBytes == fooScan.root.totalBytes)
        #expect(foo.identity.fileID == fooScan.root.fileID)
        #expect(applications.first { $0.name == "Bar" }?.isFromAppStore == true)
    }

    @Test func sortsByEachKeyWithMissingDatesLast() {
        let day1 = Date(timeIntervalSince1970: 1_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        let day3 = day2.addingTimeInterval(86_400)
        let apps = [
            application("Alpha", bytes: 300, unshared: 10, added: day2, used: nil),
            application("beta", bytes: 100, unshared: 90, added: day1, used: day3),
            application("Gamma", bytes: 200, unshared: 50, added: nil, used: day1),
        ]
        func names(_ key: ApplicationSortKey, _ order: SortOrder) -> [String] {
            apps.sorted(by: key, order).map(\.name)
        }

        #expect(names(.name, .forward) == ["Alpha", "beta", "Gamma"])
        #expect(names(.name, .reverse) == ["Gamma", "beta", "Alpha"])
        #expect(names(.size, .reverse) == ["Alpha", "Gamma", "beta"])
        #expect(names(.size, .forward) == ["beta", "Gamma", "Alpha"])
        #expect(names(.unsharedSize, .reverse) == ["beta", "Gamma", "Alpha"])
        #expect(names(.added, .forward) == ["beta", "Alpha", "Gamma"])
        #expect(names(.added, .reverse) == ["Alpha", "beta", "Gamma"])
        #expect(names(.lastUsed, .reverse) == ["beta", "Gamma", "Alpha"])
        #expect(names(.lastUsed, .forward) == ["Gamma", "beta", "Alpha"])
    }

    /// `~/Library`에 남는 데이터를 흉내 낸다. 앞의 것은 Foo의 것이고, 뒤의 것은 이름만 비슷하다.
    private func makeLeftovers(_ fixture: Fixture) throws -> String {
        let host = UUID().uuidString
        for directory in [
            "Application Support/com.example.foo", "Application Support/Foo", "Caches/com.example.foo",
            "Containers/com.example.foo/Data", "Group Containers/ABCDE12345.com.example.foo",
            "Saved Application State/com.example.foo.savedState",
            "Caches/com.example.foobar", "Application Support/Other",
        ] {
            try fixture.file("home/Library/\(directory)/blob", bytes: 10_000)
        }
        for file in [
            "Preferences/com.example.foo.plist", "Preferences/ByHost/com.example.foo.\(host).plist",
            "LaunchAgents/com.example.foo.updater.plist",
            "Preferences/ByHost/com.example.foo.helper.plist", "LaunchAgents/com.example.foo.pro.agent.plist",
        ] {
            try fixture.file("home/Library/\(file)", bytes: 100)
        }
        return host
    }

    @Test func findsLeftoversByBundleIdentifierAndName() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeApp(fixture, "Applications/Foo.app", id: "com.example.foo")
        let host = try makeLeftovers(fixture)
        let foo = try #require(try await inventory(fixture).applications().first)

        let leftovers = await LeftoverFinder(homeDirectory: fixture.path("home"))
            .leftovers(for: foo, otherBundleIdentifiers: ["com.example.foo.pro"])

        let library = fixture.path("home/Library") + "/"
        let matches = Dictionary(uniqueKeysWithValues: leftovers.map { (String($0.path.dropFirst(library.count)), $0.match) })
        #expect(matches == [
            "Application Support/com.example.foo": .bundleIdentifier,
            "Application Support/Foo": .appName,
            "Caches/com.example.foo": .bundleIdentifier,
            "Containers/com.example.foo": .bundleIdentifier,
            "Group Containers/ABCDE12345.com.example.foo": .bundleIdentifier,
            "Saved Application State/com.example.foo.savedState": .bundleIdentifier,
            "Preferences/com.example.foo.plist": .bundleIdentifier,
            "Preferences/ByHost/com.example.foo.\(host).plist": .bundleIdentifier,
            "LaunchAgents/com.example.foo.updater.plist": .bundleIdentifier,
        ])
        let caches = try #require(leftovers.first { $0.location == "Caches" })
        #expect(caches.isDirectory)
        #expect(caches.allocatedBytes == fixture.allocatedBytes("home/Library/Caches/com.example.foo/blob"))
        #expect(leftovers.first { $0.location == "Preferences" }?.isDirectory == false)
    }

    private func uninstallPlan(
        _ fixture: Fixture,
        running: Set<String> = []
    ) async throws -> (plan: DeletionPlan, deleter: Deleter) {
        let foo = try #require(try await inventory(fixture).applications().first)
        // makeLeftovers는 com.example.foo.pro의 파일도 만든다. CLI처럼 설치된 다른 앱의 번들 ID를 넘긴다.
        let leftovers = await LeftoverFinder(homeDirectory: fixture.path("home"))
            .leftovers(for: foo, otherBundleIdentifiers: ["com.example.foo.pro"])
        let targets = [DeletionTarget(application: foo)]
            + leftovers.filter { $0.match == .bundleIdentifier }.map { DeletionTarget(leftover: $0, of: foo) }
        let policy = DeletionPolicy(allowedRoots: [fixture.root], protectedPaths: [fixture.root])
        let plan = DeletionPlanner(policy: policy, isApplicationRunning: { running.contains($0) }).plan(targets)
        let deleter = Deleter(
            policy: policy,
            trash: FixtureTrash(directory: fixture.path("trash")),
            logDirectory: fixture.path("logs")
        )
        return (plan, deleter)
    }

    @Test func uninstallMovesAppAndItsDataToTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeApp(fixture, "Applications/Foo.app", id: "com.example.foo")
        _ = try makeLeftovers(fixture)

        let (plan, deleter) = try await uninstallPlan(fixture)
        let report = try await deleter.execute(plan)

        #expect(plan.items.count == 9)
        #expect(plan.blocked.isEmpty)
        #expect(report.results.allSatisfy {
            if case .movedToTrash = $0.status { true } else { false }
        })
        let manager = FileManager.default
        #expect(!manager.fileExists(atPath: fixture.path("Applications/Foo.app")))
        #expect(!manager.fileExists(atPath: fixture.path("home/Library/Preferences/com.example.foo.plist")))
        #expect(manager.fileExists(atPath: fixture.path("trash/Foo.app/Contents/Info.plist")))
        // 이름만 같은 폴더와 다른 앱의 데이터는 남는다.
        #expect(manager.fileExists(atPath: fixture.path("home/Library/Application Support/Foo/blob")))
        #expect(manager.fileExists(atPath: fixture.path("home/Library/Caches/com.example.foobar/blob")))
    }

    @Test func blocksUninstallWhileAppIsRunning() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeApp(fixture, "Applications/Foo.app", id: "com.example.foo")
        try fixture.file("home/Library/Caches/com.example.foo/blob", bytes: 1_000)

        let (plan, _) = try await uninstallPlan(fixture, running: ["com.example.foo"])

        #expect(plan.items.map(\.blocker) == Array(
            repeating: .applicationRunning(bundleIdentifier: "com.example.foo"),
            count: 2
        ))
    }

    @Test func skipsFileReplacedByDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeApp(fixture, "Applications/Foo.app", id: "com.example.foo")
        try fixture.file("home/Library/Preferences/com.example.foo.plist", bytes: 100)
        let (plan, deleter) = try await uninstallPlan(fixture)

        let preferences = fixture.path("home/Library/Preferences/com.example.foo.plist")
        try FileManager.default.removeItem(atPath: preferences)
        try fixture.directory("home/Library/Preferences/com.example.foo.plist")
        let report = try await deleter.execute(plan)

        #expect(report.results.first { $0.item.target.path == preferences }?.status == .skipped(.identityChanged))
    }

    @Test func applicationPolicyProtectsSharedFolders() {
        let policy = DeletionPolicy.applications(homeDirectory: "/Users/me")

        #expect(policy.violation(for: "/Applications/Foo.app") == nil)
        #expect(policy.violation(for: "/Users/me/Applications/Foo.app") == nil)
        #expect(policy.violation(for: "/Users/me/Library/Caches/com.example.foo") == nil)
        #expect(policy.violation(for: "/Applications") == .protectedPath)
        #expect(policy.violation(for: "/Applications/Utilities") == .protectedPath)
        #expect(policy.violation(for: "/Users/me/Library/Caches") == .protectedPath)
        #expect(policy.violation(for: "/Users/me/Library/Preferences/ByHost") == .protectedPath)
        #expect(policy.violation(for: "/System/Applications/Notes.app") == .outsideAllowedRoots)
        #expect(policy.violation(for: "/Library/Caches/com.example.foo") == .outsideAllowedRoots)
    }
}
