import Darwin
import Foundation
import Testing
@testable import CleanerCore

@Suite struct RunningItemsTests {
    private func process(_ pid: Int32, _ name: String, parent: Int32 = 1, path: String = "", memory: Int64) -> ProcessEntry {
        ProcessEntry(pid: pid, parentPID: parent, name: name, path: path, memoryBytes: memory)
    }

    @Test func readsListeningPortsFromLsof() {
        let output = """
        p123
        cnode
        f21
        n*:3000
        f22
        n127.0.0.1:9229
        p456
        cpython3
        f5
        n[::1]:8000
        """

        #expect(RunningItems.listeningPorts(lsofOutput: output) == [123: [3000, 9229], 456: [8000]])
    }

    @Test func picksDevelopmentServersOnly() {
        let home = "/Users/me"
        let processes = [
            process(123, "node", path: "/opt/homebrew/bin/node", memory: 300),
            process(124, "esbuild", parent: 123, path: "/Users/me/web/node_modules/esbuild/bin/esbuild", memory: 50),
            process(456, "python3", path: "/usr/bin/python3", memory: 100),
            process(789, "Code Helper", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper", memory: 900),
            process(900, "CrossEXService", path: "/Applications/CrossEX/CrossEXService", memory: 20),
            process(1000, "server", path: "/Users/me/rust/target/debug/server", memory: 40),
        ]
        let ports: [Int32: [Int]] = [123: [3000, 9229], 456: [8000], 789: [51672], 900: [34581], 1000: [8080]]

        let items = RunningItems.serverItems(
            ports: ports, processes: processes, excluding: [456], homeDirectory: home,
            workingDirectory: { $0 == 123 ? "/Users/me/2025/web" : nil },
            arguments: { $0 == 123 ? ["node", "/Users/me/2025/web/node_modules/.bin/vite", "--port", "3000"] : ["server"] }
        )

        #expect(items.map(\.title) == ["server", "web"])
        let web = items[1]
        #expect(web.detail == "node vite · 포트 3000, 9229 · ~/2025/web")
        #expect(web.memoryBytes == 350)
        #expect(web.stop == .signal(pids: [123], signal: SIGTERM))
        #expect(web.forceStop == .signal(pids: [123, 124], signal: SIGKILL))
    }

    @Test func sumsMemoryOfEachBootedSimulator() {
        let booted = Data("""
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
          {"name": "iPhone 17", "udid": "AAA", "state": "Booted"}
        ]}}
        """.utf8)
        let processes = [
            process(10, "launchd_sim", memory: 100),
            process(11, "SpringBoard", parent: 10, memory: 200),
            process(20, "launchd_sim", memory: 70),
            process(30, "Finder", memory: 500),
        ]

        let items = RunningItems.simulatorItems(bootedJSON: booted, processes: processes) { pid in
            pid == 10 ? ["launchd_sim", "/Users/me/Library/Developer/CoreSimulator/Devices/AAA/data/var/run/launchd_bootstrap.plist"]
                : ["launchd_sim", "/Users/me/Library/Developer/CoreSimulator/Devices/BBB/data/var/run/launchd_bootstrap.plist"]
        }

        #expect(items.count == 1)
        #expect(items[0].title == "iPhone 17")
        #expect(items[0].detail == "iOS 26.0 시뮬레이터 · 프로세스 2개")
        #expect(items[0].memoryBytes == 300)
        #expect(items[0].stop == .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "shutdown", "AAA"]))
        #expect(items[0].forceStop == nil)
    }

    @Test func recognizesDeveloperDaemons() {
        let processes = [
            process(1, "SourceKitService", memory: 100),
            process(2, "SourceKitService", memory: 50),
            process(3, "java", memory: 800),
            process(4, "java", memory: 400),
            process(5, "zsh", memory: 5),
        ]
        let gradle = ["java", "-cp", "/Users/me/.gradle/wrapper/dists/gradle-8.7-bin/x/gradle-8.7/lib/gradle-launcher.jar",
                      "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.7"]

        let items = RunningItems.developerToolItems(processes: processes) { $0 == 3 ? gradle : ["java", "-jar", "app.jar"] }

        #expect(items.map(\.title) == ["Gradle 데몬 8.7", "SourceKit 2개"])
        #expect(items[1].pids == [1, 2])
        #expect(items[1].memoryBytes == 150)
    }

    @Test func readsRunningContainers() {
        let items = RunningItems.containerItems(
            psOutput: "abc123\tweb-db\tpostgres:16\tUp 2 hours\n",
            docker: "/usr/local/bin/docker"
        )

        #expect(items.map(\.title) == ["Docker 컨테이너 · web-db"])
        #expect(items[0].detail == "postgres:16 · Up 2 hours")
        #expect(items[0].stop == .command(executable: "/usr/local/bin/docker", arguments: ["stop", "abc123"]))
        #expect(items[0].forceStop == .command(executable: "/usr/local/bin/docker", arguments: ["kill", "abc123"]))
    }

    @Test func sumsApplicationHelpersAndChildrenButNotOtherGroups() {
        let applications = [
            RunningApplicationInfo(pid: 100, name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode",
                                   bundlePath: "/Applications/Visual Studio Code.app"),
            RunningApplicationInfo(pid: 200, name: "터미널", bundleIdentifier: "com.apple.Terminal",
                                   bundlePath: "/System/Applications/Utilities/Terminal.app"),
        ]
        let processes = [
            process(100, "Electron", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", memory: 500),
            process(101, "Code Helper", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper", memory: 900),
            process(102, "node", parent: 100, path: "/opt/homebrew/bin/node", memory: 200),
            process(200, "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", memory: 100),
            process(201, "zsh", parent: 200, path: "/bin/zsh", memory: 10),
            process(202, "node", parent: 201, path: "/opt/homebrew/bin/node", memory: 400),
        ]

        let items = RunningItems.applicationItems(applications, processes: processes, excluding: [202])

        #expect(items.map(\.title) == ["Visual Studio Code", "터미널"])
        #expect(items.map(\.memoryBytes) == [1600, 110])
        #expect(items[0].stop == .quitApplication(pid: 100))
        #expect(items[0].forceStop == .forceQuitApplication(pid: 100))
    }

    @Test func readsThisProcessFromTheProcessTable() throws {
        let me = try #require(ProcessTable.snapshot().first { $0.pid == getpid() })
        #expect(!me.path.isEmpty)
        #expect(me.memoryBytes > 0)
        #expect(!ProcessTable.arguments(of: getpid()).isEmpty)
        #expect(ProcessTable.workingDirectory(of: getpid()) != nil)
        let memory = try #require(MemoryStatus.current())
        #expect(memory.physicalBytes > 0)
        #expect(memory.usedBytes > 0)
    }

    @Test @MainActor func stopsAProcessWithATerminateSignal() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()

        let sent = await RunningItemStopper.perform(.signal(pids: [sleeper.processIdentifier], signal: SIGTERM))
        sleeper.waitUntilExit()

        #expect(sent)
        #expect(sleeper.terminationReason == .uncaughtSignal)
        #expect(await RunningItemStopper.perform(.signal(pids: [1, getpid()], signal: SIGTERM)) == false)
    }
}
