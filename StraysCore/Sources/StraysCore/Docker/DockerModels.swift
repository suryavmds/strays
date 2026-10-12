import Foundation

/// A container as Strays shows it.
public struct DockerContainer: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case running
        case paused
        case restarting
        case exited
        case created
        case dead
        case other(String)

        init(_ raw: String) {
            switch raw.lowercased() {
            case "running": self = .running
            case "paused": self = .paused
            case "restarting": self = .restarting
            case "exited": self = .exited
            case "created": self = .created
            case "dead": self = .dead
            default: self = .other(raw)
            }
        }
    }

    /// A container port published on the host.
    public struct PublishedPort: Sendable, Hashable {
        public let hostIP: String
        public let hostPort: UInt16
        public let containerPort: UInt16
        public let transport: ListeningPort.Transport

        public init(hostIP: String, hostPort: UInt16, containerPort: UInt16, transport: ListeningPort.Transport) {
            self.hostIP = hostIP
            self.hostPort = hostPort
            self.containerPort = containerPort
            self.transport = transport
        }
    }

    public let id: String
    public var name: String
    public var image: String
    public var command: String
    public var state: State
    /// Docker's own summary, such as "Up 2 hours (healthy)".
    public var status: String
    public var createdAt: Date
    public var startedAt: Date?
    public var ports: [PublishedPort]
    public var composeProject: String?
    public var composeService: String?
    /// The folder `docker compose` was run from.
    public var composeWorkingDirectory: String?
    public var cpuPercent: Double?
    public var memoryBytes: UInt64?

    public init(
        id: String,
        name: String,
        image: String,
        command: String = "",
        state: State,
        status: String = "",
        createdAt: Date = .distantPast,
        startedAt: Date? = nil,
        ports: [PublishedPort] = [],
        composeProject: String? = nil,
        composeService: String? = nil,
        composeWorkingDirectory: String? = nil,
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.command = command
        self.state = state
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.ports = ports
        self.composeProject = composeProject
        self.composeService = composeService
        self.composeWorkingDirectory = composeWorkingDirectory
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }

    public var isRunning: Bool { state == .running || state == .restarting || state == .paused }
    public var shortID: String { String(id.prefix(12)) }

    /// Published ports as Strays shows them. Docker publishes on 0.0.0.0 by
    /// default, which makes the port reachable from the network.
    public var portSummaries: [PortSummary] {
        PortSummary.summarize(ports.map {
            ListeningPort(pid: 0, port: $0.hostPort, transport: $0.transport, address: $0.hostIP)
        })
    }
}

/// Everything the Docker collector learned in one pass.
public struct DockerSnapshot: Sendable, Equatable {
    /// False when no Docker socket answers. That is a normal state, not an error.
    public var isAvailable: Bool
    public var socketPath: String?
    public var containers: [DockerContainer]

    public init(isAvailable: Bool, socketPath: String? = nil, containers: [DockerContainer] = []) {
        self.isAvailable = isAvailable
        self.socketPath = socketPath
        self.containers = containers
    }

    public static let unavailable = DockerSnapshot(isAvailable: false)
}

// MARK: - Engine API payloads

struct ContainerSummaryPayload: Decodable {
    struct Port: Decodable {
        let ip: String?
        let privatePort: Int?
        let publicPort: Int?
        let type: String?

        enum CodingKeys: String, CodingKey {
            case ip = "IP"
            case privatePort = "PrivatePort"
            case publicPort = "PublicPort"
            case type = "Type"
        }
    }

    let id: String
    let names: [String]?
    let image: String?
    let command: String?
    let created: Double?
    let state: String?
    let status: String?
    let ports: [Port]?
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case command = "Command"
        case created = "Created"
        case state = "State"
        case status = "Status"
        case ports = "Ports"
        case labels = "Labels"
    }

    var container: DockerContainer {
        let published: [DockerContainer.PublishedPort] = (ports ?? []).compactMap { port in
            guard let host = port.publicPort.flatMap(UInt16.init(exactly:)), host != 0,
                  let inner = port.privatePort.flatMap(UInt16.init(exactly:))
            else { return nil }
            return .init(
                hostIP: port.ip.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0",
                hostPort: host,
                containerPort: inner,
                transport: port.type?.lowercased() == "udp" ? .udp : .tcp
            )
        }
        let rawName = names?.first ?? String(id.prefix(12))
        return DockerContainer(
            id: id,
            name: rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName,
            image: image ?? "",
            command: command ?? "",
            state: .init(state ?? ""),
            status: status ?? "",
            createdAt: created.map(Date.init(timeIntervalSince1970:)) ?? .distantPast,
            // The same port is listed once per address family.
            ports: Array(Set(published)).sorted { ($0.hostPort, $0.hostIP) < ($1.hostPort, $1.hostIP) },
            composeProject: labels?["com.docker.compose.project"],
            composeService: labels?["com.docker.compose.service"],
            composeWorkingDirectory: labels?["com.docker.compose.project.working_dir"]
        )
    }
}

