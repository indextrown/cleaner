import AppKit
import CleanerCore
import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func date(_ date: Date?) -> String {
        date?.formatted(date: .numeric, time: .omitted) ?? "기록 없음"
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case ScanError.cannotAccess(let path, let code): "\(path): \(String(cString: strerror(code)))"
        case ScanError.notADirectory(let path): "\(path): 폴더가 아닙니다"
        default: error.localizedDescription
        }
    }
}

enum Finder {
    static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    /// 시스템 설정의 "전체 디스크 접근 권한" 화면을 연다. 권한은 사용자가 직접 켠다.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 오래 걸리는 작업 동안 App Nap을 막는다. 창이 뒤에 있으면 macOS가 앱을 느리게 돌려 스캔이 몇 배 늦어진다.
@MainActor
enum BackgroundActivity {
    static func run<T>(_ reason: String, _ work: () async throws -> T) async rethrows -> T {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
        defer { ProcessInfo.processInfo.endActivity(activity) }
        return try await work()
    }
}

/// 앱 아이콘을 경로별로 한 번만 읽는다.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

extension DeletionResult.Status {
    var succeeded: Bool {
        switch self {
        case .removed, .movedToTrash, .commandSucceeded: true
        case .skipped, .failed: false
        }
    }
}

extension DeletionReport {
    /// "지움 3 · 휴지통 1 (2.1 GB) · Foo 실패: …" 같은 한 줄 요약.
    var summary: String {
        var counts: [String] = []
        let removed = results.filter { $0.status == .removed }.count
        let trashed = results.filter { if case .movedToTrash = $0.status { true } else { false } }.count
        let commands = results.filter { $0.status == .commandSucceeded }.count
        if removed > 0 { counts.append("지움 \(removed)") }
        if trashed > 0 { counts.append("휴지통 \(trashed)") }
        if commands > 0 { counts.append("명령 \(commands)") }
        let bytes = results.filter(\.status.succeeded).reduce(0) { $0 + $1.item.target.allocatedBytes }
        var parts = [(counts.isEmpty ? "처리한 항목 없음" : counts.joined(separator: " · ")) + " (\(Format.bytes(bytes)))"]
        for result in results {
            switch result.status {
            case .skipped(let reason):
                parts.append("\(result.item.target.title) 건너뜀: \(reason.explanation)")
            case .failed(let message):
                parts.append("\(result.item.target.title) 실패: \(message)")
            default:
                break
            }
        }
        return parts.joined(separator: " · ")
    }
}
