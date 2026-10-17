import Darwin
import Foundation
import Testing
@testable import CleanerCore

@Suite struct DeleterTests {
    /// fixture를 스캔하고 `fixture/projects`를 프로젝트 폴더, `fixture/home`을 홈으로 보고 계획을 만든다.
    private func plan(
        _ fixture: Fixture,
        rules: [CleanupRule] = .defaults,
        policy: DeletionPolicy? = nil,
        moveToTrash: Bool = false,
        running: Set<String> = []
    ) async throws -> DeletionPlan {
        let result = try await DiskScanner(options: ScanOptions(threadCount: 2)).scan(fixture.root)
        let report = CleanupRuleEngine(rules: rules, homeDirectory: fixture.path("home"))
            .evaluate(result, projectRoots: [fixture.path("projects")])
        let targets = report.candidates.map {
            DeletionTarget(candidate: $0, moveToTrash: moveToTrash)
        }
        let planner = DeletionPlanner(
            policy: policy ?? fixturePolicy(fixture),
            isApplicationRunning: { running.contains($0) }
        )
        return planner.plan(targets)
    }

    private func fixturePolicy(_ fixture: Fixture) -> DeletionPolicy {
        DeletionPolicy(allowedRoots: [fixture.root], protectedPaths: [fixture.root])
    }

    private func deleter(_ fixture: Fixture, policy: DeletionPolicy? = nil) -> Deleter {
        Deleter(
            policy: policy ?? fixturePolicy(fixture),
            trash: FixtureTrash(directory: fixture.path("trash")),
            logDirectory: fixture.path("logs")
        )
    }

    private func makeWebProject(_ fixture: Fixture) throws {
        try fixture.file("projects/web/package.json", bytes: 10)
        try fixture.file("projects/web/node_modules/a/index.js", bytes: 100_000)
    }

    private func logRecords(_ report: DeletionReport) throws -> [[String: Any]] {
        let path = try #require(report.logPath)
        return try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n")
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    @Test func removesPlannedDirectoryAndLogsEachStep() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWebProject(fixture)

        let plan = try await plan(fixture)
        let report = try await deleter(fixture).execute(plan)

        #expect(report.results.map(\.status) == [.removed])
        #expect(!FileManager.default.fileExists(atPath: fixture.path("projects/web/node_modules")))
        #expect(FileManager.default.fileExists(atPath: fixture.path("projects/web/package.json")))

        let records = try logRecords(report)
        #expect(records.map { $0["type"] as? String } == ["start", "item", "finish"])
        #expect(records[1]["path"] as? String == fixture.path("projects/web/node_modules"))
        #expect(records[1]["status"] as? String == "removed")
        #expect(records[1]["method"] as? String == "remove")
        #expect(records[1]["ruleID"] as? String == "npm.nodeModules")
    }

    @Test func planningDoesNotTouchFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWebProject(fixture)

        let plan = try await plan(fixture)

