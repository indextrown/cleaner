import Foundation

/// 삭제 기록을 JSON Lines(한 줄에 JSON 객체 하나)로 남긴다. 도중에 멈춰도 그때까지 처리한 기록은 남는다.
///
/// 첫 줄은 `start`, 항목마다 `item`, 마지막 줄은 `finish`다.
final class DeletionLog {
    let path: String
    private let handle: FileHandle
    private let encoder: JSONEncoder

    init(directory: String, date: Date = Date()) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        path = directory + "/cleanup-\(formatter.string(from: date)).jsonl"
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    deinit {
        try? handle.close()
    }

    func write(_ record: some Encodable) throws {
        var data = try encoder.encode(record)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}

struct StartRecord: Encodable {
    let type = "start"
    let date: Date
    let freeBytes: Int64
    let itemCount: Int
}

struct ItemRecord: Encodable {
    let type = "item"
    let date: Date
    let path: String
    let title: String
    let ruleID: String?
    let grade: String?
    /// remove, trash, command
    let method: String
    let command: String?
    let allocatedBytes: Int64
    let unsharedBytes: Int64
    /// removed, trashed, commandSucceeded, skipped, failed
    let status: String
    let detail: String?
    let trashedPath: String?
    let seconds: Double

    init(_ result: DeletionResult, date: Date = Date()) {
        let target = result.item.target
        self.date = date
        path = target.path
        title = target.title
        ruleID = target.ruleID
        grade = target.grade.map { "\($0)" }
        switch target.method {
        case .remove:
            method = "remove"
            command = nil
        case .moveToTrash:
            method = "trash"
            command = nil
        case .command(let cleanupCommand):
            method = "command"
            command = cleanupCommand.commandLine
        }
        allocatedBytes = target.allocatedBytes
        unsharedBytes = target.unsharedBytes
        switch result.status {
        case .removed:
            status = "removed"
            detail = nil
            trashedPath = nil
        case .movedToTrash(let destination):
            status = "trashed"
            detail = nil
            trashedPath = destination
        case .commandSucceeded:
            status = "commandSucceeded"
            if case .command(let cleanupCommand) = target.method, cleanupCommand.completesInBackground {
                detail = "도구가 뒤에서 마저 지움"
            } else {
                detail = nil
            }
            trashedPath = nil
        case .skipped(let reason):
            status = "skipped"
            detail = reason.explanation
            trashedPath = nil
        case .failed(let message):
            status = "failed"
            detail = message
            trashedPath = nil
        }
        let components = result.duration.components
        seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

struct FinishRecord: Encodable {
    let type = "finish"
    let date: Date
    let freeBytes: Int64
    /// 시작할 때보다 늘어난 여유 공간. 다른 프로그램이 같은 시간에 쓴 양만큼 어긋날 수 있다.
    let reclaimedBytes: Int64
}
