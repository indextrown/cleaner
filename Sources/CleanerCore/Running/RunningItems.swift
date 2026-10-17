import AppKit
import Darwin
import Foundation

/// 실행 중 탭의 한 줄. 같은 것을 이루는 프로세스를 묶고, 끄는 방법을 함께 둔다.
public struct RunningItem: Identifiable, Sendable, Equatable {
    public enum Group: Int, CaseIterable, Sendable {
        case simulators
        case developerTools
        case servers
        case applications
    }

    public enum Stop: Sendable, Equatable {
        /// 도구 명령. 예: `xcrun simctl shutdown <UDID>`, `docker stop <ID>`
        case command(executable: String, arguments: [String])
        /// 프로세스에 신호를 보낸다. SIGTERM은 정상 종료 요청, SIGKILL은 강제 종료다.
        case signal(pids: [Int32], signal: Int32)
        /// 앱에 종료를 요청한다. 저장하지 않은 문서가 있으면 앱이 묻는다.
        case quitApplication(pid: Int32)
        case forceQuitApplication(pid: Int32)
    }

    public let id: String
    public let group: Group
    public let title: String
    public let detail: String
    /// 묶인 프로세스의 메모리 합계. 알 수 없으면 nil(Docker 컨테이너 등).
    public let memoryBytes: Int64?
    public let pids: [Int32]
    public let stop: Stop
    /// 정상 종료로 꺼지지 않을 때 쓰는 방법. 없으면 nil.
    public let forceStop: Stop?
    /// 아이콘을 보여 줄 앱 번들 경로.
    public let bundlePath: String?
    public let systemImage: String
}

/// NSWorkspace에서 메인 스레드로 읽어 넘기는 앱 정보.
public struct RunningApplicationInfo: Sendable {
    public let pid: Int32
    public let name: String
    public let bundleIdentifier: String?
    public let bundlePath: String?

    public init(pid: Int32, name: String, bundleIdentifier: String?, bundlePath: String?) {
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
    }

    /// Dock에 보이는 일반 앱. Finder와 이 앱 자신은 뺀다.
    @MainActor
    public static func regularApplications() -> [RunningApplicationInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && $0.bundleIdentifier != "com.apple.finder" }
            .map {
                RunningApplicationInfo(
                    pid: $0.processIdentifier,
                    name: $0.localizedName ?? $0.bundleIdentifier ?? "앱",
                    bundleIdentifier: $0.bundleIdentifier,
                    bundlePath: $0.bundleURL?.path
                )
            }
    }
}

