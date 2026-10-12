import Darwin
import Foundation

/// Everything Strays knows at one moment.
public struct StraysSnapshot: Sendable, Equatable {
    public var strays: [Stray]
    public var capturedAt: Date
    /// How long the scan took, for the performance budget.
    public var scanDuration: TimeInterval

    public init(strays: [Stray] = [], capturedAt: Date = Date(), scanDuration: TimeInterval = 0) {
        self.strays = strays
        self.capturedAt = capturedAt
        self.scanDuration = scanDuration
    }

    public static let empty = StraysSnapshot(strays: [], capturedAt: .distantPast)
}

/// Runs the collectors on an adaptive interval and merges their results.
public actor Monitor {
    /// How often to scan. The UI picks one based on what is on screen.
    public enum Cadence: Sendable, Equatable {
        /// The dashboard or the menu bar popover is visible.
        case active
        /// Only the menu bar icon is visible.
        case background
        /// The Mac is asleep.
        case paused

        public var interval: TimeInterval? {
            switch self {
            case .active: 2
            case .background: 10
            case .paused: nil
            }
        }
    }

    private let processTable = ProcessTableCollector()
    private let ports: PortCollector
    private let inspector = ProcessInspector()
    private let classifier: DevProcessClassifier
    private let builder: StrayBuilder
    private let currentUID = getuid()

    private var cadence: Cadence = .paused
    private var loop: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<StraysSnapshot>.Continuation] = [:]
    public private(set) var latest: StraysSnapshot = .empty

    public init(
        rules: RuntimeRules = .bundled,
        homeDirectory: String = NSHomeDirectory(),
        minimumAge: TimeInterval? = nil,
        includeOtherUsers: Bool = true
    ) {
        let resolver = ProjectResolver(homeDirectory: homeDirectory)
        ports = PortCollector(includeOtherUsers: includeOtherUsers)
        classifier = DevProcessClassifier(
            rules: rules,
            homeDirectory: homeDirectory,
            projectResolver: resolver,
            minimumAge: minimumAge
        )
        builder = StrayBuilder(projectResolver: resolver, excludedPIDs: [getpid()])
    }

    // MARK: - Subscribing

    /// A stream of snapshots, starting with the latest one.
    public func snapshots() -> AsyncStream<StraysSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<StraysSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        if latest != .empty { continuation.yield(latest) }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    // MARK: - Scheduling

    public func setCadence(_ newCadence: Cadence) {
        guard newCadence != cadence else { return }
        cadence = newCadence
        loop?.cancel()
        loop = nil
        guard let interval = newCadence.interval else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        setCadence(.paused)
    }

    // MARK: - Scanning

    @discardableResult
    public func refresh() async -> StraysSnapshot {
        let started = DispatchTime.now().uptimeNanoseconds
        let scan = await scan()
        let strays = builder.build(from: scan)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        let snapshot = StraysSnapshot(strays: strays, capturedAt: Date(), scanDuration: elapsed)
        latest = snapshot
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
        return snapshot
    }

    private func scan() async -> ProcessScan {
        // A collector that fails costs us its data for one cycle, never the scan.
        let table = (try? await processTable.collect()) ?? ProcessTable(entries: [])
        let listening = (try? await ports.collect()) ?? []
        await inspector.prune(keeping: table)

        // Phase 1: which of our own processes run a dev runtime? Path only.
        let ownEntries = table.entries.values.filter { $0.uid == currentUID }
        let paths = await inspector.executablePaths(for: ownEntries)
        let runtimeCandidates = ownEntries.filter {
            classifier.runtime(forExecutablePath: paths[$0.pid], name: $0.name) != nil
        }

        // Phase 2: full details for those, for everything with a port, and
        // for the main process of any app a listener belongs to.
        let listenerPIDs = Set(listening.map(\.pid))
        let appRoots = ProcessGrouper.appRoots(of: listenerPIDs, executablePaths: paths, in: table)
        var wanted = Set(runtimeCandidates.map(\.pid)).union(listenerPIDs).union(appRoots.values)
        var details = await inspector.details(for: wanted.compactMap { table[$0] })

        let now = Date()
        var devProcesses: [Int32: DevClassification] = [:]
        for candidate in runtimeCandidates {
            if let detail = details[candidate.pid], let classification = classifier.classify(detail, now: now) {
                devProcesses[candidate.pid] = classification
            }
        }

        // A dev process owns its subtree, so read the descendants too: their
        // CPU and memory count towards the tree.
        let missing = devProcesses.keys
            .flatMap { table.descendants(of: $0) }
            .filter { !wanted.contains($0.pid) }
        if !missing.isEmpty {
            wanted.formUnion(missing.map(\.pid))
            details.merge(await inspector.details(for: missing)) { current, _ in current }
        }

        return ProcessScan(table: table, ports: listening, details: details, devProcesses: devProcesses, appRoots: appRoots)
    }
}
