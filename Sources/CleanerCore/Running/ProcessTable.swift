import Darwin
import Foundation

/// 실행 중인 프로세스 하나. 같은 사용자의 프로세스만 읽을 수 있다.
public struct ProcessEntry: Sendable, Equatable {
    public let pid: Int32
    public let parentPID: Int32
    /// 실행 파일 이름(최대 32자).
    public let name: String
    /// 실행 파일 경로. 읽지 못하면 빈 문자열.
    public let path: String
    /// 활동 모니터의 "메모리"와 같은 값(phys_footprint).
    public let memoryBytes: Int64

    public init(pid: Int32, parentPID: Int32, name: String, path: String, memoryBytes: Int64) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.path = path
        self.memoryBytes = memoryBytes
    }
}

/// libproc으로 프로세스 목록과 각 프로세스의 정보를 읽는다.
public enum ProcessTable {
    /// `uid` 사용자의 프로세스. 다른 사용자(root 등)의 프로세스는 메모리를 읽을 수 없어 뺀다.
    public static func snapshot(ownedBy uid: uid_t = getuid()) -> [ProcessEntry] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(count, 0)).compactMap { pid in
            guard pid > 0, let info = bsdInfo(pid), info.pbi_uid == uid else { return nil }
            return ProcessEntry(
                pid: pid,
                parentPID: Int32(info.pbi_ppid),
                name: name(of: info),
                path: path(of: pid) ?? "",
                memoryBytes: memoryFootprint(of: pid) ?? 0
            )
        }
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func name(of info: proc_bsdinfo) -> String {
        // pbi_name이 비어 있으면(짧은 이름만 있는 경우) pbi_comm을 쓴다.
        let name = cString(info.pbi_name)
        return name.isEmpty ? cString(info.pbi_comm) : name
    }

    /// C 구조체 안의 고정 길이 문자 배열(튜플)을 문자열로 바꾼다.
    private static func cString<T>(_ tuple: T) -> String {
        var tuple = tuple
        let size = MemoryLayout<T>.size
        return withUnsafeBytes(of: &tuple) { bytes in
            let characters = bytes.prefix(size).prefix { $0 != 0 }
            return String(decoding: characters, as: UTF8.self)
        }
    }

    public static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func memoryFootprint(of pid: pid_t) -> Int64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Int64(usage.ri_phys_footprint) : nil
    }

    /// 프로세스의 현재 작업 폴더. 개발 서버가 어느 프로젝트에서 켜졌는지 알 때 쓴다.
    public static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// 프로세스를 실행한 인자(첫 번째는 실행 파일). `KERN_PROCARGS2`로 읽는다.
    public static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        // 인자 개수 다음에 실행 경로가 오고, NUL로 채운 뒤 인자들이 NUL로 나뉘어 이어진다.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// `roots`와 그 아래로 이어진 모든 자식 프로세스의 PID.
    public static func descendants(of roots: Set<Int32>, in processes: [ProcessEntry]) -> Set<Int32> {
        let children = Dictionary(grouping: processes, by: \.parentPID)
        var result = roots
        var queue = Array(roots)
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where result.insert(child.pid).inserted {
                queue.append(child.pid)
            }
        }
        return result
    }
}

/// 메모리와 스왑 상태. 활동 모니터의 메모리 탭과 같은 기준으로 센다.
public struct MemoryStatus: Sendable, Equatable {
    public enum Pressure: Sendable, Equatable {
        case normal
        case warning
        case critical
    }

    public let physicalBytes: Int64
    /// 앱 메모리 + 고정 메모리 + 압축된 메모리.
    public let usedBytes: Int64
    public let compressedBytes: Int64
    /// 디스크의 스왑 파일(`/System/Volumes/VM`)에 내보낸 양. 재시동하면 비워진다.
    public let swapUsedBytes: Int64
    public let swapTotalBytes: Int64
    public let pressure: Pressure

    public static func current() -> MemoryStatus? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Int64(sysconf(_SC_PAGESIZE))
        let appPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let used = (appPages + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        return MemoryStatus(
            physicalBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            usedBytes: used,
            compressedBytes: Int64(stats.compressor_page_count) * page,
            swapUsedBytes: hasSwap ? Int64(swap.xsu_used) : 0,
            swapTotalBytes: hasSwap ? Int64(swap.xsu_total) : 0,
            pressure: level >= 4 ? .critical : level >= 2 ? .warning : .normal
        )
    }
}
