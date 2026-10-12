import Darwin
import Foundation

/// The raw facts gathered in one scan, before they are merged into strays.
public struct ProcessScan: Sendable {
    public var table: ProcessTable
    public var ports: [ListeningPort]
    /// Details for every process that takes part in a stray.
    public var details: [Int32: ProcessDetails]
    /// The processes that count as dev processes, with their runtime.
    public var devProcesses: [Int32: DevClassification]
    /// PIDs that tree-building must not climb past.
    public var boundaries: Set<Int32>
    /// For processes inside an app bundle: the app's main process.
    public var appRoots: [Int32: Int32]

    public init(
        table: ProcessTable,
        ports: [ListeningPort],
        details: [Int32: ProcessDetails],
        devProcesses: [Int32: DevClassification],
        boundaries: Set<Int32> = [],
        appRoots: [Int32: Int32] = [:]
    ) {
        self.table = table
        self.ports = ports
        self.details = details
        self.devProcesses = devProcesses
        self.boundaries = boundaries
        self.appRoots = appRoots
    }
}

/// Merges a `ProcessScan` into the list of strays the UI shows. Pure: the
/// same scan always produces the same list.
public struct StrayBuilder: Sendable {
    private let currentUID: UInt32
    private let projectResolver: ProjectResolver
    /// PIDs that never appear: Strays itself, for one.
    private let excludedPIDs: Set<Int32>

    public init(
        projectResolver: ProjectResolver,
        currentUID: UInt32 = getuid(),
        excludedPIDs: Set<Int32> = []
    ) {
        self.projectResolver = projectResolver
        self.currentUID = currentUID
        self.excludedPIDs = excludedPIDs
    }

    public func build(from scan: ProcessScan) -> [Stray] {
        let portsByPID = Dictionary(grouping: scan.ports, by: \.pid)
        // UDP sockets are everywhere (mDNS, QUIC). They are worth showing on
        // something we already list, but do not make a process interesting.
        let tcpListeners = Set(scan.ports.lazy.filter { $0.transport == .tcp }.map(\.pid))
        let devPIDs = Set(scan.devProcesses.keys)
        let interesting = tcpListeners.union(devPIDs)
            .subtracting(excludedPIDs)
            .filter { scan.table[$0] != nil }

        var roots = ProcessGrouper.roots(
            of: interesting,
            absorbing: devPIDs.subtracting(excludedPIDs),
            boundaries: scan.boundaries.union(excludedPIDs),
            in: scan.table
        )
        // A listener that no dev tree claimed, and that lives in an app
        // bundle, is filed under that app's main process.
        for pid in interesting where roots[pid] == pid && !devPIDs.contains(pid) {
            if let appRoot = scan.appRoots[pid], scan.table[appRoot] != nil, !excludedPIDs.contains(appRoot) {
                roots[pid] = appRoot
            }
        }
        let membersByRoot = Dictionary(grouping: roots.keys.sorted(), by: { roots[$0] ?? $0 })

        return membersByRoot.compactMap { rootPID, members -> Stray? in
            guard let rootEntry = scan.table[rootPID] else { return nil }
            // A dev process owns its whole subtree. An app is its main
            // process plus the helpers that hold its ports; whatever else it
            // spawned is its own business.
            let memberEntries = devPIDs.contains(rootPID)
                ? scan.table.descendants(of: rootPID)
                : members.filter { $0 != rootPID }.compactMap { scan.table[$0] }
            let root = scan.details[rootPID] ?? ProcessDetails(entry: rootEntry, isInspectable: false)
            let descendants = memberEntries.map { scan.details[$0.pid] ?? ProcessDetails(entry: $0, isInspectable: false) }
            let group = ProcessGroup(root: root, descendants: descendants, runtime: scan.devProcesses[rootPID])
            return makeStray(group: group, portsByPID: portsByPID)
        }
        .sorted(by: Self.newestFirst)
    }

    private func makeStray(group: ProcessGroup, portsByPID: [Int32: [ListeningPort]]) -> Stray {
        let root = group.root
        let members = group.members
        let ports = members.flatMap { portsByPID[$0.pid] ?? [] }

        let category: Stray.Category
        if group.runtime != nil {
            category = .dev
        } else if root.entry.uid != currentUID {
            category = .system
        } else {
            category = .app
        }

        let (title, subtitle) = naming(for: group)
        return Stray(
            id: "process:\(root.identity.key)",
            kind: .process(group),
            category: category,
            title: title,
            subtitle: subtitle,
            ports: PortSummary.summarize(ports),
            project: project(for: group),
            origin: .unknown,
            startedAt: root.identity.startDate,
            cpuPercent: members.reduce(0) { $0 + $1.cpuPercent },
            memoryBytes: members.reduce(0) { $0 + $1.residentBytes }
        )
    }

    /// A dev process is named by its command. An app is named by its bundle,
    /// with the helper that actually holds the port as the subtitle.
    private func naming(for group: ProcessGroup) -> (title: String, subtitle: String?) {
        let root = group.root
        if group.runtime == nil, let path = root.executablePath, let app = AppBundle.name(forExecutablePath: path) {
            // Name the helper only when it is the whole item; an app with
            // several listening helpers is simply the app.
            let helper = group.descendants.isEmpty && root.executableName != app ? root.executableName : nil
            return (app, helper)
        }
        let title = CommandSummary.title(
            arguments: root.arguments,
            executableName: root.executableName,
            isInterpreter: group.runtime?.isInterpreter ?? false
        )
        return (title, group.runtime?.runtimeName)
    }

    /// The root's working directory decides the project; if that is not
    /// inside one, the first descendant that is wins.
    private func project(for group: ProcessGroup) -> Project? {
        // Apps and system daemons run from `/` or their bundle; a project
        // only means something for dev processes.
        guard group.runtime != nil else { return nil }
        for member in group.members {
            if let cwd = member.cwd, let project = projectResolver.project(forDirectory: cwd) {
                return project
            }
        }
        return nil
    }

    static func newestFirst(_ lhs: Stray, _ rhs: Stray) -> Bool {
        let left = lhs.startedAt ?? .distantPast
        let right = rhs.startedAt ?? .distantPast
        return left == right ? lhs.id < rhs.id : left > right
    }
}
