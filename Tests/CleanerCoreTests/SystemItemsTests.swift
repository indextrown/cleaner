import Foundation
import Testing
@testable import CleanerCore

@Suite struct SystemItemsTests {
    @Test func findsLocationsOutsideTheScannedTree() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cacheDirectory = fixture.path("var/folders/C")
        try fixture.file("home/projects/app/package.json", bytes: 10)
        try fixture.file("var/folders/C/com.apple.dt.Instruments/symbols.db", bytes: 100_000)
        try fixture.file("var/folders/C/com.example.tool/cache.bin", bytes: 10_000)
        try fixture.file("var/folders/C/com.apple.metal/shader.bin", bytes: 10_000)
        let rules = [
            CleanupRule(
                id: "test.instruments", tool: "Xcode", title: "Instruments", grade: .cache, restore: "",
                scope: .location(cacheDirectory + "/com.apple.dt.Instruments")
            ),
            CleanupRule(
                id: "test.userCaches", tool: "앱 캐시", title: "임시 캐시", grade: .cache, restore: "",
                scope: .contentsOf(cacheDirectory, skippingPrefixes: ["com.apple."])
            ),
        ]
        let engine = CleanupRuleEngine(rules: rules, homeDirectory: fixture.path("home"))
        let home = try await DiskScanner(options: ScanOptions(threadCount: 2)).scan(fixture.path("home"))

        // 홈 트리만으로는 홈 밖 캐시를 찾지 못한다.
        #expect(engine.evaluate(home, projectRoots: []).candidates.isEmpty)
        // 바깥 경로 안에 든 경로는 바깥을 스캔하면 함께 들어오므로 한 번만 스캔한다.
        #expect(engine.locationPaths(outside: home.root.name) == [cacheDirectory])

        let report = await engine.evaluateLocations(outside: home.root.name, scanner: DiskScanner(options: ScanOptions(threadCount: 2)))

