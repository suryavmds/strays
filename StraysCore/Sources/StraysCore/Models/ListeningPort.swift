import Foundation

/// One bound socket: a TCP socket in LISTEN state, or a bound UDP socket.
public struct ListeningPort: Hashable, Sendable, Codable {
    public enum Transport: String, Sendable, Codable, Comparable {
        case tcp
        case udp

        public static func < (lhs: Transport, rhs: Transport) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let pid: Int32
    public let port: UInt16
    public let transport: Transport
    /// The bind address. `*` means every interface on both IPv4 and IPv6;
    /// `0.0.0.0` and `::` mean every interface on one family.
    public let address: String

    public init(pid: Int32, port: UInt16, transport: Transport, address: String) {
        self.pid = pid
        self.port = port
        self.transport = transport
        self.address = address
    }

    /// True when other machines on the network can reach this port.
    public var isLANVisible: Bool { !Self.isLoopback(address) }

    public var isWildcard: Bool { Self.wildcardAddresses.contains(address) }

    static let wildcardAddresses: Set<String> = ["*", "0.0.0.0", "::"]

    /// Loopback means 127.0.0.0/8, ::1, or a link-local address scoped to lo0.
    public static func isLoopback(_ address: String) -> Bool {
        var host = address.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasPrefix("::ffff:") {
            host = String(host.dropFirst("::ffff:".count))
        }
        if host == "::1" || host == "localhost" { return true }
        if host.hasSuffix("%lo0") { return true }
        return host.hasPrefix("127.") && host.split(separator: ".").count == 4
    }
}

/// The ports of one item, collapsed for display: one row per port number and
/// transport, however many sockets or addresses back it.
public struct PortSummary: Hashable, Sendable, Identifiable {
    public let port: UInt16
    public let transport: ListeningPort.Transport
    public let addresses: [String]
    public let isLANVisible: Bool
    /// The process that owns the socket (the lowest PID when several share it).
    public let pid: Int32

    public init(port: UInt16, transport: ListeningPort.Transport, addresses: [String], isLANVisible: Bool, pid: Int32) {
        self.port = port
        self.transport = transport
        self.addresses = addresses
        self.isLANVisible = isLANVisible
        self.pid = pid
    }

    public var id: String { "\(transport.rawValue):\(port)" }

    public static func summarize(_ ports: [ListeningPort]) -> [PortSummary] {
        struct Key: Hashable {
            let port: UInt16
            let transport: ListeningPort.Transport
        }
        var groups: [Key: [ListeningPort]] = [:]
        for port in ports {
            groups[Key(port: port.port, transport: port.transport), default: []].append(port)
        }
        return groups
            .map { key, members in
                PortSummary(
                    port: key.port,
                    transport: key.transport,
                    addresses: Array(Set(members.map(\.address))).sorted(),
                    isLANVisible: members.contains(where: \.isLANVisible),
                    pid: members.map(\.pid).min() ?? 0
                )
            }
            .sorted { ($0.transport, $0.port) < ($1.transport, $1.port) }
    }
}
