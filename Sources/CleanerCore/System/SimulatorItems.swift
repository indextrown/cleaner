import Darwin
import Foundation

/// 도구에 물어서 찾는 정리 항목. 경로를 스캔해서는 크기나 쓰임새를 알 수 없는 것들이다(시뮬레이터 런타임 등).
public struct SystemItem: Sendable, Identifiable {
    public let id: String
    public let ruleID: String
    public let tool: String
    public let title: String
    /// 판단에 필요한 정보. 예: "빌드 21A328 · 마지막 사용 2026. 7. 13. · 시뮬레이터 0대"
    public let detail: String
    public let grade: CleanupGrade
    public let restore: String
    /// 도구가 알려 준 크기.
    public let bytes: Int64
    /// 항목이 있는 곳. 표시와, 계획한 그대로인지 확인하는 데 쓴다.
    public let path: String
    public let command: CleanupCommand
    /// 고를 때 쓰는 짧은 이름. 런타임은 버전("17.0"), 쓸 수 없는 시뮬레이터는 "unavailable".
    public let selector: String
}

/// `xcrun simctl`로 시뮬레이터 런타임과 쓸 수 없는 시뮬레이터를 찾는다.
public enum SimulatorItems {
    public static func find(homeDirectory: String = NSHomeDirectory()) async -> [SystemItem] {
        guard
            let runtimes = await ToolRunner.output("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]),
            let devices = await ToolRunner.output("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"])
        else { return [] }

        var items = runtimeItems(runtimesJSON: runtimes, devicesJSON: devices) + deviceItems(devicesJSON: devices)
        let unavailable = unavailableDevices(devicesJSON: devices)
        if !unavailable.isEmpty {
            var bytes: Int64 = 0
            let scanner = DiskScanner(options: ScanOptions(threadCount: 4))
            for device in unavailable {
                bytes += (try? await scanner.scan(device.directory))?.root.totalBytes ?? 0
            }
            items.append(SystemItem(
                id: "simulator.unavailableDevices",
                ruleID: "simulator.unavailableDevices",
                tool: "Xcode",
                title: "쓸 수 없는 시뮬레이터 \(unavailable.count)대",
                detail: unavailable.map(\.name).joined(separator: ", "),
                grade: .cache,
                restore: "런타임이 없어 이미 실행할 수 없는 시뮬레이터라 다시 만들 필요가 없다",
                bytes: bytes,
                path: homeDirectory + "/Library/Developer/CoreSimulator/Devices",
                command: CleanupCommand(
                    executable: "/usr/bin/xcrun",
                    arguments: ["simctl", "delete", "unavailable"],
                    summary: "설치된 런타임이 없어 쓸 수 없는 시뮬레이터를 지움"
                ),
                selector: "unavailable"
            ))
        }
        return items
    }

    struct Runtime: Decodable {
        let identifier: String
        let version: String
        let build: String?
        let sizeBytes: Int64?
        let lastUsedAt: String?
        let path: String
        let runtimeIdentifier: String
        let deletable: Bool?
    }

