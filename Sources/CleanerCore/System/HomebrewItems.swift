import Foundation

/// Homebrew가 정리할 수 있다고 알려 주는 옛 버전과 내려받은 설치 파일.
///
/// `/opt/homebrew` 전체 크기는 설치된 패키지라 지울 대상이 아니다. `brew cleanup --dry-run`이 알려 주는
/// "비울 수 있는 크기"만 항목으로 만든다.
public enum HomebrewItems {
    static let executables = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public static func find() async -> [SystemItem] {
        guard let brew = executables.first(where: FileManager.default.isExecutableFile(atPath:)),
              // cleanup은 스스로 업데이트하지 않지만, 혹시 모를 자동 업데이트와 안내 문구를 끈다.
              let data = await ToolRunner.output(
                brew, ["cleanup", "--dry-run"],
                environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
              ),
              let item = item(dryRunOutput: String(decoding: data, as: UTF8.self), brew: brew)
        else { return [] }
        return [item]
    }

    static func item(dryRunOutput output: String, brew: String) -> SystemItem? {
        guard let bytes = freedBytes(dryRunOutput: output), bytes > 0 else { return nil }
        let count = output.split(separator: "\n").filter { $0.hasPrefix("Would remove") }.count
        // brew가 있는 곳(`/opt/homebrew/bin/brew` → `/opt/homebrew`)
        let prefix = ((brew as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return SystemItem(
            id: "homebrew.cleanup",
            ruleID: "homebrew.cleanup",
            tool: "Homebrew",
            title: "Homebrew 옛 버전·설치 파일",
            detail: "brew cleanup으로 지울 수 있는 항목 \(count)개 · 설치된 패키지는 그대로 둠",
            grade: .cache,
            restore: "옛 버전이 다시 필요하면 brew install로 설치",
            bytes: bytes,
            path: prefix,
            command: CleanupCommand(
                executable: brew,
                arguments: ["cleanup"],
                summary: "오래된 버전과 내려받은 설치 파일을 지움"
            ),
            selector: "homebrew"
        )
    }

    /// "This operation would free approximately 212.1MB of disk space." → 바이트.
    /// Homebrew는 1024 단위(KB, MB, GB)로 적는다.
    static func freedBytes(dryRunOutput output: String) -> Int64? {
        guard let match = output.firstMatch(of: /free approximately ([0-9.]+)\s*([KMGT]?B)/),
              let value = Double(match.1)
        else { return nil }
        let multiplier: Int64 = switch match.2 {
        case "KB": 1 << 10
        case "MB": 1 << 20
        case "GB": 1 << 30
        case "TB": 1 << 40
        default: 1
        }
        return Int64(value * Double(multiplier))
    }
}

/// 도구에 물어서 찾는 시스템 항목 전부.
public enum SystemItems {
    public static func find(homeDirectory: String = NSHomeDirectory()) async -> [SystemItem] {
        async let simulators = SimulatorItems.find(homeDirectory: homeDirectory)
        async let homebrew = HomebrewItems.find()
        return await simulators + homebrew + TemporaryFileItems.find()
    }
}
