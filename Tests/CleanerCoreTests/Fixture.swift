import Darwin
import Foundation
@testable import CleanerCore

/// 테스트용 임시 디렉터리. 테스트가 끝나면 `remove()`로 권한을 되돌린 뒤 지운다.
///
/// ARC가 마지막 사용 직후 객체를 해제할 수 있어서 deinit에서 지우지 않는다. 스캔 도중에 다른 fixture가
/// 사라지면 테스트가 엉뚱한 이유로 통과할 수 있다.
final class Fixture {
    let root: String
    private var lockedPaths: [String] = []

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = realpath(base.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(resolved) }
        root = String(cString: resolved)
    }

    func path(_ relativePath: String) -> String {
        root + "/" + relativePath
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> String {
        let path = path(relativePath)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// 0이 아닌 바이트로 채운 파일을 만든다. 상위 디렉터리도 함께 만든다.
    @discardableResult
    func file(_ relativePath: String, bytes: Int) throws -> String {
        let path = path(relativePath)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// lstat이 보고하는 할당 크기. 스캐너 결과와 비교할 기준값이다.
    func allocatedBytes(_ relativePath: String) -> Int64 {
        var info = stat()
        precondition(lstat(path(relativePath), &info) == 0, "lstat failed: \(relativePath)")
        return Int64(info.st_blocks) * 512
    }

    /// 아무도 읽을 수 없게 권한을 0으로 바꾼다.
    func lock(_ relativePath: String) {
        setMode(relativePath, 0)
    }

    /// 권한을 바꾼다. `remove()`가 0o755로 되돌린다.
    func setMode(_ relativePath: String, _ mode: mode_t) {
        let path = path(relativePath)
        precondition(chmod(path, mode) == 0)
        lockedPaths.append(path)
    }

    func remove() {
        for path in lockedPaths {
            chmod(path, 0o755)
        }
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// 휴지통 대신 fixture 안의 폴더로 옮긴다. 테스트가 사용자의 실제 휴지통을 건드리지 않게 한다.
/// 이름이 겹치면 Finder처럼 뒤에 번호를 붙인다.
struct FixtureTrash: Trashing {
    let directory: String

    func moveToTrash(_ path: String) throws -> String {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        var destination = directory + "/" + name
        var number = 2
        while FileManager.default.fileExists(atPath: destination) {
            destination = directory + "/\(name) \(number)"
            number += 1
        }
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return destination
    }
}

struct CommandFailed: Error, CustomStringConvertible {
    let command: [String]
    let status: Int32
    let output: String

    var description: String { "\(command.joined(separator: " ")) → \(status)\n\(output)" }
}

@discardableResult
func run(_ executable: String, _ arguments: String...) throws -> String {
    try run(executable, arguments)
}

@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CommandFailed(command: [executable] + arguments, status: process.terminationStatus, output: output)
    }
    return output
}

/// `du -skx`가 보고하는 KiB. 같은 볼륨만, 하드링크는 한 번만 센다.
func duKiB(_ path: String) throws -> Int64 {
    let output = try run("/usr/bin/du", "-skx", path)
    guard let field = output.split(whereSeparator: \.isWhitespace).first, let kib = Int64(field) else {
        throw CommandFailed(command: ["du", "-skx", path], status: 0, output: output)
    }
    return kib
}

extension DirectoryNode {
    func child(named name: String) -> DirectoryNode? {
        children.first { $0.name == name }
    }
}