public enum RunningItems {
    /// 지금 켜져 있는 시뮬레이터·개발 도구·개발 서버·앱을 찾는다. 앞 묶음에 든 프로세스는 뒤 묶음에서 뺀다.
    public static func find(
        applications: [RunningApplicationInfo],
        homeDirectory: String = NSHomeDirectory()
    ) async -> [RunningItem] {
        let processes = ProcessTable.snapshot()
        async let booted = ToolRunner.output("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"])
        async let listening = ToolRunner.output(
            "/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-u", String(getuid()), "-F", "pcn"]
        )
        async let containers = dockerContainers()

        var items = simulatorItems(bootedJSON: await booted ?? Data(), processes: processes)
        items += emulatorItems(processes: processes)
        items += developerToolItems(processes: processes)
        items += await containers
        var claimed = Set(items.flatMap(\.pids))
        items += serverItems(
            ports: listeningPorts(lsofOutput: String(decoding: await listening ?? Data(), as: UTF8.self)),
            processes: processes, excluding: claimed, homeDirectory: homeDirectory
        )
        claimed = Set(items.flatMap(\.pids))
        items += applicationItems(applications, processes: processes, excluding: claimed)
        return items
    }

    // MARK: - 시뮬레이터·에뮬레이터

    private struct DeviceList: Decodable {
        struct Device: Decodable {
            let name: String
            let udid: String
            let state: String?
        }
        let devices: [String: [Device]]
    }

    /// 켜진 iOS 시뮬레이터. 메모리는 그 기기의 `launchd_sim`과 그 아래 프로세스를 더한다.
    static func simulatorItems(
        bootedJSON: Data,
        processes: [ProcessEntry],
        arguments: (Int32) -> [String] = ProcessTable.arguments(of:)
    ) -> [RunningItem] {
        guard let list = try? JSONDecoder().decode(DeviceList.self, from: bootedJSON) else { return [] }
        let launchers = processes.filter { $0.name == "launchd_sim" }
        let launcherArguments = Dictionary(uniqueKeysWithValues: launchers.map { ($0.pid, arguments($0.pid).joined(separator: " ")) })
        return list.devices.flatMap { runtime, devices in
            devices.filter { $0.state == "Booted" }.map { device in
                let roots = Set(launchers.filter { launcherArguments[$0.pid]?.contains(device.udid) == true }.map(\.pid))
                let members = roots.isEmpty ? [] : ProcessTable.descendants(of: roots, in: processes)
                let memory = processes.filter { members.contains($0.pid) }.reduce(Int64(0)) { $0 + $1.memoryBytes }
                return RunningItem(
                    id: "simulator." + device.udid,
                    group: .simulators,
                    title: device.name,
                    detail: "\(SimulatorItems.runtimeName(runtime)) 시뮬레이터 · 프로세스 \(members.count)개",
                    memoryBytes: members.isEmpty ? nil : memory,
                    pids: members.sorted(),
                    stop: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "shutdown", device.udid]),
                    forceStop: nil,
                    bundlePath: nil,
                    systemImage: "iphone"
                )
            }
        }
        .sorted { $0.title < $1.title }
    }

    /// Android 에뮬레이터(qemu). AVD 이름은 `-avd 이름`이나 `@이름` 인자에서 읽는다.
    static func emulatorItems(
        processes: [ProcessEntry],
        arguments: (Int32) -> [String] = ProcessTable.arguments(of:)
    ) -> [RunningItem] {
        processes.filter { $0.name.hasPrefix("qemu-system") }.map { process in
            let args = arguments(process.pid)
            let avd = args.firstIndex(of: "-avd").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                ?? args.first { $0.hasPrefix("@") }.map { String($0.dropFirst()) }
            let members = ProcessTable.descendants(of: [process.pid], in: processes)
            return RunningItem(
                id: "emulator.\(process.pid)",
                group: .simulators,
                title: avd.map { "Android 에뮬레이터 · \($0)" } ?? "Android 에뮬레이터",
                detail: "프로세스 \(members.count)개",
                memoryBytes: memory(of: members, in: processes),
                pids: members.sorted(),
                stop: .signal(pids: [process.pid], signal: SIGTERM),
                forceStop: .signal(pids: members.sorted(), signal: SIGKILL),
                bundlePath: nil,
                systemImage: "iphone.gen1"
            )
        }
    }

    // MARK: - 개발 도구

    /// 이름으로 알아보는 개발 도구 백그라운드 프로세스.
    static let developerToolNames: [String: (title: String, detail: String)] = [
        "SourceKitService": ("SourceKit", "Xcode 코드 분석. Xcode가 켜져 있으면 필요할 때 다시 켜짐"),
        "XCBBuildService": ("Xcode 빌드 서비스", "Xcode가 켜져 있으면 필요할 때 다시 켜짐"),
        "sourcekit-lsp": ("SourceKit-LSP", "편집기의 Swift 언어 서버"),
        "swift-plugin-server": ("Swift 매크로 플러그인 서버", "빌드 중에만 필요함"),
        "watchman": ("Watchman", "React Native 등의 파일 감시. 필요하면 다시 켜짐"),
        "adb": ("adb 서버", "Android 기기 연결. adb를 쓰면 다시 켜짐"),
    ]

    /// Java 인자로 알아보는 데몬. 빌드가 끝나도 몇 시간 동안 메모리를 쥐고 남는다.
    static let javaDaemons: [(marker: String, title: String, detail: String)] = [
        ("org.gradle.launcher.daemon.bootstrap.GradleDaemon", "Gradle 데몬", "빌드가 끝나도 남아 메모리를 씀. 다음 빌드 때 다시 켜짐"),
        ("org.jetbrains.kotlin.daemon.KotlinCompileDaemon", "Kotlin 컴파일 데몬", "빌드가 끝나도 남아 메모리를 씀. 다음 빌드 때 다시 켜짐"),
    ]

    static func developerToolItems(
        processes: [ProcessEntry],
        arguments: (Int32) -> [String] = ProcessTable.arguments(of:)
    ) -> [RunningItem] {
        var items: [RunningItem] = []
        let byName = Dictionary(grouping: processes.filter { developerToolNames[$0.name] != nil }, by: \.name)
        for (name, members) in byName {
            guard let known = developerToolNames[name] else { continue }
            let pids = members.map(\.pid).sorted()
            items.append(RunningItem(
                id: "tool." + name,
                group: .developerTools,
                title: known.title + (pids.count > 1 ? " \(pids.count)개" : ""),
                detail: known.detail,
                memoryBytes: members.reduce(0) { $0 + $1.memoryBytes },
                pids: pids,
                stop: .signal(pids: pids, signal: SIGTERM),
                forceStop: .signal(pids: pids, signal: SIGKILL),
                bundlePath: nil,
                systemImage: "gearshape.2"
            ))
        }
        for process in processes where process.name == "java" {
            let joined = arguments(process.pid).joined(separator: " ")
            guard let daemon = javaDaemons.first(where: { joined.contains($0.marker) }) else { continue }
            // Gradle 데몬은 클래스 경로의 gradle-8.7 같은 폴더 이름에서 버전을 읽는다.
            let version = joined.firstMatch(of: /gradle-([0-9][0-9.]*)/).map { " " + String($0.1) } ?? ""
            items.append(RunningItem(
                id: "tool.\(process.pid)",
                group: .developerTools,
                title: daemon.title + (daemon.title == "Gradle 데몬" ? version : ""),
                detail: daemon.detail,
                memoryBytes: process.memoryBytes,
                pids: [process.pid],
                stop: .signal(pids: [process.pid], signal: SIGTERM),
                forceStop: .signal(pids: [process.pid], signal: SIGKILL),
                bundlePath: nil,
                systemImage: "gearshape.2"
            ))
        }
        return items.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
    }

    /// 실행 중인 Docker 컨테이너. Docker가 꺼져 있으면 빈 목록이다.
    static func dockerContainers() async -> [RunningItem] {
        guard let docker = CommandResolver(searchPaths: CommandResolver.defaultSearchPaths + [
            "/Applications/Docker.app/Contents/Resources/bin",
        ]).resolve("docker"),
            let data = await ToolRunner.output(docker, ["ps", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"])
        else { return [] }
        return containerItems(psOutput: String(decoding: data, as: UTF8.self), docker: docker)
    }

    static func containerItems(psOutput: String, docker: String) -> [RunningItem] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, !fields[0].isEmpty else { return nil }
            return RunningItem(
                id: "docker." + fields[0],
                group: .developerTools,
                title: "Docker 컨테이너 · \(fields[1])",
                detail: "\(fields[2]) · \(fields[3])",
                memoryBytes: nil,
                pids: [],
                stop: .command(executable: docker, arguments: ["stop", fields[0]]),
                forceStop: .command(executable: docker, arguments: ["kill", fields[0]]),
                bundlePath: nil,
                systemImage: "shippingbox"
            )
        }
    }

    // MARK: - 개발 서버

    /// `lsof -F pcn` 출력에서 PID별 대기 중인 TCP 포트.
    static func listeningPorts(lsofOutput: String) -> [Int32: [Int]] {
        var ports: [Int32: Set<Int>] = [:]
        var pid: Int32?
        for line in lsofOutput.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p":
                pid = Int32(value)
            case "n":
                // "*:3000", "127.0.0.1:5173", "[::1]:8081"
                if let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) {
                    ports[pid, default: []].insert(port)
                }
            default:
                continue
            }
        }
        return ports.mapValues { $0.sorted() }
    }

    /// 개발 서버로 볼 런타임 이름. 이 이름이 아니어도 홈 폴더 안에서 직접 빌드한 실행 파일은 서버로 본다.
    static let serverRuntimes = ["node", "bun", "deno", "python", "ruby", "java", "php", "dotnet", "beam.smp", "uvicorn", "gunicorn"]

    static func serverItems(
        ports: [Int32: [Int]],
        processes: [ProcessEntry],
        excluding claimed: Set<Int32>,
        homeDirectory: String,
        workingDirectory: (Int32) -> String? = ProcessTable.workingDirectory(of:),
        arguments: (Int32) -> [String] = ProcessTable.arguments(of:)
    ) -> [RunningItem] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        return ports.compactMap { pid, ports -> RunningItem? in
            guard !claimed.contains(pid), pid != getpid(), let process = byPID[pid] else { return nil }
            let name = process.name.lowercased()
            let isRuntime = serverRuntimes.contains { name == $0 || name.hasPrefix($0) }
            let isOwnBuild = process.path.hasPrefix(homeDirectory + "/")
                && !process.path.hasPrefix(homeDirectory + "/Library/")
                && !process.path.contains(".app/")
            guard isRuntime || isOwnBuild else { return nil }
            let folder = workingDirectory(pid).flatMap { $0 == "/" ? nil : $0 }
            // node vite.js 같은 실행이면 스크립트 이름을 함께 보여 준다.
            let script = arguments(pid).dropFirst().first { !$0.hasPrefix("-") }.map { ($0 as NSString).lastPathComponent }
            let title = folder.map { ($0 as NSString).lastPathComponent } ?? process.name
            var parts: [String] = []
            parts.append(script.map { "\(process.name) \($0)" } ?? process.name)
            parts.append("포트 " + ports.map(String.init).joined(separator: ", "))
            if let folder {
                parts.append(folder.hasPrefix(homeDirectory) ? "~" + String(folder.dropFirst(homeDirectory.count)) : folder)
            }
            let detail = parts.joined(separator: " · ")
            let members = ProcessTable.descendants(of: [pid], in: processes).subtracting(claimed)
            return RunningItem(
                id: "server.\(pid)",
                group: .servers,
                title: title,
                detail: detail,
                memoryBytes: memory(of: members, in: processes),
                pids: members.sorted(),
                stop: .signal(pids: [pid], signal: SIGTERM),
                forceStop: .signal(pids: members.sorted(), signal: SIGKILL),
                bundlePath: nil,
                systemImage: "network"
            )
        }
        .sorted { $0.title < $1.title }
    }

    // MARK: - 앱

    /// 앱 번들 안의 프로세스(도우미·XPC)와 앱이 띄운 자식 프로세스의 메모리를 더한다.
    static func applicationItems(
        _ applications: [RunningApplicationInfo],
        processes: [ProcessEntry],
        excluding claimed: Set<Int32>
    ) -> [RunningItem] {
        let applicationPIDs = Set(applications.map(\.pid))
        return applications.map { application in
            let bundlePrefix = application.bundlePath.map { $0 + "/" }
            var members = ProcessTable.descendants(of: [application.pid], in: processes)
            if let bundlePrefix {
                members.formUnion(processes.filter { $0.path.hasPrefix(bundlePrefix) }.map(\.pid))
            }
            // 다른 앱(그 앱이 띄운 것 포함)과 앞 묶음에서 이미 보여 준 프로세스는 뺀다.
            members.subtract(claimed)
            members.subtract(applicationPIDs.subtracting([application.pid]))
            return RunningItem(
                id: "app.\(application.pid)",
                group: .applications,
                title: application.name,
                detail: "프로세스 \(members.count)개",
                memoryBytes: memory(of: members, in: processes),
                pids: members.sorted(),
                stop: .quitApplication(pid: application.pid),
                forceStop: .forceQuitApplication(pid: application.pid),
                bundlePath: application.bundlePath,
                systemImage: "app"
            )
        }
        .sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
    }

    private static func memory(of pids: Set<Int32>, in processes: [ProcessEntry]) -> Int64 {
        processes.reduce(0) { pids.contains($1.pid) ? $0 + $1.memoryBytes : $0 }
    }
}

/// 실행 중인 항목을 끈다.
@MainActor
public enum RunningItemStopper {
    /// 끄기를 요청한다. 명령이 실패하거나 신호를 보낼 수 없으면 false. 앱 종료는 요청만 하고, 실제로 꺼졌는지는 다시 찾아서 본다.
    public static func perform(_ stop: RunningItem.Stop) async -> Bool {
        switch stop {
        case .command(let executable, let arguments):
            return await ToolRunner.output(executable, arguments) != nil
        case .signal(let pids, let signal):
            // 이 앱 자신과 launchd(1)에는 보내지 않는다. 다른 사용자의 프로세스는 커널이 막는다(EPERM).
            let targets = pids.filter { $0 > 1 && $0 != getpid() }
            guard !targets.isEmpty else { return false }
            return targets.allSatisfy { kill($0, signal) == 0 || errno == ESRCH }
        case .quitApplication(let pid):
            return NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
        case .forceQuitApplication(let pid):
            return NSRunningApplication(processIdentifier: pid)?.forceTerminate() ?? false
        }
    }
}
