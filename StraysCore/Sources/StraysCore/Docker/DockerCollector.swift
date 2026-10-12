import Foundation

/// Lists containers through the Docker Engine API, with live stats for the
/// ones the UI is actually showing.
public actor DockerCollector: Collector {
    public nonisolated let name = "docker"

    private let locate: @Sendable () -> String?
    private var client: DockerClient?
    /// Containers to fetch CPU and memory for. Stats cost one request each,
    /// so only visible rows get them.
    private var statsTargets: Set<String> = []
    private var previousStats: [String: ContainerStatsPayload] = [:]
    private var startTimes: [String: (status: String, startedAt: Date?)] = [:]

    public init(locate: @escaping @Sendable () -> String? = { DockerSocketLocator.locate() }) {
        self.locate = locate
    }

    /// The client for the socket that last answered, for actions.
    public var currentClient: DockerClient? { client }

    public func setStatsTargets(_ ids: Set<String>) {
        statsTargets = ids
    }

    /// Never throws for "Docker is not running": that is simply an
    /// unavailable snapshot.
    public func collect() async throws -> DockerSnapshot {
        guard let client = resolveClient() else { return .unavailable }

        var containers: [DockerContainer]
        do {
            containers = try await client.containers(all: true)
        } catch {
            // The socket file can outlive the daemon. Look again next time.
            self.client = nil
            return .unavailable
        }

        await fillStartTimes(&containers, using: client)
        await fillStats(&containers, using: client)

        let alive = Set(containers.map(\.id))
        previousStats = previousStats.filter { alive.contains($0.key) }
        startTimes = startTimes.filter { alive.contains($0.key) }
        return DockerSnapshot(isAvailable: true, socketPath: client.socketPath, containers: containers)
    }

    // MARK: - Private

    private func resolveClient() -> DockerClient? {
        if let client, DockerSocketLocator.isSocket(client.socketPath) { return client }
        client = locate().map(DockerClient.init(socketPath:))
        return client
    }

    /// The list endpoint has no start time, so running containers are
    /// inspected once and again whenever their state changes.
    private func fillStartTimes(_ containers: inout [DockerContainer], using client: DockerClient) async {
        let stale = containers.filter { container in
            container.isRunning && startTimes[container.id]?.status != Self.statusKey(container)
        }
        let fetched = await withTaskGroup(of: (String, Date?).self) { group in
            for container in stale {
                group.addTask { (container.id, try? await client.startedAt(of: container.id)) }
            }
            var result: [String: Date?] = [:]
            for await (id, date) in group { result[id] = date }
            return result
        }
        for container in stale {
            startTimes[container.id] = (Self.statusKey(container), fetched[container.id] ?? nil)
        }
        for index in containers.indices where containers[index].isRunning {
            containers[index].startedAt = startTimes[containers[index].id]?.startedAt
        }
    }

    /// "Up 2 hours" changes every hour, which is often enough to notice a
    /// restart without inspecting on every pass.
    private static func statusKey(_ container: DockerContainer) -> String {
        "\(container.state)|\(container.status)"
    }

    private func fillStats(_ containers: inout [DockerContainer], using client: DockerClient) async {
        let targets = containers.filter { $0.state == .running && statsTargets.contains($0.id) }
        guard !targets.isEmpty else { return }

        let readings = await withTaskGroup(of: (String, ContainerStatsPayload?).self) { group in
            for container in targets {
                group.addTask { (container.id, try? await client.stats(of: container.id)) }
            }
            var result: [String: ContainerStatsPayload] = [:]
            for await (id, reading) in group {
                if let reading { result[id] = reading }
            }
            return result
        }

        for index in containers.indices {
            guard let reading = readings[containers[index].id] else { continue }
            containers[index].memoryBytes = reading.memoryBytes
            if let previous = previousStats[containers[index].id] {
                containers[index].cpuPercent = ContainerStatsPayload.cpuPercent(from: previous, to: reading)
            }
            previousStats[containers[index].id] = reading
        }
    }
}
