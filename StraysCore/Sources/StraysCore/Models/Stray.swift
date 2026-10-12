import Foundation

/// Where something came from: which AI agent, terminal, or IDE started it.
public enum Origin: Hashable, Sendable {
    /// Started by an AI coding agent. `orphaned` means the agent session has
    /// exited and left this running.
    case agent(id: String, orphaned: Bool)
    case terminal(name: String)
    case ide(name: String)
    case unknown

    public var agentID: String? {
        if case let .agent(id, _) = self { return id }
        return nil
    }

    public var isOrphaned: Bool {
        if case let .agent(_, orphaned) = self { return orphaned }
        return false
    }
}

/// A process tree shown as one item: `npm run dev`, the shell it spawned, and
/// the server that shell started are one thing to the developer.
public struct ProcessGroup: Sendable, Equatable {
    /// The topmost process of the tree; the one whose command names the item.
    public var root: ProcessDetails
    /// Every other process in the tree, in breadth-first order.
    public var descendants: [ProcessDetails]
    public var runtime: DevClassification?

    public init(root: ProcessDetails, descendants: [ProcessDetails] = [], runtime: DevClassification? = nil) {
        self.root = root
        self.descendants = descendants
        self.runtime = runtime
    }

    public var members: [ProcessDetails] { [root] + descendants }
}

/// One thing running in the background.
public struct Stray: Identifiable, Sendable, Equatable {
    public enum Category: String, Sendable, CaseIterable {
        /// A dev server, watcher, worker, or other developer-started process.
        case dev
        /// An ordinary app that happens to listen on a port.
        case app
        /// Owned by root or another user; limited information.
        case system
        case docker
        case brew
    }

    public enum Kind: Sendable, Equatable {
        case process(ProcessGroup)
    }

    public let id: String
    public var kind: Kind
    public var category: Category
    public var title: String
    /// Secondary line: the helper process of an app, for instance.
    public var subtitle: String?
    public var ports: [PortSummary]
    public var project: Project?
    public var origin: Origin
    public var startedAt: Date?
    /// Summed over the whole process tree. 100 means one full core.
    public var cpuPercent: Double
    public var memoryBytes: UInt64

    public init(
        id: String,
        kind: Kind,
        category: Category,
        title: String,
        subtitle: String? = nil,
        ports: [PortSummary] = [],
        project: Project? = nil,
        origin: Origin = .unknown,
        startedAt: Date? = nil,
        cpuPercent: Double = 0,
        memoryBytes: UInt64 = 0
    ) {
        self.id = id
        self.kind = kind
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.ports = ports
        self.project = project
        self.origin = origin
        self.startedAt = startedAt
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }

    public var processGroup: ProcessGroup? {
        if case let .process(group) = kind { return group }
        return nil
    }

    public var isLANVisible: Bool { ports.contains(where: \.isLANVisible) }

    /// The first TCP port, which is the one worth opening in a browser.
    public var primaryPort: PortSummary? {
        ports.first { $0.transport == .tcp } ?? ports.first
    }
}
