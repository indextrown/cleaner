import Darwin

/// getattrlistbulk(2)가 돌려준 디렉터리 항목 하나.
struct DirectoryEntry {
    enum Kind {
        case file
        case directory
        case symlink
        case other
    }

    var name: String
    var kind: Kind
    var fileID: UInt64
    var linkCount: UInt32
    /// 디스크에 실제로 할당된 바이트. 희소 파일은 논리 크기보다 작다.
    var allocatedBytes: Int64
    /// 삭제하면 바로 비워지는 바이트. APFS 클론이나 스냅샷과 공유하는 블록은 빠진다.
    /// 볼륨이 이 값을 주지 않으면(APFS가 아니면) `allocatedBytes`와 같다.
    var unsharedBytes: Int64
    /// 다른 볼륨이 마운트된 지점이나 autofs 트리거라서 들어가면 안 되는 디렉터리다.
    var isVolumeBoundary: Bool
    /// 이 항목의 속성을 읽지 못했을 때의 errno. 0이면 정상이다.
    var error: Int32
}

enum DirectoryReadError: Error {
    case open(errno: Int32)
    case read(errno: Int32)
    /// 열어 보니 스캔을 시작한 볼륨과 다른 장치였다.
    case otherVolume
}

/// 디렉터리를 getattrlistbulk(2)로 읽는다.
///
/// 시스템 콜 한 번에 항목 여러 개의 이름, 종류, inode, 할당 크기를 받는다. 항목마다 lstat을 부르는
/// `FileManager.enumerator`보다 시스템 콜 수가 훨씬 적다. 버퍼를 재사용하므로 스레드마다 하나씩 만든다.
final class DirectoryReader {
    private static let bufferSize = 256 * 1024

    private let buffer: UnsafeMutableRawPointer
    private var request: attrlist

    init() {
        buffer = .allocate(byteCount: Self.bufferSize, alignment: 16)
        request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = ATTR_CMN_RETURNED_ATTRS
            | attrgroup_t(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
        // FSOPT_ATTR_CMN_EXTENDED를 주면 forkattr 자리를 확장 common 속성(ATTR_CMNEXT_*)으로 읽는다.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
    }

    deinit {
        buffer.deallocate()
    }

    /// `path`의 항목을 모두 읽어 `entries`에 덧붙인다.
    ///
    /// 경로 마지막 요소가 심볼릭 링크면 열지 않는다. 열린 디렉터리가 `device`와 다른 볼륨이면 읽지 않는다.
    func read(path: String, device: dev_t, into entries: inout [DirectoryEntry]) throws(DirectoryReadError) {
        let fd = Self.retryingOnInterrupt { open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw .open(errno: errno) }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .open(errno: errno) }
        guard info.st_dev == device else { throw .otherVolume }

        while true {
            let count = Self.retryingOnInterrupt {
                getattrlistbulk(fd, &request, buffer, Self.bufferSize, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            }
            if count == 0 { return }
            guard count > 0 else { throw .read(errno: errno) }

            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = cursor.loadUnaligned(as: UInt32.self)
                entries.append(Self.parseEntry(at: cursor + MemoryLayout<UInt32>.size, device: device))
                cursor += Int(length)
            }
        }
    }

    /// 시그널에 끊긴 시스템 콜(EINTR)을 몇 번까지 다시 부른다. 아무것도 읽지 않은 채 끊긴 것이라
    /// 그대로 다시 불러도 디렉터리 위치가 어긋나지 않는다.
    private static func retryingOnInterrupt(_ call: () -> Int32) -> Int32 {
        var result = call()
        var attempts = 1
        while result < 0, errno == EINTR, attempts < 5 {
            result = call()
            attempts += 1
        }
        return result
    }

    /// 항목 하나를 해석한다. 속성은 요청한 그룹 순서(common → dir → file → fork)와 그룹 안의 비트 순서로
    /// 붙어 있고, 실제로 돌려준 속성만 들어 있으므로 `returned` 비트를 보고 하나씩 읽는다.
    /// ATTR_CMN_ERROR는 비트 순서와 상관없이 ATTR_CMN_RETURNED_ATTRS 바로 뒤에 온다.
    private static func parseEntry(at start: UnsafeRawPointer, device: dev_t) -> DirectoryEntry {
        var field = start
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        func has(_ group: attrgroup_t, _ attribute: Int32) -> Bool {
            group & attrgroup_t(attribute) != 0
        }

        var error: Int32 = 0
        if has(returned.commonattr, ATTR_CMN_ERROR) {
            error = Int32(bitPattern: field.loadUnaligned(as: UInt32.self))
            field += MemoryLayout<UInt32>.size
        }

        var name = ""
        if has(returned.commonattr, ATTR_CMN_NAME) {
            let reference = field.loadUnaligned(as: attrreference_t.self)
            let characters = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
            name = String(cString: characters)
            field += MemoryLayout<attrreference_t>.size
        }

        var entryDevice = device
        if has(returned.commonattr, ATTR_CMN_DEVID) {
            entryDevice = field.loadUnaligned(as: dev_t.self)
            field += MemoryLayout<dev_t>.size
        }

        var objectType = fsobj_type_t(VNON.rawValue)
        if has(returned.commonattr, ATTR_CMN_OBJTYPE) {
            objectType = field.loadUnaligned(as: fsobj_type_t.self)
            field += MemoryLayout<fsobj_type_t>.size
        }

        var fileID: UInt64 = 0
        if has(returned.commonattr, ATTR_CMN_FILEID) {
            fileID = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }

        var mountStatus: UInt32 = 0
        if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) {
            mountStatus = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }

        var linkCount: UInt32 = 1
        if has(returned.fileattr, ATTR_FILE_LINKCOUNT) {
            linkCount = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }

        var allocatedBytes: Int64 = 0
        if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) {
            allocatedBytes = field.loadUnaligned(as: off_t.self)
            field += MemoryLayout<off_t>.size
        }

        var unsharedBytes = allocatedBytes
        if has(returned.forkattr, ATTR_CMNEXT_PRIVATESIZE) {
            unsharedBytes = field.loadUnaligned(as: off_t.self)
            field += MemoryLayout<off_t>.size
        }

        let kind: DirectoryEntry.Kind = switch objectType {
        case fsobj_type_t(VREG.rawValue): .file
        case fsobj_type_t(VDIR.rawValue): .directory
        case fsobj_type_t(VLNK.rawValue): .symlink
        default: .other
        }

        let boundaryFlags = UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER)
        let isVolumeBoundary = kind == .directory
            && (entryDevice != device || mountStatus & boundaryFlags != 0)

        return DirectoryEntry(
            name: name,
            kind: kind,
            fileID: fileID,
            linkCount: linkCount,
            allocatedBytes: allocatedBytes,
            unsharedBytes: unsharedBytes,
            isVolumeBoundary: isVolumeBoundary,
            error: error
        )
    }
}
