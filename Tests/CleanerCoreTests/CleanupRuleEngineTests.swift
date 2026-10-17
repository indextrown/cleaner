import Foundation
import Testing
@testable import CleanerCore

@Suite struct CleanupRuleEngineTests {
    /// fixture 전체를 스캔하고, `fixture/home`을 홈 디렉터리로 보고 규칙을 적용한다.
    private func evaluate(_ fixture: Fixture, projectRoots: [String]? = nil) async throws -> CleanupReport {
        let result = try await DiskScanner(options: ScanOptions(threadCount: 2)).scan(fixture.root)
        let engine = CleanupRuleEngine(homeDirectory: fixture.path("home"))
        return engine.evaluate(result, projectRoots: projectRoots ?? [fixture.root])
    }

    private func ruleIDs(_ report: CleanupReport) -> [String: String] {
        Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.path, $0.rule.id) })
    }

    @Test func requiresMarkerNextToArtifact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("web/package.json", bytes: 10)
        try fixture.file("web/node_modules/a/index.js", bytes: 1_000)
        try fixture.file("loose/node_modules/b/index.js", bytes: 1_000)

        let report = try await evaluate(fixture)

        #expect(ruleIDs(report) == [fixture.path("web/node_modules"): "npm.nodeModules"])
        #expect(report.candidates.first?.evidence == "옆에 package.json")
        #expect(report.rejected.map(\.path) == [fixture.path("loose/node_modules")])
        #expect(report.rejected.first?.reason == .missingMarker)
    }

    @Test func doesNotListArtifactsInsideArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("web/package.json", bytes: 10)
        try fixture.file("web/node_modules/pkg/package.json", bytes: 10)
        try fixture.file("web/node_modules/pkg/node_modules/dep/index.js", bytes: 1_000)

        let report = try await evaluate(fixture)

        #expect(report.candidates.map(\.path) == [fixture.path("web/node_modules")])
        #expect(report.rejected.isEmpty)
    }

    @Test func picksRuleByMarkerWhenNamesAreShared() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("gradle/build.gradle", bytes: 10)
        try fixture.file("gradle/build/out.class", bytes: 100)
        try fixture.file("flutter/pubspec.yaml", bytes: 10)
        try fixture.file("flutter/build/app.dill", bytes: 100)
        try fixture.file("tool/app.spec", bytes: 10)
        try fixture.file("tool/build/app.pkg", bytes: 100)
        try fixture.file("tool/dist/app", bytes: 100)
        try fixture.file("ios/App.xcodeproj/project.pbxproj", bytes: 10)
        try fixture.file("ios/build/App.o", bytes: 100)
        try fixture.file("pkg/pyproject.toml", bytes: 10)
        try fixture.file("pkg/dist/pkg-0.1.0-py3-none-any.whl", bytes: 100)
        try fixture.file("plain/build/notes.txt", bytes: 100)

        let report = try await evaluate(fixture)

        #expect(ruleIDs(report) == [
            fixture.path("gradle/build"): "gradle.build",
            fixture.path("flutter/build"): "flutter.build",
            fixture.path("tool/build"): "pyinstaller.build",
            fixture.path("tool/dist"): "pyinstaller.build",
            fixture.path("ios/build"): "xcode.projectBuild",
            fixture.path("pkg/dist"): "python.package",
        ])
        #expect(report.candidates.first { $0.path == fixture.path("ios/build") }?.evidence == "옆에 App.xcodeproj")
        #expect(report.rejected.map(\.path) == [fixture.path("plain/build")])
    }

    @Test func treatsVirtualEnvironmentAsReviewOnlyWithPyvenvCfg() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("crawler/.venv/pyvenv.cfg", bytes: 10)
        try fixture.file("crawler/.venv/lib/site.py", bytes: 1_000)
        try fixture.file("other/venv/lib/site.py", bytes: 1_000)
        // 이름이 제각각인 가상환경은 bin·lib과 pyvenv.cfg로 알아본다.
        for name in ["crawling", ".venv-wheel"] {
            try fixture.file("tools/\(name)/pyvenv.cfg", bytes: 10)
            try fixture.file("tools/\(name)/bin/python", bytes: 100)
            try fixture.file("tools/\(name)/lib/site.py", bytes: 100)
        }
        try fixture.file("tools/scripts/bin/run.sh", bytes: 100)
        try fixture.file("tools/scripts/lib/util.sh", bytes: 100)

        let report = try await evaluate(fixture)

        #expect(ruleIDs(report) == [
            fixture.path("crawler/.venv"): "python.venv",
            fixture.path("tools/crawling"): "python.venvAnyName",
            fixture.path("tools/.venv-wheel"): "python.venvAnyName",
        ])
        #expect(report.candidates.allSatisfy { $0.grade == .review })
        #expect(report.rejected.map(\.path) == [fixture.path("other/venv")])
    }

    @Test func groupsCandidatesByNearestGitRepository() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("mono/.git")
        for package in ["a", "b"] {
            try fixture.file("mono/packages/\(package)/package.json", bytes: 10)
            try fixture.file("mono/packages/\(package)/node_modules/x.js", bytes: 1_000)
        }
        try fixture.file("solo/package.json", bytes: 10)
        try fixture.file("solo/node_modules/x.js", bytes: 1_000)

        let report = try await evaluate(fixture)

        let groups = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.path, $0.group) })
        let mono = CleanupCandidate.Group.project(root: fixture.path("mono"), isGitRepository: true)
        #expect(groups[fixture.path("mono/packages/a/node_modules")] == mono)
        #expect(groups[fixture.path("mono/packages/b/node_modules")] == mono)
        #expect(groups[fixture.path("solo/node_modules")] == .project(root: fixture.path("solo"), isGitRepository: false))
    }

    @Test func appliesProjectRulesOnlyInsideProjectFolders() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("home/projects/app/package.json", bytes: 10)
        try fixture.file("home/projects/app/node_modules/x.js", bytes: 1_000)
        try fixture.file("home/.vscode/extensions/ext/package.json", bytes: 10)
        try fixture.file("home/.vscode/extensions/ext/node_modules/x.js", bytes: 1_000)
        try fixture.file("home/Library/Application Support/Tool/package.json", bytes: 10)
        try fixture.file("home/Library/Application Support/Tool/node_modules/x.js", bytes: 1_000)
        try fixture.file("home/projects/Tool.app/Contents/Resources/package.json", bytes: 10)
        try fixture.file("home/projects/Tool.app/Contents/Resources/node_modules/x.js", bytes: 1_000)
        let expected = [fixture.path("home/projects/app/node_modules")]

        let onlyProjects = try await evaluate(fixture, projectRoots: [fixture.path("home/projects")])
        #expect(onlyProjects.candidates.map(\.path) == expected)

        // 홈 전체를 프로젝트 폴더로 줘도 숨김 폴더, ~/Library, 앱 번들 안으로는 들어가지 않는다.
        let wholeHome = try await evaluate(fixture, projectRoots: [fixture.path("home")])
        #expect(wholeHome.candidates.map(\.path) == expected)
    }

    @Test func appliesLocationRulesToKnownCacheFolders() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("home/Library/Caches/com.apple.Safari/cache.db", bytes: 1_000)
        try fixture.file("home/Library/Caches/com.example.App/cache.db", bytes: 1_000)
        try fixture.file("home/.npm/_cacache/index", bytes: 1_000)
        try fixture.directory("existing/Live.xcodeproj")
        try writeDerivedData(fixture, "Gone-abc", workspace: fixture.path("missing/Gone.xcodeproj"))
        try writeDerivedData(fixture, "Live-def", workspace: fixture.path("existing/Live.xcodeproj"))

        let report = try await evaluate(fixture, projectRoots: [])

        let derivedData = fixture.path("home/Library/Developer/Xcode/DerivedData")
        #expect(ruleIDs(report) == [
            fixture.path("home/Library/Caches/com.example.App"): "apps.cache",
            fixture.path("home/.npm/_cacache"): "npm.cache",
            derivedData + "/Gone-abc": "xcode.derivedData",
            derivedData + "/Live-def": "xcode.derivedData",
        ])
        #expect(report.rejected.map(\.path) == [fixture.path("home/Library/Caches/com.apple.Safari")])
        #expect(report.rejected.first?.reason == .systemManaged)

        let gone = try #require(report.candidates.first { $0.path == derivedData + "/Gone-abc" })
        #expect(gone.workspacePath == fixture.path("missing/Gone.xcodeproj"))
        #expect(gone.isWorkspaceMissing)
        #expect(gone.group == .tool("Xcode"))
        let live = try #require(report.candidates.first { $0.path == derivedData + "/Live-def" })
        #expect(!live.isWorkspaceMissing)
    }

    @Test func recognizesSwiftPMBuildByContents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.directory("Demo/Demo.xcodeproj")
        try fixture.file("Demo/.build/build.db", bytes: 100)
        try fixture.file("Scripts/.build/DerivedData/app.o", bytes: 100)
        try fixture.file("Scripts/.build/smoke.png", bytes: 100)

        let report = try await evaluate(fixture)

        #expect(report.candidates.map(\.path) == [fixture.path("Demo/.build")])
        #expect(report.candidates.first?.evidence == "안에 build.db")
        #expect(report.rejected.map(\.path) == [fixture.path("Scripts/.build")])
    }

    @Test func gitFilterDowngradesCommittedDirectoriesToReview() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // 한글 폴더 이름을 NFD로 만든다. Finder로 만든 폴더처럼 디스크에는 NFD, git 출력은 NFC로 나온다.
        let web = "repo/" + "웹".decomposedStringWithCanonicalMapping
        try fixture.file("\(web)/package.json", bytes: 10)
        try fixture.file("\(web)/dist/index.js", bytes: 1_000)
        try fixture.file("\(web)/node_modules/x.js", bytes: 1_000)
        try "node_modules\n".write(toFile: fixture.path("repo/.gitignore"), atomically: true, encoding: .utf8)
        let repository = fixture.path("repo")
        try run("/usr/bin/git", "-C", repository, "init", "-q")
        try run("/usr/bin/git", "-C", repository, "add", ".")
        try run(
            "/usr/bin/git", "-C", repository,
            "-c", "user.name=Cleaner", "-c", "user.email=cleaner@example.com", "-c", "commit.gpgsign=false",
            "commit", "-qm", "init"
        )

        let report = try await evaluate(fixture)
        #expect(report.candidates.allSatisfy { $0.grade == .buildArtifact })

        let filtered = await GitTrackedFilter().apply(to: report)

        let grades = Dictionary(uniqueKeysWithValues: filtered.candidates.map { ($0.node.name, $0.grade) })
        #expect(grades == ["node_modules": .buildArtifact, "dist": .review])
        #expect(filtered.candidates.map(\.trackedFileCount) == [0, 1])
    }

    private func writeDerivedData(_ fixture: Fixture, _ name: String, workspace: String) throws {
        let folder = "home/Library/Developer/Xcode/DerivedData/\(name)"
        try fixture.file("\(folder)/Build/Products/App", bytes: 1_000)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["WorkspacePath": workspace],
            format: .xml,
            options: 0
        )
        try plist.write(to: URL(fileURLWithPath: fixture.path("\(folder)/info.plist")))
    }
}