    private struct DeviceList: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let name: String
        let isAvailable: Bool?
        let dataPath: String?
        let udid: String?
        let state: String?
        let lastBootedAt: String?
        let dataPathSize: Int64?
    }

    /// 쓸 수 있는 시뮬레이터 하나하나. 안에 설치한 앱과 데이터가 있어 판단 필요 등급이다.
    /// 크기는 simctl이 알려 준 데이터 크기(`dataPathSize`)다.
    static func deviceItems(devicesJSON: Data) -> [SystemItem] {
        guard let list = try? JSONDecoder().decode(DeviceList.self, from: devicesJSON) else { return [] }
        let dateParser = ISO8601DateFormatter()
        return list.devices.flatMap { runtimeIdentifier, devices in
            devices.compactMap { device -> SystemItem? in
                guard device.isAvailable != false, let udid = device.udid, let dataPath = device.dataPath else { return nil }
                let runtime = runtimeName(runtimeIdentifier)
                let lastBooted: Date? = device.lastBootedAt.flatMap(dateParser.date(from:))
                let lastBootedText = lastBooted?.formatted(date: .numeric, time: .omitted) ?? "기록 없음"
                var parts: [String] = ["마지막 실행 " + lastBootedText]
                if device.state == "Booted" {
                    parts.append("지금 켜져 있음 (끈 뒤 지울 수 있음)")
                }
                let detail = parts.joined(separator: " · ")
                return SystemItem(
                    id: "simulator.device." + udid,
                    ruleID: "simulator.device",
                    tool: "시뮬레이터 기기",
                    title: "\(device.name) · \(runtime)",
                    detail: detail,
                    grade: .review,
                    restore: "Xcode > Window > Devices and Simulators에서 다시 만들 수 있다. 안에 설치한 앱과 데이터는 사라진다",
                    bytes: device.dataPathSize ?? 0,
                    path: (dataPath as NSString).deletingLastPathComponent,
                    command: CleanupCommand(
                        executable: "/usr/bin/xcrun",
                        arguments: ["simctl", "delete", udid],
                        summary: "\(device.name) 시뮬레이터를 CoreSimulator를 거쳐 지움"
                    ),
                    selector: udid
                )
            }
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-0` → `iOS 26.0`
    static func runtimeName(_ runtimeIdentifier: String) -> String {
        let parts = (runtimeIdentifier.split(separator: ".").last ?? "").split(separator: "-")
        let platform = platformName(runtimeIdentifier)
        return parts.count > 1 ? "\(platform) \(parts.dropFirst().joined(separator: "."))" : platform
    }

    /// `simctl runtime list -j`와 `simctl list devices -j` 출력으로 런타임 항목을 만든다.
    static func runtimeItems(runtimesJSON: Data, devicesJSON: Data) -> [SystemItem] {
        guard let runtimes = try? JSONDecoder().decode([String: Runtime].self, from: runtimesJSON) else { return [] }
        let devices = (try? JSONDecoder().decode(DeviceList.self, from: devicesJSON))?.devices ?? [:]
        let dateParser = ISO8601DateFormatter()

        return runtimes.values
            .filter { $0.deletable != false }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
            .map { runtime in
                let platform = platformName(runtime.runtimeIdentifier)
                let lastUsed = runtime.lastUsedAt.flatMap(dateParser.date(from:))
                let deviceCount = devices[runtime.runtimeIdentifier]?.count ?? 0
                let detail = [
                    runtime.build.map { "빌드 \($0)" },
                    "마지막 사용 " + (lastUsed?.formatted(date: .numeric, time: .omitted) ?? "기록 없음"),
                    "이 런타임의 시뮬레이터 \(deviceCount)대",
                ].compactMap(\.self).joined(separator: " · ")
                return SystemItem(
                    id: "simulator.runtime." + runtime.identifier,
                    ruleID: "simulator.runtime",
                    tool: "Xcode",
                    title: "\(platform) \(runtime.version) 시뮬레이터 런타임",
                    detail: detail,
                    grade: .review,
                    restore: "Xcode > 설정 > Components에서 다시 내려받음. 이 버전의 시뮬레이터는 그때까지 실행되지 않는다",
                    bytes: runtime.sizeBytes ?? 0,
                    path: runtime.path,
                    command: CleanupCommand(
                        executable: "/usr/bin/xcrun",
                        arguments: ["simctl", "runtime", "delete", runtime.identifier],
                        summary: "\(platform) \(runtime.version) 런타임을 CoreSimulator를 거쳐 지움",
                        completesInBackground: true
                    ),
                    selector: runtime.version
                )
            }
    }

    /// 쓸 수 없는(런타임이 지워진) 시뮬레이터. `directory`는 기기 폴더(`Devices/<UDID>`)다.
    static func unavailableDevices(devicesJSON: Data) -> [(name: String, directory: String)] {
        guard let list = try? JSONDecoder().decode(DeviceList.self, from: devicesJSON) else { return [] }
        return list.devices.values.joined()
            .filter { $0.isAvailable == false }
            .compactMap { device in
                device.dataPath.map { (device.name, ($0 as NSString).deletingLastPathComponent) }
            }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-0` → `iOS`
    private static func platformName(_ runtimeIdentifier: String) -> String {
        let name = runtimeIdentifier.split(separator: ".").last?.split(separator: "-").first.map(String.init) ?? "시뮬레이터"
        return name == "xrOS" ? "visionOS" : name
    }
}

/// simctl에 등록되지 않았는데 `/System/Library/AssetsV2`에 남은 시뮬레이터 런타임 에셋.
///
/// Cryptex 런타임은 `simctl runtime delete`로 등록과 마운트가 풀린 뒤에도 내려받은 에셋이 남을 수 있다.
/// 이 폴더는 SIP로 보호되어 Cleaner나 sudo로는 지울 수 없고, macOS(mobileassetd)만 지운다.
public struct LeftoverRuntimeAsset: Sendable, Identifiable {
    public let path: String
    public let platform: String
    public let version: String
    public let build: String
    public let bytes: Int64
    /// macOS가 자동으로 지우지 않도록 표시되어 있다(`NeverCollected`).
    public let isNeverCollected: Bool

    public var id: String { path }
}

extension SimulatorItems {
    public static let assetsDirectory = "/System/Library/AssetsV2"

    /// 등록되지 않은 런타임 에셋을 찾는다. simctl 출력을 읽지 못하면 모든 에셋을 남은 것으로 잘못 볼 수 있으므로 빈 목록을 돌려준다.
    public static func leftoverRuntimeAssets(assetsDirectory: String = assetsDirectory) async -> [LeftoverRuntimeAsset] {
        guard
            let runtimes = await ToolRunner.output("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]),
            let builds = registeredBuilds(runtimesJSON: runtimes)
        else { return [] }
        return await leftoverRuntimeAssets(assetsDirectory: assetsDirectory, registeredBuilds: builds)
    }

    /// `simctl runtime list -j`에 있는 런타임의 빌드 번호. 해석하지 못하면 nil.
    static func registeredBuilds(runtimesJSON: Data) -> Set<String>? {
        guard let runtimes = try? JSONDecoder().decode([String: Runtime].self, from: runtimesJSON) else { return nil }
        return Set(runtimes.values.compactMap(\.build))
    }

    static func leftoverRuntimeAssets(assetsDirectory: String, registeredBuilds: Set<String>) async -> [LeftoverRuntimeAsset] {
        let prefix = "com_apple_MobileAsset_"
        let suffix = "SimulatorRuntime"
        let catalogs = ((try? FileManager.default.contentsOfDirectory(atPath: assetsDirectory)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
        let scanner = DiskScanner(options: ScanOptions(threadCount: 2))

        var leftovers: [LeftoverRuntimeAsset] = []
        for catalog in catalogs.sorted() {
            let platform = displayPlatform(String(catalog.dropFirst(prefix.count).dropLast(suffix.count)))
            let catalogPath = assetsDirectory + "/" + catalog
            let assets = ((try? FileManager.default.contentsOfDirectory(atPath: catalogPath)) ?? [])
                .filter { $0.hasSuffix(".asset") }
            for asset in assets.sorted() {
                let path = catalogPath + "/" + asset
                guard
                    let data = FileManager.default.contents(atPath: path + "/Info.plist"),
                    let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                    let properties = info["MobileAssetProperties"] as? [String: Any],
                    let build = properties["Build"] as? String,
                    !registeredBuilds.contains(build)
                else { continue }
                leftovers.append(LeftoverRuntimeAsset(
                    path: path,
                    platform: platform,
                    version: properties["SimulatorVersion"] as? String ?? "?",
                    build: build,
                    bytes: (try? await scanner.scan(path))?.root.totalBytes ?? 0,
                    isNeverCollected: properties["__AssetDefaultGarbageCollectionBehavior"] as? String == "NeverCollected"
                ))
            }
        }
        return leftovers.sorted { $0.bytes > $1.bytes }
    }

    /// 에셋 폴더 이름 속 플랫폼 이름을 흔히 쓰는 이름으로 바꾼다.
    private static func displayPlatform(_ name: String) -> String {
        switch name {
        case "xrOS": "visionOS"
        case "appleTVOS": "tvOS"
        default: name
        }
    }
}

extension DeletionTarget {
    /// 시스템 항목을 삭제 대상으로 바꾼다. 항목 경로가 지금 없으면 nil.
    public init?(systemItem item: SystemItem) {
        var info = stat()
        guard lstat(item.path, &info) == 0 else { return nil }
        self.init(
            path: item.path,
            identity: FileIdentity(device: info.st_dev, fileID: info.st_ino),
            method: .command(item.command),
            title: item.title,
            ruleID: item.ruleID,
            grade: item.grade,
            allocatedBytes: item.bytes,
            unsharedBytes: item.bytes,
            isDirectory: info.st_mode & S_IFMT == S_IFDIR,
            conflictingApplications: Self.applicationsByTool[item.tool] ?? []
        )
    }
}

/// 외부 명령을 실행하고 표준 출력을 받는다. 블로킹이라 협력 스레드 풀 밖에서 돌린다.
enum ToolRunner {
    static func output(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, environment: environment))
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], environment: [String: String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
