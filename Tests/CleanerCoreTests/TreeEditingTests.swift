import Foundation
import Synchronization
import Testing
@testable import CleanerCore

/// 실제로 옮기지 않고 어떤 경로가 들어왔는지만 기록한다.
private final class RecordingTrash: Trashing {
    let paths = Mutex<[String]>([])

    func moveToTrash(_ path: String) throws -> String {
        paths.withLock { $0.append(path) }
        return "/recorded" + path
    }
}

@Suite struct TreeEditingTests {
    @Test func listsEntriesBySizeWithSmallFilesGrouped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("big.bin", bytes: 3_000_000)
        try fixture.file("a.txt", bytes: 1_000)
        try fixture.file("b.txt", bytes: 2_000)
        try fixture.file("folder/inner.bin", bytes: 2_000_000)
        let scanner = DiskScanner(options: ScanOptions(threadCount: 2, largeFileThreshold: 1 << 20))

        let root = try await scanner.scan(fixture.root).root

        #expect(root.entries.map(\.id) == ["f/big.bin", "d/folder", "small"])
        guard case .smallFiles(let count, let bytes, _) = root.entries.last else {
            Issue.record("작은 파일 묶음이 마지막에 있어야 한다")
            return
        }
        #expect(count == 2)
        #expect(bytes == fixture.allocatedBytes("a.txt") + fixture.allocatedBytes("b.txt"))
    }

    @Test func removingEntriesUpdatesAncestorTotals() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("parent/child/data.bin", bytes: 500_000)
        try fixture.file("parent/child/deeper/more.bin", bytes: 300_000)
        try fixture.file("parent/large.bin", bytes: 2_000_000)
        try fixture.file("parent/keep.bin", bytes: 100_000)
        let scanner = DiskScanner(options: ScanOptions(threadCount: 2, largeFileThreshold: 1 << 20))
        let root = try await scanner.scan(fixture.root).root
        let parent = try #require(root.child(named: "parent"))

        parent.removeChild(try #require(parent.child(named: "child")))
        parent.removeLargeFile(named: "large.bin")

        // 디스크에서 같은 것을 지우고 다시 스캔한 결과와 같아야 한다.
        try FileManager.default.removeItem(atPath: fixture.path("parent/child"))
        try FileManager.default.removeItem(atPath: fixture.path("parent/large.bin"))
        let rescanned = try await scanner.scan(fixture.root).root
        for (edited, fresh) in [(root, rescanned), (parent, try #require(rescanned.child(named: "parent")))] {
            #expect(edited.totalBytes == fresh.totalBytes)
            #expect(edited.totalUnsharedBytes == fresh.totalUnsharedBytes)
            #expect(edited.totalFileCount == fresh.totalFileCount)
            #expect(edited.totalDirectoryCount == fresh.totalDirectoryCount)
        }
        #expect(parent.entries.map(\.id) == ["small"])
    }

    @Test func comparatorSortsLikeSwiftUITable() {
        let older = Date(timeIntervalSince1970: 0)
        let newer = Date(timeIntervalSince1970: 100)
        func app(_ name: String, _ added: Date?) -> InstalledApplication {
            InstalledApplication(
                path: "/Applications/\(name).app", name: name, bundleIdentifier: nil, version: nil,
                identity: FileIdentity(device: 0, fileID: 0), allocatedBytes: 0, unsharedBytes: 0,
                addedDate: added, lastUsedDate: nil, isFromAppStore: false
            )
        }
        let apps = [app("B", older), app("A", nil), app("C", newer)]

        // Table은 열을 누를 때마다 같은 비교자의 order만 뒤집어 sorted(using:)에 넘긴다.
        var comparator = ApplicationComparator(.added)
        #expect(apps.sorted(using: [comparator]).map(\.name) == ["B", "C", "A"])
        comparator.order = .reverse
        #expect(apps.sorted(using: [comparator]).map(\.name) == ["C", "B", "A"])
    }

    @Test func usesAuthorizedTrashOnlyForUnwritableItems() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("locked/App.app/Contents/Info.plist", bytes: 100)
        try fixture.file("open/Other.app/Contents/Info.plist", bytes: 100)
        fixture.setMode("locked", 0o555)
        let result = try await DiskScanner().scan(fixture.root)
        func target(_ relativePath: String) throws -> DeletionTarget {
            let node = try #require(result.root.descendant(atPath: fixture.path(relativePath)))
            return DeletionTarget(
                path: fixture.path(relativePath), identity: FileIdentity(device: result.device, fileID: node.fileID),
                method: .moveToTrash, title: relativePath, allocatedBytes: node.totalBytes, unsharedBytes: node.totalUnsharedBytes
            )
        }
        let targets = [try target("locked/App.app"), try target("open/Other.app")]
        let policy = DeletionPolicy(allowedRoots: [fixture.root], protectedPaths: [])

        let strict = DeletionPlanner(policy: policy, isApplicationRunning: { _ in false }).plan(targets)
        let lenient = DeletionPlanner(policy: policy, isApplicationRunning: { _ in false }, authorizesTrash: true).plan(targets)

        #expect(strict.items.map(\.blocker) == [.requiresAdministrator, nil])
        #expect(lenient.items.map(\.blocker) == [nil, nil])
        #expect(lenient.items[0].warnings.contains(.requiresAuthorization))

        let trash = RecordingTrash()
        let authorized = RecordingTrash()
        let deleter = Deleter(policy: policy, trash: trash, authorizedTrash: authorized, logDirectory: nil)
        _ = try await deleter.execute(lenient)

        #expect(authorized.paths.withLock { $0 } == [fixture.path("locked/App.app")])
        #expect(trash.paths.withLock { $0 } == [fixture.path("open/Other.app")])
    }
}
