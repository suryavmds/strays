import Darwin
import Foundation

/// Thin wrappers over libproc and sysctl.
///
/// Every call returns nil or an empty collection on failure (the process
/// died, or it belongs to another user), so callers never special-case
/// ESRCH or EPERM and a permission error can never crash a scan.
enum LibProc {
    struct TaskInfo: Sendable {
        /// Total user + system CPU time, in nanoseconds.
        let cpuTimeNanoseconds: UInt64
        let residentBytes: UInt64
    }

    struct SocketDescriptor {
        let fd: Int32
        let info: socket_fdinfo
    }

    static func allPIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<pid_t>.stride
        // Head-room for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(bytes) / stride + 64)
        let used = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard used > 0 else { return [] }
        return pids.prefix(Int(used) / stride).filter { $0 > 0 }
    }

    /// Basic facts for every process on the machine, in one system call.
    ///
    /// This uses `sysctl kern.proc.all` rather than libproc's
    /// `PROC_PIDTBSDINFO`, which the kernel refuses for other users'
    /// processes. Without those entries we would lose root-owned listeners,
    /// and ancestor chains would break at root-owned links such as `login`.
    static func allEntries() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        // The table can grow between the size probe and the read; retry.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            let capacity = size / stride + 64
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            size = capacity * stride
            if sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 {
                return buffer.prefix(size / stride).compactMap(entry(from:))
            }
        }
        return []
    }

    /// Basic facts for one process. Works for every process, including
    /// other users'.
    static func entry(for pid: pid_t) -> ProcessEntry? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // A PID that does not exist succeeds with a size of zero.
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return entry(from: info)
    }

    private static func entry(from info: kinfo_proc) -> ProcessEntry? {
        let pid = info.kp_proc.p_pid
        guard pid > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return ProcessEntry(
            identity: ProcessIdentity(
                pid: pid,
                startSeconds: UInt64(max(0, start.tv_sec)),
                startMicroseconds: UInt64(max(0, start.tv_usec))
            ),
            ppid: info.kp_eproc.e_ppid,
            pgid: info.kp_eproc.e_pgid,
            uid: info.kp_eproc.e_ucred.cr_uid,
            name: string(fromFixedBuffer: info.kp_proc.p_comm)
        )
    }

    static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return string(fromCString: buffer)
    }

    static func workingDirectory(for pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = string(fromFixedBuffer: info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    static func taskInfo(for pid: pid_t) -> TaskInfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user &+ info.pti_total_system
        return TaskInfo(
            cpuTimeNanoseconds: machTicksToNanoseconds(ticks),
            residentBytes: info.pti_resident_size
        )
    }

    /// Raw KERN_PROCARGS2 buffer: argc, executable path, argv, environment.
    /// Same-user processes only.
    static func rawArguments(for pid: pid_t) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) != 0 {
            // The arguments grew between the two calls; retry with the maximum.
            size = argumentMaximum
            buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        }
        return Array(buffer.prefix(size))
    }

    /// Every socket the process holds, or nil when we may not look (another
    /// user's process) or the process is gone.
    ///
    /// The size probe alone is not a permission check: it succeeds for
    /// root's processes too. Only the real read tells us.
    static func sockets(for pid: pid_t) -> [SocketDescriptor]? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let used = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard used > 0 else { return nil }

        var result: [SocketDescriptor] = []
        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize {
                result.append(SocketDescriptor(fd: fd.proc_fd, info: info))
            }
        }
        return result
    }

    // MARK: - Helpers

    private static let argumentMaximum: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }()

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// libproc reports CPU time in Mach ticks, which are not nanoseconds on
    /// Apple Silicon.
    static func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        guard timebase.denom != 0, timebase.numer != timebase.denom else { return ticks }
        let (high, low) = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        return UInt64(timebase.denom).dividingFullWidth((high, low)).quotient
    }

    /// Reads a NUL-terminated C string out of a buffer we filled.
    static func string(fromCString buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Reads a NUL-terminated C string out of a fixed-size tuple field.
    static func string<T>(fromFixedBuffer buffer: T) -> String {
        withUnsafeBytes(of: buffer) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
