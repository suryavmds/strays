import Foundation

/// A PID alone is not an identity: PIDs get reused. Pairing it with the start
/// time lets us prove we are still talking about the same process before we
/// signal it.
public struct ProcessIdentity: Hashable, Sendable, Codable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    public var startDate: Date {
        Date(timeIntervalSince1970: Double(startSeconds) + Double(startMicroseconds) / 1_000_000)
    }

    /// Stable string form, used in item identifiers.
    public var key: String { "\(pid).\(startSeconds).\(startMicroseconds)" }
}

/// The cheap facts we read for every process on the machine.
public struct ProcessEntry: Hashable, Sendable {
    public let identity: ProcessIdentity
    public let ppid: Int32
    public let pgid: Int32
    public let uid: UInt32
    public let name: String

    public init(identity: ProcessIdentity, ppid: Int32, pgid: Int32, uid: UInt32, name: String) {
        self.identity = identity
        self.ppid = ppid
        self.pgid = pgid
        self.uid = uid
        self.name = name
    }

    public var pid: Int32 { identity.pid }
}

/// A point-in-time view of every process, indexed for tree walks.
public struct ProcessTable: Sendable {
    public let entries: [Int32: ProcessEntry]
    private let childIndex: [Int32: [Int32]]

    public init(entries: [ProcessEntry]) {
        var byPID: [Int32: ProcessEntry] = [:]
        var children: [Int32: [Int32]] = [:]
        for entry in entries {
            byPID[entry.pid] = entry
            if entry.ppid != entry.pid {
                children[entry.ppid, default: []].append(entry.pid)
            }
        }
        self.entries = byPID
        self.childIndex = children.mapValues { $0.sorted() }
    }

    public subscript(pid: Int32) -> ProcessEntry? { entries[pid] }

    public func children(of pid: Int32) -> [ProcessEntry] {
        (childIndex[pid] ?? []).compactMap { entries[$0] }
    }

    /// Ancestors of `pid`, nearest first. Excludes `pid` itself.
    public func ancestors(of pid: Int32) -> [ProcessEntry] {
        var result: [ProcessEntry] = []
        var seen: Set<Int32> = [pid]
        var current = entries[pid]?.ppid
        while let next = current, next > 0, !seen.contains(next), let entry = entries[next] {
            result.append(entry)
            seen.insert(next)
            current = entry.ppid
        }
        return result
    }

    /// Every descendant of `pid` in breadth-first order. Excludes `pid` itself.
    public func descendants(of pid: Int32) -> [ProcessEntry] {
        var result: [ProcessEntry] = []
        var seen: Set<Int32> = [pid]
        var queue = childIndex[pid] ?? []
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            guard !seen.contains(next), let entry = entries[next] else { continue }
            seen.insert(next)
            result.append(entry)
            queue.append(contentsOf: childIndex[next] ?? [])
        }
        return result
    }
}

/// Everything we know about one process. Fields are empty or nil when the
/// kernel refuses to tell us (another user's process, or root's).
///
/// The environment can also be empty for Apple's own system binaries
/// (`/bin/zsh`, `/usr/bin/ruby`, …): on macOS 26 the system reveals their
/// arguments but not their environment, even to the same user. A macOS 15
/// CI machine did reveal it, so do not rely on either.
public struct ProcessDetails: Sendable, Equatable, Identifiable {
    public let entry: ProcessEntry
    public var executablePath: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var cwd: String?
    public var username: String
    /// 100 means one full core.
    public var cpuPercent: Double
    public var residentBytes: UInt64
    /// False when the process belongs to another user and we could only read
    /// its basic facts.
    public var isInspectable: Bool

    public init(
        entry: ProcessEntry,
        executablePath: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        cwd: String? = nil,
        username: String = "",
        cpuPercent: Double = 0,
        residentBytes: UInt64 = 0,
        isInspectable: Bool = true
    ) {
        self.entry = entry
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.username = username
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.isInspectable = isInspectable
    }

    public var id: ProcessIdentity { entry.identity }
    public var pid: Int32 { entry.pid }
    public var identity: ProcessIdentity { entry.identity }

    /// Basename of the executable, falling back to the kernel's short name.
    public var executableName: String {
        if let path = executablePath, let last = path.split(separator: "/").last {
            return String(last)
        }
        return entry.name
    }
}
