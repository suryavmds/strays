import Darwin
import Foundation

/// Reads the expensive per-process facts (arguments, environment, cwd, CPU,
/// memory) for the processes we care about.
///
/// The executable path, arguments, and environment are cached per process
/// identity. CPU usage is derived from the change in CPU time between two
/// consecutive calls, so the first reading for a process is always zero.
public actor ProcessInspector {
    private struct StaticFacts {
        var executablePath: String?
        var arguments: [String]
        var environment: [String: String]
        /// The kernel's process name when we read the facts. It changes on
        /// exec, which is our cue to read them again.
        var name: String
        var readAt: UInt64
    }

    /// A process can exec a program with the same name (`sh -c 'exec sh …'`),
    /// which the name check misses. Re-reading now and then catches it.
    private static let factsLifetime: UInt64 = 30 * 1_000_000_000

    private struct CPUSample {
        var cpuTimeNanoseconds: UInt64
        var uptimeNanoseconds: UInt64
        var percent: Double
    }

    private let currentUID = getuid()
    private var staticFacts: [ProcessIdentity: StaticFacts] = [:]
    private var pathCache: [ProcessIdentity: (name: String, path: String?)] = [:]
    private var cpuSamples: [ProcessIdentity: CPUSample] = [:]
    private var usernames: [UInt32: String] = [:]

    public init() {}

    /// The executable path alone: one cheap call, cached. Used to pre-filter
    /// processes before paying for full details.
    public func executablePaths(for entries: [ProcessEntry]) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for entry in entries {
            if let cached = pathCache[entry.identity], cached.name == entry.name {
                result[entry.pid] = cached.path
                continue
            }
            let path = LibProc.executablePath(for: entry.pid)
            pathCache[entry.identity] = (entry.name, path)
            result[entry.pid] = path
        }
        return result
    }

    public func details(for entries: [ProcessEntry]) -> [Int32: ProcessDetails] {
        let now = DispatchTime.now().uptimeNanoseconds
        var result: [Int32: ProcessDetails] = [:]
        result.reserveCapacity(entries.count)
        for entry in entries {
            result[entry.pid] = details(for: entry, uptime: now)
        }
        return result
    }

    /// Drops cached state for processes that no longer exist.
    public func prune(keeping table: ProcessTable) {
        let alive = Set(table.entries.values.map(\.identity))
        staticFacts = staticFacts.filter { alive.contains($0.key) }
        pathCache = pathCache.filter { alive.contains($0.key) }
        cpuSamples = cpuSamples.filter { alive.contains($0.key) }
    }

    // MARK: - Private

    private func details(for entry: ProcessEntry, uptime: UInt64) -> ProcessDetails {
        let facts = facts(for: entry, uptime: uptime)
        let task = LibProc.taskInfo(for: entry.pid)
        let isInspectable = task != nil || !facts.arguments.isEmpty

        return ProcessDetails(
            entry: entry,
            executablePath: facts.executablePath,
            arguments: facts.arguments,
            environment: facts.environment,
            cwd: LibProc.workingDirectory(for: entry.pid),
            username: username(for: entry.uid),
            cpuPercent: task.map { cpuPercent(for: entry.identity, cpuTime: $0.cpuTimeNanoseconds, uptime: uptime) } ?? 0,
            residentBytes: task?.residentBytes ?? 0,
            isInspectable: isInspectable
        )
    }

    private func facts(for entry: ProcessEntry, uptime: UInt64) -> StaticFacts {
        if let cached = staticFacts[entry.identity], cached.name == entry.name,
           uptime &- cached.readAt < Self.factsLifetime {
            return cached
        }
        let parsed = LibProc.rawArguments(for: entry.pid).flatMap(ProcArgsParser.parse)
        let path = LibProc.executablePath(for: entry.pid) ?? parsed?.executablePath
        let facts = StaticFacts(
            executablePath: path?.isEmpty == false ? path : nil,
            arguments: parsed?.arguments ?? [],
            environment: parsed?.environment ?? [:],
            name: entry.name,
            readAt: uptime
        )
        staticFacts[entry.identity] = facts
        return facts
    }

    private func cpuPercent(for identity: ProcessIdentity, cpuTime: UInt64, uptime: UInt64) -> Double {
        defer {
            cpuSamples[identity]?.cpuTimeNanoseconds = cpuTime
            cpuSamples[identity]?.uptimeNanoseconds = uptime
        }
        guard let previous = cpuSamples[identity] else {
            cpuSamples[identity] = CPUSample(cpuTimeNanoseconds: cpuTime, uptimeNanoseconds: uptime, percent: 0)
            return 0
        }
        let elapsed = uptime &- previous.uptimeNanoseconds
        // Two calls in the same instant: keep the previous reading rather
        // than dividing by nearly zero.
        guard elapsed > 50_000_000, cpuTime >= previous.cpuTimeNanoseconds else { return previous.percent }
        let percent = Double(cpuTime - previous.cpuTimeNanoseconds) / Double(elapsed) * 100
        cpuSamples[identity]?.percent = percent
        return percent
    }

    private func username(for uid: UInt32) -> String {
        if let cached = usernames[uid] { return cached }
        let name = getpwuid(uid).flatMap { $0.pointee.pw_name }.map { String(cString: $0) } ?? "\(uid)"
        usernames[uid] = name
        return name
    }
}
