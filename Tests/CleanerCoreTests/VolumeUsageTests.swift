import Foundation
import Testing
@testable import CleanerCore

@Suite struct VolumeUsageTests {
    /// `df -k`가 보고하는 사용량(바이트)과 남은 공간.
    private func df(_ path: String) throws -> (used: Int64, available: Int64) {
        let fields = try run("/bin/df", "-k", path)
            .split(separator: "\n").last?
            .split(whereSeparator: \.isWhitespace) ?? []
        let used = try #require(Int64(fields[2]))
        let available = try #require(Int64(fields[3]))
        return (used * 1024, available * 1024)
    }

    @Test func matchesDfForTheDataVolume() throws {
        let usage = try #require(VolumeUsage(path: NSHomeDirectory()))
        let reference = try df("/System/Volumes/Data")

        #expect(usage.mountPoint == "/System/Volumes/Data")
        // 측정 사이에 다른 프로그램이 디스크를 쓸 수 있어 0.5%까지 허용한다.
        #expect(abs(usage.usedBytes - reference.used) < reference.used / 200)
        #expect(abs(usage.availableBytes - reference.available) < max(reference.available / 50, 200_000_000))
        #expect(usage.containerUsedBytes > usage.usedBytes)
        #expect(usage.containerUsedBytes + usage.availableBytes == usage.capacityBytes)
    }
}