struct ContainerInspectPayload: Decodable {
    struct State: Decodable {
        let startedAt: String?

        enum CodingKeys: String, CodingKey {
            case startedAt = "StartedAt"
        }
    }

    let state: State?

    enum CodingKeys: String, CodingKey {
        case state = "State"
    }

    /// Docker reports nanoseconds ("2026-10-12T01:49:53.803283838Z") and uses
    /// year 1 for "never started".
    var startedAt: Date? {
        guard let raw = state?.startedAt, !raw.hasPrefix("0001-") else { return nil }
        let withoutFraction = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: withoutFraction)
    }
}

/// One raw stats reading. CPU usage is cumulative, so a percentage needs two.
struct ContainerStatsPayload: Decodable, Equatable {
    struct CPUStats: Decodable, Equatable {
        struct Usage: Decodable, Equatable {
            let totalUsage: UInt64?

            enum CodingKeys: String, CodingKey {
                case totalUsage = "total_usage"
            }
        }

        let cpuUsage: Usage?
        let systemCPUUsage: UInt64?
        let onlineCPUs: Int?

        enum CodingKeys: String, CodingKey {
            case cpuUsage = "cpu_usage"
            case systemCPUUsage = "system_cpu_usage"
            case onlineCPUs = "online_cpus"
        }
    }

    struct MemoryStats: Decodable, Equatable {
        let usage: UInt64?
        let stats: [String: UInt64]?
    }

    let cpuStats: CPUStats?
    let memoryStats: MemoryStats?

    enum CodingKeys: String, CodingKey {
        case cpuStats = "cpu_stats"
        case memoryStats = "memory_stats"
    }

    var containerCPUTime: UInt64 { cpuStats?.cpuUsage?.totalUsage ?? 0 }
    var systemCPUTime: UInt64 { cpuStats?.systemCPUUsage ?? 0 }
    var onlineCPUs: Int { max(cpuStats?.onlineCPUs ?? 1, 1) }

    /// Usage minus reclaimable page cache, the figure `docker stats` shows.
    var memoryBytes: UInt64 {
        let usage = memoryStats?.usage ?? 0
        let cache = memoryStats?.stats?["inactive_file"] ?? memoryStats?.stats?["total_inactive_file"] ?? 0
        return usage > cache ? usage - cache : usage
    }

    /// CPU use between two readings. 100 means one full core.
    static func cpuPercent(from previous: ContainerStatsPayload, to current: ContainerStatsPayload) -> Double {
        guard current.containerCPUTime >= previous.containerCPUTime, current.systemCPUTime > previous.systemCPUTime else { return 0 }
        let container = Double(current.containerCPUTime - previous.containerCPUTime)
        let system = Double(current.systemCPUTime - previous.systemCPUTime)
        return container / system * Double(current.onlineCPUs) * 100
    }
}

/// Decodes `docker logs` output.
enum DockerLogDecoder {
    /// Without a TTY, Docker multiplexes stdout and stderr: each frame is an
    /// 8-byte header (stream id, three zero bytes, big-endian length) followed
    /// by that many bytes. With a TTY the stream is raw.
    static func decode(_ data: Data, isMultiplexed: Bool) -> String {
        guard isMultiplexed, let text = demultiplex(data) else {
            return String(decoding: data, as: UTF8.self)
        }
        return text
    }

    static func demultiplex(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var cursor = 0
        while cursor + 8 <= bytes.count {
            guard bytes[cursor] <= 2, bytes[cursor + 1] == 0, bytes[cursor + 2] == 0, bytes[cursor + 3] == 0 else { return nil }
            let length = Int(bytes[cursor + 4]) << 24 | Int(bytes[cursor + 5]) << 16 | Int(bytes[cursor + 6]) << 8 | Int(bytes[cursor + 7])
            let start = cursor + 8
            let end = min(start + length, bytes.count)
            output.append(contentsOf: bytes[start..<end])
            cursor = end
        }
        // Trailing bytes that do not form a header mean this was not a
        // multiplexed stream after all.
        guard cursor == bytes.count else { return nil }
        return String(decoding: output, as: UTF8.self)
    }
}
