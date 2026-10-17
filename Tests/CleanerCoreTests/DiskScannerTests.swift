import Darwin
import Foundation
import Testing
@testable import CleanerCore

@Suite struct DiskScannerTests {
    let scanner = DiskScanner(options: ScanOptions(threadCount: 4))

    @Test func sumsAllocatedSizesOfNestedFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("a.bin", bytes: 10_000)
        try fixture.file("sub/b.bin", bytes: 200_000)
        try fixture.file("sub/deeper/c.bin", bytes: 3_000_000)

        let result = try await scanner.scan(fixture.root)

        let subBytes = fixture.allocatedBytes("sub/b.bin") + fixture.allocatedBytes("sub/deeper/c.bin")
        #expect(result.root.totalBytes == fixture.allocatedBytes("a.bin") + subBytes)
        #expect(result.root.totalUnsharedBytes == result.root.totalBytes)
        #expect(result.root.totalFileCount == 3)
        #expect(result.root.totalDirectoryCount == 2)
        let sub = try #require(result.root.child(named: "sub"))
        #expect(sub.totalBytes == subBytes)
        #expect(sub.child(named: "deeper")?.path == fixture.path("sub/deeper"))
        #expect(result.issues.isEmpty)

        var info = stat()
        #expect(lstat(fixture.path("sub"), &info) == 0)
        #expect(sub.fileID == info.st_ino)
        #expect(result.device == info.st_dev)
        #expect(lstat(fixture.root, &info) == 0)
        #expect(result.root.fileID == info.st_ino)
    }

    @Test func countsHardLinkedFileOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("one/data.bin", bytes: 500_000)
        try fixture.directory("two")
        #expect(link(fixture.path("one/data.bin"), fixture.path("two/data.bin")) == 0)

        let result = try await scanner.scan(fixture.root)

        let fileBytes = fixture.allocatedBytes("one/data.bin")
        #expect(result.root.totalBytes == fileBytes)
        #expect(result.skippedHardLinkBytes == fileBytes)
        #expect(result.root.totalFileCount == 2)
    }

    @Test func doesNotFollowSymlinks() async throws {
        let outside = try Fixture()
        let fixture = try Fixture()
        defer {
            fixture.remove()
            outside.remove()
        }
        try outside.file("big.bin", bytes: 2_000_000)
        try fixture.file("small.bin", bytes: 1_000)
        #expect(symlink(outside.root, fixture.path("to-outside")) == 0)
        #expect(symlink(fixture.root, fixture.path("loop")) == 0)

        let result = try await scanner.scan(fixture.root)

        #expect(result.root.children.isEmpty)
        #expect(result.root.totalFileCount == 3)
        #expect(result.root.totalBytes < 100_000)
    }

    @Test func separatesBlocksSharedWithClones() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("original.bin", bytes: 3_000_000)
        try fixture.file("alone.bin", bytes: 500_000)
        #expect(clonefile(fixture.path("original.bin"), fixture.path("clone.bin"), 0) == 0)

        let result = try await scanner.scan(fixture.root)

        let cloneBytes = fixture.allocatedBytes("original.bin")
        let aloneBytes = fixture.allocatedBytes("alone.bin")
        #expect(result.root.totalBytes == cloneBytes * 2 + aloneBytes)
        #expect(result.root.totalUnsharedBytes == aloneBytes)
        #expect(Set(result.root.largeFiles.map(\.unsharedBytes)) == [0])
    }

    @Test func usesAllocatedSizeForSparseFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fd = open(fixture.path("sparse.img"), O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        #expect(ftruncate(fd, 1 << 30) == 0)
        close(fd)

        let result = try await scanner.scan(fixture.root)

        #expect(result.root.totalBytes == fixture.allocatedBytes("sparse.img"))
        #expect(result.root.totalBytes < 1 << 20)
    }

    @Test func recordsUnreadableDirectoryAndKeepsScanning() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("locked/secret.bin", bytes: 100_000)
        try fixture.file("open/visible.bin", bytes: 100_000)
        fixture.lock("locked")

        let result = try await scanner.scan(fixture.root)

        #expect(result.root.child(named: "locked")?.status == .unreadable(errno: EACCES))
        #expect(result.issues == [ScanIssue(path: fixture.path("locked"), errno: EACCES)])
        #expect(result.root.totalBytes == fixture.allocatedBytes("open/visible.bin"))
    }

    @Test func namesOnlyFilesAboveThreshold() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("big.bin", bytes: 2_000_000)
        try fixture.file("small.bin", bytes: 1_000)
        let scanner = DiskScanner(options: ScanOptions(threadCount: 2, largeFileThreshold: 1 << 20))

        let result = try await scanner.scan(fixture.root)

        #expect(result.root.largeFiles.map(\.name) == ["big.bin"])
        #expect(result.root.ownFileCount == 2)
    }

    @Test func skipsExcludedPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("keep/a.bin", bytes: 100_000)
        try fixture.file("skip/b.bin", bytes: 100_000)
        let scanner = DiskScanner(options: ScanOptions(threadCount: 2, excludedPaths: [fixture.path("skip")]))

        let result = try await scanner.scan(fixture.root)

        #expect(result.root.child(named: "skip")?.status == .excluded)
        #expect(result.root.totalBytes == fixture.allocatedBytes("keep/a.bin"))
    }

    @Test(arguments: [1, 8])
    func matchesDuRegardlessOfThreadCount(threads: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for branch in 0..<20 {
            for leaf in 0..<5 {
                try fixture.file("d\(branch)/e\(leaf)/f.bin", bytes: (branch * 5 + leaf + 1) * 7_000)
            }
        }

        let result = try await DiskScanner(options: ScanOptions(threadCount: threads)).scan(fixture.root)

        #expect(result.root.totalBytes / 1024 == (try duKiB(fixture.root)))
        #expect(result.root.totalFileCount == 100)
        #expect(result.root.totalDirectoryCount == 120)
    }

    @Test func stopsAtMountedVolumes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("tree/local.bin", bytes: 100_000)
        let mountPoint = try fixture.directory("tree/mnt")
        let image = fixture.path("volume.dmg")
        try run("/usr/bin/hdiutil", "create", "-size", "8m", "-fs", "APFS", "-volname", "CleanerTest", image)
        try run("/usr/bin/hdiutil", "attach", image, "-mountpoint", mountPoint, "-nobrowse")
        defer { _ = try? run("/usr/bin/hdiutil", "detach", mountPoint, "-force") }
        try fixture.file("tree/mnt/inside.bin", bytes: 1_000_000)

        let result = try await scanner.scan(fixture.path("tree"))

        #expect(result.root.child(named: "mnt")?.status == .otherVolume)
        #expect(result.root.totalBytes == fixture.allocatedBytes("tree/local.bin"))
    }

    @Test func givesUpOnDirectoriesThatDoNotOpenInTime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("slow/inside.bin", bytes: 100_000)
        try fixture.file("fast/visible.bin", bytes: 100_000)
        let slow = fixture.path("slow")
        var options = ScanOptions(threadCount: 2, directoryTimeout: .milliseconds(500))
        // 권한 확인 창을 기다리며 open()이 멈춘 것처럼, 이 폴더만 3초 동안 붙잡는다.
        options.beforeReading = { path in
            if path == slow { Thread.sleep(forTimeInterval: 3) }
        }

        let start = ContinuousClock.now
        let result = try await DiskScanner(options: options).scan(fixture.root)
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(2.5))
        #expect(result.root.child(named: "slow")?.status == .unreadable(errno: ETIMEDOUT))
        #expect(result.issues == [ScanIssue(path: slow, errno: ETIMEDOUT)])
        #expect(result.root.totalBytes == fixture.allocatedBytes("fast/visible.bin"))
    }

    @Test func keepsScanningWhenEveryWorkerIsStuck() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for name in ["a", "b", "c"] {
            try fixture.file("stuck-\(name)/x.bin", bytes: 1_000)
        }
        try fixture.file("ok/deep/y.bin", bytes: 50_000)
        var options = ScanOptions(threadCount: 2, directoryTimeout: .milliseconds(300))
        // 워커 수(2)보다 많은 폴더가 멈춰도, 대신할 워커를 띄워 나머지를 끝까지 읽어야 한다.
        options.beforeReading = { path in
            if (path as NSString).lastPathComponent.hasPrefix("stuck-") { Thread.sleep(forTimeInterval: 2) }
        }

        let result = try await DiskScanner(options: options).scan(fixture.root)

        #expect(result.issues.count == 3)
        #expect(result.root.totalBytes == fixture.allocatedBytes("ok/deep/y.bin"))
    }

    @Test func throwsWhenCancelled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("a.bin", bytes: 1_000)
        let scanner = scanner
        let root = fixture.root

        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await scanner.scan(root)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func rejectsFileAsRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = try fixture.file("a.bin", bytes: 10)

        await #expect(throws: ScanError.notADirectory(path: file)) {
            try await scanner.scan(file)
        }
    }
}