        let ids = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.path, $0.rule.id) })
        #expect(ids == [
            cacheDirectory + "/com.apple.dt.Instruments": "test.instruments",
            cacheDirectory + "/com.example.tool": "test.userCaches",
        ])
        #expect(report.rejected.map(\.path) == [cacheDirectory + "/com.apple.metal"])
    }

    @Test func skipsLocationsInsideProjectRootsAndExcludedFolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for folder in ["home/projects/.cache-a", "home/Library/Caches/app", "home/Library/Containers/x/Caches", "other/C"] {
            try fixture.directory(folder)
        }
        let rules = [
            ("projects/.cache-a", "a"), ("Library/Caches", "b"), ("Library/Containers/x/Caches", "c"),
        ].map { path, id in
            CleanupRule(id: id, tool: "T", title: id, grade: .cache, restore: "", scope: .location(path))
        } + [CleanupRule(id: "d", tool: "T", title: "d", grade: .cache, restore: "", scope: .location(fixture.path("other/C")))]
        let engine = CleanupRuleEngine(rules: rules, homeDirectory: fixture.path("home"))

        let paths = engine.locationPaths(
            outside: [fixture.path("home/projects"), fixture.path("elsewhere")],
            excludedPaths: [fixture.path("home/Library/Containers")]
        )

        #expect(paths == [fixture.path("home/Library/Caches"), fixture.path("other/C")])
    }

    @Test func findsCachesNestedInsideEachAppFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for folder in ["Discord/Cache", "Discord/Code Cache", "Discord/Local Storage", "Code/CachedData", "Notes/Data"] {
            try fixture.file("home/Library/Application Support/\(folder)/blob", bytes: 10_000)
        }
        let rule = try #require([CleanupRule].defaults.first { $0.id == "apps.electronCache" })
        let scan = try await DiskScanner(options: ScanOptions(threadCount: 2)).scan(fixture.root)

        let report = CleanupRuleEngine(rules: [rule], homeDirectory: fixture.path("home")).evaluate(scan, projectRoots: [])

        let support = fixture.path("home/Library/Application Support")
        #expect(Set(report.candidates.map(\.path)) == [
            support + "/Discord/Cache", support + "/Discord/Code Cache", support + "/Code/CachedData",
        ])
        #expect(report.candidates.allSatisfy { $0.device == scan.device })
    }

    @Test func commandsAreNotLimitedToAllowedRoots() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("outside/runtime.dmg", bytes: 1_000)
        var info = stat()
        #expect(lstat(fixture.path("outside/runtime.dmg"), &info) == 0)
        let identity = FileIdentity(device: info.st_dev, fileID: info.st_ino)
        let policy = DeletionPolicy(allowedRoots: [fixture.path("home")], protectedPaths: [])
        func target(_ method: DeletionTarget.Method) -> DeletionTarget {
            DeletionTarget(
                path: fixture.path("outside/runtime.dmg"), identity: identity, method: method, title: "런타임",
                allocatedBytes: 1_000, unsharedBytes: 1_000, isDirectory: false
            )
        }
        let command = CleanupCommand(executable: "/usr/bin/true", arguments: [], summary: "")

        let plan = DeletionPlanner(policy: policy, isApplicationRunning: { _ in false })
            .plan([target(.remove), target(.command(command))])

        #expect(plan.items.map(\.blocker) == [.policy(.outsideAllowedRoots), nil])
    }

    @Test func cleanupPolicyAllowsInsideUserCacheDirectoryOnly() {
        let policy = DeletionPolicy.cleanup(homeDirectory: "/Users/me", userCacheDirectory: "/private/var/folders/ab/xyz/C")

        #expect(policy.violation(for: "/private/var/folders/ab/xyz/C/com.apple.dt.Instruments") == nil)
        #expect(policy.violation(for: "/private/var/folders/ab/xyz/C") == .protectedPath)
        #expect(policy.violation(for: "/private/var/folders/ab/xyz/T/tmp") == .outsideAllowedRoots)
    }

    @Test func findsSandboxedAppCachesAndPlaygroundDevices() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let containers = "home/Library/Containers"
        try fixture.file("\(containers)/com.example.notes/Data/Library/Caches/blob", bytes: 50_000)
        try fixture.file("\(containers)/com.example.notes/Data/Documents/note", bytes: 50_000)
        try fixture.file("\(containers)/com.apple.mail/Data/Library/Caches/blob", bytes: 50_000)
        try fixture.file("\(containers)/com.example.empty/Data/Library/Preferences/p.plist", bytes: 10)
        try fixture.file("home/Library/Developer/XCPGDevices/DEVICE/data/blob", bytes: 50_000)
        let ids: Set<String> = ["apps.containerCache", "xcode.playgroundDevices"]
        let engine = CleanupRuleEngine(
            rules: [CleanupRule].defaults.filter { ids.contains($0.id) },
            homeDirectory: fixture.path("home")
        )

        let report = await engine.evaluateLocations(
            outside: [fixture.path("elsewhere")],
            scanner: DiskScanner(options: ScanOptions(threadCount: 2))
        )

        #expect(Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.path, $0.rule.id) }) == [
            fixture.path("\(containers)/com.example.notes/Data/Library/Caches"): "apps.containerCache",
            fixture.path("home/Library/Developer/XCPGDevices"): "xcode.playgroundDevices",
        ])
    }

    @Test func listsEachAvailableSimulator() {
        let devices = Data("""
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"name": "iPhone 17", "udid": "AAA", "isAvailable": true, "state": "Shutdown",
             "lastBootedAt": "2026-10-06T03:05:46Z", "dataPathSize": 6000000000,
             "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/AAA/data"},
            {"name": "iPad Air", "udid": "BBB", "isAvailable": true, "state": "Booted", "dataPathSize": 9000000000,
             "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/BBB/data"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-16-0": [
            {"name": "iPhone 14", "udid": "CCC", "isAvailable": false,
             "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/CCC/data"}
          ]
        }}
        """.utf8)

        let items = SimulatorItems.deviceItems(devicesJSON: devices)

        #expect(items.map(\.title) == ["iPad Air · iOS 26.0", "iPhone 17 · iOS 26.0"])
        #expect(items.map(\.selector) == ["BBB", "AAA"])
        #expect(items.map(\.bytes) == [9_000_000_000, 6_000_000_000])
        #expect(items.allSatisfy { $0.grade == .review && $0.ruleID == "simulator.device" })
        #expect(items[1].path == "/Users/me/Library/Developer/CoreSimulator/Devices/AAA")
        #expect(items[1].command.arguments == ["simctl", "delete", "AAA"])
        #expect(items[0].detail.contains("지금 켜져 있음"))
        #expect(!items[1].detail.contains("기록 없음"))
    }

    @Test func findsOldRuleFilteredLeftoversOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let temporary = fixture.path("T")
        try fixture.file("T/com.example.app.ShipIt.old/Example.app/binary", bytes: 300_000)
        try fixture.file("T/com.example.app.ShipIt.new/Example.app/binary", bytes: 300_000)
        try fixture.file("T/other.old/file", bytes: 300_000)
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        for name in ["com.example.app.ShipIt.old", "other.old"] {
            try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: fixture.path("T/\(name)"))
        }
        let rule = CleanupRule(
            id: "test.updates", tool: "앱 업데이트", title: "앱 업데이트 잔여물", grade: .cache, restore: "",
            scope: .contentsOf(temporary), namePatterns: ["*.ShipIt.*"], minimumAge: 24 * 60 * 60
        )
        let engine = CleanupRuleEngine(rules: [rule], homeDirectory: fixture.path("home"))

        let report = await engine.evaluateLocations(outside: [fixture.path("home")], scanner: DiskScanner(options: ScanOptions(threadCount: 2)))

        #expect(report.candidates.map(\.path) == [temporary + "/com.example.app.ShipIt.old"])
        #expect(report.rejected.map(\.path) == [temporary + "/com.example.app.ShipIt.new"])
        #expect(report.rejected.map(\.reason) == [.recentlyModified])
    }

    @Test func countsOldTemporaryFilesOfATool() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("T/.com.openai.codex.AAA", bytes: 40_000)
        try fixture.file("T/.com.openai.codex.BBB", bytes: 40_000)
        try fixture.file("T/.com.openai.codex.NEW", bytes: 40_000)
        try fixture.file("T/.com.openai.codex.DIR/inside", bytes: 40_000)
        try fixture.file("T/unrelated", bytes: 40_000)
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        for name in [".com.openai.codex.AAA", ".com.openai.codex.BBB", ".com.openai.codex.DIR", "unrelated"] {
            try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: fixture.path("T/\(name)"))
        }

        let items = TemporaryFileItems.find(directory: fixture.path("T"))

        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.title == "Codex 임시 파일 2개")
        #expect(item.bytes == fixture.allocatedBytes("T/.com.openai.codex.AAA") + fixture.allocatedBytes("T/.com.openai.codex.BBB"))
        #expect(item.command.executable == "/usr/bin/find")
        #expect(item.command.arguments == [
            fixture.path("T"), "-maxdepth", "1", "-type", "f", "-name", ".com.openai.codex.*", "-mmin", "+1440", "-delete",
        ])
        #expect(TemporaryFileItems.find(directory: fixture.path("empty")).isEmpty)
    }

    @Test func temporaryFileCommandDeletesOnlyOldMatchingFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("T/.com.openai.codex.OLD", bytes: 1_000)
        try fixture.file("T/.com.openai.codex.NEW", bytes: 1_000)
        try fixture.file("T/keep.old", bytes: 1_000)
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        for name in [".com.openai.codex.OLD", "keep.old"] {
            try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: fixture.path("T/\(name)"))
        }
        let item = try #require(TemporaryFileItems.find(directory: fixture.path("T")).first)

        try run(item.command.executable, item.command.arguments)

        let left = try FileManager.default.contentsOfDirectory(atPath: fixture.path("T")).sorted()
        #expect(left == [".com.openai.codex.NEW", "keep.old"])
    }

    @Test func readsWhatHomebrewWouldFree() throws {
        let output = """
        Would remove: /opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.5_1 (1,707 files, 34.6MB)
        Would remove: /Users/me/Library/Caches/Homebrew/node--25.0.0 (12.1MB)
        ==> This operation would free approximately 212.1MB of disk space.
        """

        #expect(HomebrewItems.freedBytes(dryRunOutput: output) == Int64(212.1 * 1_048_576))
        #expect(HomebrewItems.freedBytes(dryRunOutput: "would free approximately 1.5GB of") == Int64(1.5 * 1_073_741_824))
        #expect(HomebrewItems.freedBytes(dryRunOutput: "") == nil)

        let item = try #require(HomebrewItems.item(dryRunOutput: output, brew: "/opt/homebrew/bin/brew"))
        #expect(item.path == "/opt/homebrew")
        #expect(item.command.arguments == ["cleanup"])
        #expect(item.detail.contains("2개"))
        #expect(HomebrewItems.item(dryRunOutput: "", brew: "/opt/homebrew/bin/brew") == nil)
    }

    private func writeAsset(_ fixture: Fixture, _ relativePath: String, version: String, build: String, neverCollected: Bool) throws {
        try fixture.file("\(relativePath)/AssetData/runtime.dmg", bytes: 200_000)
        var properties: [String: Any] = ["SimulatorVersion": version, "Build": build]
        if neverCollected { properties["__AssetDefaultGarbageCollectionBehavior"] = "NeverCollected" }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["MobileAssetProperties": properties], format: .xml, options: 0
        )
        try plist.write(to: URL(fileURLWithPath: fixture.path("\(relativePath)/Info.plist")))
    }

    @Test func findsRuntimeAssetsThatAreNoLongerRegistered() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let iOS = "AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime"
        try writeAsset(fixture, "\(iOS)/aaa.asset", version: "26.0", build: "23A343", neverCollected: true)
        try writeAsset(fixture, "\(iOS)/bbb.asset", version: "18.2", build: "22C150", neverCollected: true)
        try writeAsset(fixture, "AssetsV2/com_apple_MobileAsset_xrOSSimulatorRuntime/ccc.asset", version: "2.0", build: "22N1", neverCollected: false)
        try writeAsset(fixture, "AssetsV2/com_apple_MobileAsset_Font8/ddd.asset", version: "1", build: "X", neverCollected: false)

        let leftovers = await SimulatorItems.leftoverRuntimeAssets(
            assetsDirectory: fixture.path("AssetsV2"),
            registeredBuilds: ["23A343"]
        )

        #expect(leftovers.map { "\($0.platform) \($0.version)" } == ["iOS 18.2", "visionOS 2.0"])
        #expect(leftovers.map(\.isNeverCollected) == [true, false])
        #expect(leftovers.first?.bytes == fixture.allocatedBytes("\(iOS)/bbb.asset/AssetData/runtime.dmg")
            + fixture.allocatedBytes("\(iOS)/bbb.asset/Info.plist"))
    }

    @Test func doesNotGuessWhenSimctlOutputIsUnreadable() {
        #expect(SimulatorItems.registeredBuilds(runtimesJSON: Data("not json".utf8)) == nil)
        #expect(SimulatorItems.registeredBuilds(runtimesJSON: Data("{}".utf8)) == [])
    }

    @Test func readsSimulatorRuntimesFromSimctlJSON() {
        let runtimes = Data("""
        {
          "AAA": {"identifier": "AAA", "version": "18.2", "build": "22C150", "sizeBytes": 8710000000,
                  "lastUsedAt": "2026-02-08T08:42:02Z", "path": "/Library/Developer/CoreSimulator/Images/AAA.dmg",
                  "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-2", "deletable": true},
          "BBB": {"identifier": "BBB", "version": "26.0", "build": "23A343", "sizeBytes": 10020000000,
                  "path": "/System/Library/AssetsV2/BBB.asset",
                  "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "deletable": true},
          "CCC": {"identifier": "CCC", "version": "2.0", "path": "/x", "deletable": false,
                  "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.xrOS-2-0"}
        }
        """.utf8)
        let devices = Data("""
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"name": "iPhone 17", "isAvailable": true, "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/U1/data"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-16-0": [
            {"name": "iPhone 14", "isAvailable": false, "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/U2/data"}
          ]
        }}
        """.utf8)

        let items = SimulatorItems.runtimeItems(runtimesJSON: runtimes, devicesJSON: devices)

        #expect(items.map(\.title) == ["iOS 18.2 시뮬레이터 런타임", "iOS 26.0 시뮬레이터 런타임"])
        #expect(items.map(\.selector) == ["18.2", "26.0"])
        #expect(items.map(\.bytes) == [8_710_000_000, 10_020_000_000])
        #expect(items.allSatisfy { $0.grade == .review })
        #expect(items[0].command.arguments == ["simctl", "runtime", "delete", "AAA"])
        #expect(items.allSatisfy { $0.command.completesInBackground })
        #expect(items[0].detail.contains("시뮬레이터 0대"))
        #expect(items[1].detail.contains("시뮬레이터 1대"))
        #expect(items[1].detail.contains("마지막 사용 기록 없음"))

        let unavailable = SimulatorItems.unavailableDevices(devicesJSON: devices)
        #expect(unavailable.map(\.name) == ["iPhone 14"])
        #expect(unavailable.map(\.directory) == ["/Users/me/Library/Developer/CoreSimulator/Devices/U2"])
    }
}
