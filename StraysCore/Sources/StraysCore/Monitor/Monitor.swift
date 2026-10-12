import Darwin
import Foundation

/// Everything Strays knows at one moment.
public struct StraysSnapshot: Sendable, Equatable {
    public var strays: [Stray]
    public var capturedAt: Date
    /// How long the scan took, for the performance budget.
    public var scanDuration: TimeInterval
    /// False when no Docker daemon answered. Not an error.
    public var isDockerAvailable: Bool
    /// False when Homebrew is not installed.
    public var isBrewAvailable: Bool

    public init(
        strays: [Stray] = [],
        capturedAt: Date = Date(),
        scanDuration: TimeInterval = 0,
        isDockerAvailable: Bool = false,
        isBrewAvailable: Bool = false
    ) {
        self.strays = strays
        self.capturedAt = capturedAt
        self.scanDuration = scanDuration
        self.isDockerAvailable = isDockerAvailable
        self.isBrewAvailable = isBrewAvailable
    }

    public static let empty = StraysSnapshot(strays: [], capturedAt: .distantPast)
}

public enum ContainerAction: Sendable, Equatable {
    case start
    case stop
    case restart
    /// `force` also removes a container that is still running.
    case remove(force: Bool)
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

        /// `brew` is slow, so its list is allowed to be this old.
        var brewMaxAge: TimeInterval {
            self == .active ? 30 : 300
        }
    }

    /// Which optional sources to consult. Tests turn them off.
    public struct Sources: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let docker = Sources(rawValue: 1 << 0)
        public static let brew = Sources(rawValue: 1 << 1)
        /// Listeners owned by root and other users, via netstat.
        public static let otherUsers = Sources(rawValue: 1 << 2)
        public static let all: Sources = [.docker, .brew, .otherUsers]
    }

    private let processTable = ProcessTableCollector()
    private let ports: PortCollector
    private let inspector = ProcessInspector()
    private let classifier: DevProcessClassifier
    private let builder: StrayBuilder
    private let merger: StrayMerger
    private let docker: DockerCollector?
    private let brew: BrewCollector?
    private let currentUID = getuid()

    private var cadence: Cadence = .paused
    private var loop: Task<Void, Never>?
    private var brewRefresh: Task<Void, Never>?
    private var lastBrew: BrewSnapshot?
    private var lastBrewDate: Date = .distantPast
    private var subscribers: [UUID: AsyncStream<StraysSnapshot>.Continuation] = [:]
    public private(set) var latest: StraysSnapshot = .empty

    public init(
        rules: RuntimeRules = .bundled,
        homeDirectory: String = NSHomeDirectory(),
        minimumAge: TimeInterval? = nil,
        sources: Sources = .all,
        dockerCollector: DockerCollector? = nil,
        brewCollector: BrewCollector? = nil
    ) {
        let resolver = ProjectResolver(homeDirectory: homeDirectory)
        ports = PortCollector(includeOtherUsers: sources.contains(.otherUsers))
        classifier = DevProcessClassifier(
            rules: rules,
            homeDirectory: homeDirectory,
            projectResolver: resolver,
            minimumAge: minimumAge
        )
        builder = StrayBuilder(projectResolver: resolver, excludedPIDs: [getpid()])
        merger = StrayMerger(projectResolver: resolver)
        docker = sources.contains(.docker) ? (dockerCollector ?? DockerCollector()) : nil
        brew = sources.contains(.brew) ? (brewCollector ?? BrewCollector()) : nil
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

        let brewSnapshot = await currentBrewSnapshot()
        let dockerSnapshot = await currentDockerSnapshot()
        let scan = await scan(serviceRoots: Set(brewSnapshot.services.compactMap(\.pid)))
        let strays = merger.merge(processes: builder.build(from: scan), docker: dockerSnapshot, brew: brewSnapshot)

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        let snapshot = StraysSnapshot(
            strays: strays,
            capturedAt: Date(),
            scanDuration: elapsed,
            isDockerAvailable: dockerSnapshot.isAvailable,
            isBrewAvailable: brewSnapshot.isAvailable
        )
        latest = snapshot
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
        return snapshot
    }

    private func currentDockerSnapshot() async -> DockerSnapshot {
        guard let docker else { return .unavailable }
        return (try? await docker.collect()) ?? .unavailable
    }

    /// The first list is fetched inline. After that a stale list is served
    /// as it is while a fresh one is fetched in the background, so brew's
    /// half second never holds up a scan.
    private func currentBrewSnapshot() async -> BrewSnapshot {
        guard let brew else { return .unavailable }
        guard let cached = lastBrew else {
            let fresh = (try? await brew.collect(maxAge: 0)) ?? .unavailable
            lastBrew = fresh
            lastBrewDate = Date()
            return fresh
        }
        if Date().timeIntervalSince(lastBrewDate) >= cadence.brewMaxAge, brewRefresh == nil {
            brewRefresh = Task { [weak self] in
                let fresh = try? await brew.collect(maxAge: 0)
                await self?.finishBrewRefresh(fresh)
            }
        }
        return cached
    }

    private func finishBrewRefresh(_ fresh: BrewSnapshot?) {
        brewRefresh = nil
        lastBrewDate = Date()
        if let fresh { lastBrew = fresh }
    }

    private func scan(serviceRoots: Set<Int32>) async -> ProcessScan {
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

        // Phase 2: full details for those, for everything with a port, for
        // the main process of any app a listener belongs to, and for the
        // main process of each Homebrew service.
        let listenerPIDs = Set(listening.map(\.pid))
        let appRoots = ProcessGrouper.appRoots(of: listenerPIDs, executablePaths: paths, in: table)
        let services = serviceRoots.filter { table[$0] != nil }
        var wanted = Set(runtimeCandidates.map(\.pid)).union(listenerPIDs).union(appRoots.values).union(services)
        var details = await inspector.details(for: wanted.compactMap { table[$0] })

        let now = Date()
        var devProcesses: [Int32: DevClassification] = [:]
        for candidate in runtimeCandidates where !services.contains(candidate.pid) {
            if let detail = details[candidate.pid], let classification = classifier.classify(detail, now: now) {
                devProcesses[candidate.pid] = classification
            }
        }

        // A dev process or a service owns its subtree, so read the
        // descendants too: their CPU and memory count towards the tree.
        let missing = Set(devProcesses.keys).union(services)
            .flatMap { table.descendants(of: $0) }
            .filter { !wanted.contains($0.pid) }
        if !missing.isEmpty {
            wanted.formUnion(missing.map(\.pid))
            details.merge(await inspector.details(for: missing)) { current, _ in current }
        }

        return ProcessScan(
            table: table,
            ports: listening,
            details: details,
            devProcesses: devProcesses,
            appRoots: appRoots,
            subtreeOwners: services
        )
    }

    // MARK: - Docker and Homebrew actions

    /// Limits per-container stats requests to the rows the UI is showing.
    public func setVisibleContainers(_ ids: Set<String>) async {
        await docker?.setStatsTargets(ids)
    }

    public func perform(_ action: ContainerAction, onContainer id: String) async throws {
        guard let client = await docker?.currentClient else { throw DockerError.unavailable }
        switch action {
        case .start: try await client.start(id)
        case .stop: try await client.stop(id)
        case .restart: try await client.restart(id)
        case let .remove(force): try await client.remove(id, force: force)
        }
        await refresh()
    }

    /// Stops every running container of a compose project.
    public func stopComposeProject(_ name: String) async throws {
        guard let client = await docker?.currentClient else { throw DockerError.unavailable }
        let targets = latest.strays.compactMap(\.container).filter { $0.composeProject == name && $0.isRunning }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for container in targets {
                group.addTask { try await client.stop(container.id) }
            }
            try await group.waitForAll()
        }
        await refresh()
    }

    public func containerLogs(id: String, tail: Int = 200) async throws -> String {
        guard let client = await docker?.currentClient else { throw DockerError.unavailable }
        return try await client.logs(of: id, tail: tail)
    }

    public func perform(_ action: BrewAction, onService name: String) async throws {
        guard let brew else { throw BrewError.notInstalled }
        defer { lastBrewDate = .distantPast }
        try await brew.perform(action, on: name)
        lastBrew = try? await brew.collect(maxAge: 0)
        lastBrewDate = Date()
        await refresh()
    }
}
