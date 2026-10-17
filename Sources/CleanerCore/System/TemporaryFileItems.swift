import Darwin
import Foundation

/// 사용자 임시 폴더(`/var/folders/…/T`)에 도구가 남긴 임시 파일.
///
/// 정리 규칙은 폴더 단위라서, 파일 수천 개로 흩어진 것은 여기서 직접 세어 시스템 항목 하나로 만든다.
/// 지금 쓰는 파일을 건드리지 않도록 하루 넘게 바뀌지 않은 파일만 세고, 지울 때도 같은 조건으로 `find`가 지운다.
public enum TemporaryFileItems {
    struct Pattern {
        let id: String
        let tool: String
        let title: String
        let prefix: String
        let restore: String
        let detail: String
    }

    static let patterns = [
        Pattern(
            id: "codex.temporaryFiles", tool: "Codex", title: "Codex 임시 파일", prefix: ".com.openai.codex.",
            restore: "Codex를 실행하면 필요한 만큼 다시 만듦",
            detail: "Codex가 실행할 때 만들고 지우지 않은 파일"
        ),
    ]

    public static func find(
        directory: String? = UserDirectories.temporaryDirectory,
        minimumAge: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) -> [SystemItem] {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let cutoff = now.timeIntervalSince1970 - minimumAge
        return patterns.compactMap { pattern in
            var count = 0
            var bytes: Int64 = 0
            for name in names where name.hasPrefix(pattern.prefix) {
                var info = stat()
                guard lstat(directory + "/" + name, &info) == 0,
                      info.st_mode & S_IFMT == S_IFREG,
                      TimeInterval(info.st_mtimespec.tv_sec) < cutoff
                else { continue }
                count += 1
                bytes += Int64(info.st_blocks) * 512
            }
            guard count > 0 else { return nil }
            let minutes = Int(minimumAge / 60)
            return SystemItem(
                id: pattern.id,
                ruleID: pattern.id,
                tool: pattern.tool,
                title: "\(pattern.title) \(count.formatted())개",
                detail: "\(pattern.detail) · 하루 넘게 바뀌지 않은 것만 · \(directory)",
                grade: .cache,
                restore: pattern.restore,
                bytes: bytes,
                path: directory,
                command: CleanupCommand(
                    executable: "/usr/bin/find",
                    arguments: [directory, "-maxdepth", "1", "-type", "f", "-name", pattern.prefix + "*", "-mmin", "+\(minutes)", "-delete"],
                    summary: "임시 폴더에서 하루 넘은 \(pattern.title)을 지움"
                ),
                selector: pattern.id
            )
        }
    }
}