        #expect(plan.runnable.count == 1)
        #expect(plan.allocatedBytes == plan.items[0].target.allocatedBytes)
        #expect(FileManager.default.fileExists(atPath: fixture.path("projects/web/node_modules/a/index.js")))
        #expect(!FileManager.default.fileExists(atPath: fixture.path("logs")))
    }

    @Test func skipsDirectoryRecreatedAfterPlanning() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWebProject(fixture)
        let plan = try await plan(fixture)

        try FileManager.default.removeItem(atPath: fixture.path("projects/web/node_modules"))
        try fixture.file("projects/web/node_modules/new.js", bytes: 10)
        let report = try await deleter(fixture).execute(plan)

        #expect(report.results.map(\.status) == [.skipped(.identityChanged)])
        #expect(FileManager.default.fileExists(atPath: fixture.path("projects/web/node_modules/new.js")))
    }

    @Test func skipsDirectoryReplacedBySymlink() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWebProject(fixture)
        try fixture.file("precious/keep.txt", bytes: 10)
        let plan = try await plan(fixture)

        let nodeModules = fixture.path("projects/web/node_modules")
        try FileManager.default.moveItem(atPath: nodeModules, toPath: nodeModules + "-old")
        #expect(symlink(fixture.path("precious"), nodeModules) == 0)
        let report = try await deleter(fixture).execute(plan)

        #expect(report.results.map(\.status) == [.skipped(.identityChanged)])
        #expect(FileManager.default.fileExists(atPath: fixture.path("precious/keep.txt")))
    }

    @Test func skipsWhenParentPathBecomesSymlink() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWebProject(fixture)
        let plan = try await plan(fixture)

        // 디렉터리를 옮기고 그 자리에 링크를 두면 inode는 같지만 경로가 다른 곳을 가리킨다.
        try FileManager.default.moveItem(atPath: fixture.path("projects/web"), toPath: fixture.path("projects/web-real"))
        #expect(symlink(fixture.path("projects/web-real"), fixture.path("projects/web")) == 0)
        let report = try await deleter(fixture).execute(plan)

        #expect(report.results.map(\.status) == [.skipped(.pathChanged)])
        #expect(FileManager.default.fileExists(atPath: fixture.path("projects/web-real/node_modules/a/index.js")))
    }

    @Test func blocksPathsOutsidePolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWebProject(fixture)
        let policy = DeletionPolicy(allowedRoots: [fixture.path("home")], protectedPaths: [])

        let plan = try await plan(fixture, policy: policy)
        let report = try await deleter(fixture, policy: policy).execute(plan)

        #expect(plan.items.map(\.blocker) == [.policy(.outsideAllowedRoots)])
        #expect(report.results.map(\.status) == [.skipped(.blocked(.policy(.outsideAllowedRoots)))])
        #expect(FileManager.default.fileExists(atPath: fixture.path("projects/web/node_modules/a/index.js")))
    }

    @Test func policyAcceptsOnlyPathsStrictlyInsideAllowedRoots() {
        let policy = DeletionPolicy(allowedRoots: ["/Users/me"], protectedPaths: ["/Users/me", "/Users/me/Library"])

        #expect(policy.violation(for: "/Users/me/2025/web/node_modules") == nil)
        #expect(policy.violation(for: "/System/Volumes/Data/Users/me/2025/node_modules") == nil)
        #expect(policy.violation(for: "/Users/me") == .protectedPath)
        #expect(policy.violation(for: "/Users/me/Library") == .protectedPath)
        #expect(policy.violation(for: "/Users/meow/node_modules") == .outsideAllowedRoots)
        #expect(policy.violation(for: "/Users/me/../other/node_modules") == .outsideAllowedRoots)
        #expect(policy.violation(for: "/Users/me/web/") == .outsideAllowedRoots)
        #expect(policy.violation(for: "Users/me/web") == .outsideAllowedRoots)
    }

    @Test func movesToTrashWhenRequested() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWebProject(fixture)

        let plan = try await plan(fixture, moveToTrash: true)
        let report = try await deleter(fixture).execute(plan)

        #expect(plan.items.first?.warnings == [.spaceFreedOnlyAfterEmptyingTrash])
        #expect(plan.unsharedBytes == 0)
        #expect(report.results.map(\.status) == [.movedToTrash(to: fixture.path("trash/node_modules"))])
        #expect(!FileManager.default.fileExists(atPath: fixture.path("projects/web/node_modules")))
        #expect(FileManager.default.fileExists(atPath: fixture.path("trash/node_modules/a/index.js")))
    }

    private func commandRule(_ executable: String, _ arguments: [String] = []) -> [CleanupRule] {
        [CleanupRule(
            id: "test.command", tool: "Test", title: "명령 테스트", grade: .cache, restore: "",
            scope: .location(".tool-cache"),
            command: CleanupCommand(executable: executable, arguments: arguments, summary: "테스트")
        )]
    }

    @Test func runsCommandInsteadOfDeleting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("home/.tool-cache/blob", bytes: 1_000)

        let plan = try await plan(fixture, rules: commandRule("/usr/bin/touch", [fixture.path("ran")]))
        let report = try await deleter(fixture).execute(plan)

        #expect(report.results.map(\.status) == [.commandSucceeded])
        #expect(FileManager.default.fileExists(atPath: fixture.path("ran")))
        #expect(FileManager.default.fileExists(atPath: fixture.path("home/.tool-cache/blob")))
        #expect(try logRecords(report)[1]["command"] as? String == "/usr/bin/touch \(fixture.path("ran"))")
    }

    @Test func reportsFailingCommand() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("home/.tool-cache/blob", bytes: 1_000)

        let plan = try await plan(fixture, rules: commandRule("/usr/bin/false"))
        let report = try await deleter(fixture).execute(plan)

        #expect(report.results.map(\.status) == [.failed("종료 코드 1")])
    }

    @Test func blocksMissingCommand() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("home/.tool-cache/blob", bytes: 1_000)

        let plan = try await plan(fixture, rules: commandRule("cleaner-no-such-command"))
        let report = try await deleter(fixture).execute(plan)

        #expect(plan.items.map(\.blocker) == [.commandNotFound("cleaner-no-such-command")])
        #expect(report.results.map(\.status) == [.skipped(.blocked(.commandNotFound("cleaner-no-such-command")))])
    }

    @Test func blocksWhenParentIsNotWritable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWebProject(fixture)
        fixture.setMode("projects/web", 0o555)

        let plan = try await plan(fixture)

        #expect(plan.items.map(\.blocker) == [.requiresAdministrator])
    }

    @Test func reportsFailureWhenSubdirectoryCannotBeEmptied() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWebProject(fixture)
        try fixture.file("projects/web/node_modules/locked/file.js", bytes: 10)
        fixture.setMode("projects/web/node_modules/locked", 0o555)

        let plan = try await plan(fixture)
        let report = try await deleter(fixture).execute(plan)

        #expect(report.results.map(\.status) == [.failed(String(cString: strerror(EACCES)))])
        #expect(FileManager.default.fileExists(atPath: fixture.path("projects/web/node_modules/locked/file.js")))
    }

    @Test func doesNotDeleteIntoMountedVolume() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWebProject(fixture)
        let mountPoint = try fixture.directory("projects/web/node_modules/mnt")
        let image = fixture.path("volume.dmg")
        try run("/usr/bin/hdiutil", "create", "-size", "8m", "-fs", "APFS", "-volname", "CleanerTest", image)
        try run("/usr/bin/hdiutil", "attach", image, "-mountpoint", mountPoint, "-nobrowse")
        defer { _ = try? run("/usr/bin/hdiutil", "detach", mountPoint, "-force") }
        try fixture.file("projects/web/node_modules/mnt/inside.bin", bytes: 1_000)

        let plan = try await plan(fixture)
        let report = try await deleter(fixture).execute(plan)

        guard case .failed = report.results.first?.status else {
            Issue.record("마운트 지점이 남아 있으므로 실패해야 한다: \(String(describing: report.results.first?.status))")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.path("projects/web/node_modules/mnt/inside.bin")))
        #expect(!FileManager.default.fileExists(atPath: fixture.path("projects/web/node_modules/a/index.js")))
    }

    @Test func warnsWhenRelatedApplicationIsRunning() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("projects/ios/App.xcodeproj")
        try fixture.file("projects/ios/build/App.o", bytes: 1_000)

        let plan = try await plan(fixture, running: ["com.apple.dt.Xcode"])

        #expect(plan.items.first?.target.ruleID == "xcode.projectBuild")
        #expect(plan.items.first?.warnings == [.applicationRunning(bundleIdentifier: "com.apple.dt.Xcode")])
        #expect(plan.items.first?.blocker == nil)
    }
}
