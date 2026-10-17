import Darwin
import Foundation

/// 경로가 있는 볼륨과 그 볼륨이 속한 APFS 컨테이너의 사용량.
///
/// APFS에서는 한 컨테이너의 여러 볼륨(macOS, 데이터, Preboot, Recovery, VM)이 공간을 나눠 쓴다.
/// `statfs`의 남은 블록은 컨테이너 기준이라, 볼륨 하나의 사용량은 `ATTR_VOL_SPACEUSED`로 따로 읽는다(`df`와 같은 방식).
public struct VolumeUsage: Sendable, Equatable {
    public let mountPoint: String
    /// 이 볼륨만 쓰는 크기. `df`의 Used와 같다.
    public let usedBytes: Int64
    /// 컨테이너의 모든 볼륨이 쓰는 크기. 시스템 설정의 "사용 중"과 같다.
    public let containerUsedBytes: Int64
    /// 컨테이너에 남은 공간. 같은 컨테이너의 볼륨이 함께 쓴다.
    public let availableBytes: Int64
    /// 컨테이너 전체 크기.
    public let capacityBytes: Int64

    /// 같은 컨테이너의 다른 볼륨(macOS, Preboot, Recovery, VM 등)이 쓰는 크기.
    public var otherVolumesBytes: Int64 { containerUsedBytes - usedBytes }

    /// `path`가 있는 볼륨을 찾는다. `/Users`처럼 펌링크된 경로도 실제 장치 번호로 데이터 볼륨을 찾는다.
    public init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }

        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return nil }
        let volumes = UnsafeBufferPointer(start: mounts, count: Int(count))
        guard let volume = volumes.first(where: { $0.f_fsid.val.0 == info.st_dev }) else { return nil }

        let blockSize = Int64(volume.f_bsize)
        let mountPoint = withUnsafeBytes(of: volume.f_mntonname) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        self.mountPoint = mountPoint
        containerUsedBytes = (Int64(volume.f_blocks) - Int64(volume.f_bfree)) * blockSize
        availableBytes = Int64(volume.f_bavail) * blockSize
        capacityBytes = Int64(volume.f_blocks) * blockSize
        usedBytes = Self.spaceUsed(mountPoint: mountPoint) ?? containerUsedBytes
    }

    /// 볼륨 하나가 쓰는 크기. APFS가 아니라서 값을 주지 않으면 nil.
    private static func spaceUsed(mountPoint: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)

        // 응답은 [전체 길이 u_int32][off_t 사용량] 순서다.
        var buffer = (UInt32(0), Int64(0))
        let result = withUnsafeMutableBytes(of: &buffer) { bytes in
            getattrlist(mountPoint, &request, bytes.baseAddress, bytes.count, 0)
        }
        guard result == 0 else { return nil }
        return withUnsafeBytes(of: &buffer) { $0.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: Int64.self) }
    }
}
