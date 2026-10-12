import Darwin
import Foundation

public enum PortScanError: Error, Equatable {
    case processListUnavailable
    case toolFailed(String)
}

// MARK: - libproc (primary)

/// Finds listening sockets by walking every process's file descriptors.
/// No subprocess, a few milliseconds per scan.
struct LibprocPortScanner: Sendable {
    struct Result: Sendable {
        var ports: [ListeningPort]
        /// PIDs whose descriptors we were allowed to read.
        var inspectedPIDs: Set<Int32>
    }

    // ABI constants from <sys/proc_info.h>.
    private static let socketKindInternet: Int32 = 1 // SOCKINFO_IN
    private static let socketKindTCP: Int32 = 2 // SOCKINFO_TCP
    private static let tcpStateListen: Int32 = 1 // TSI_S_LISTEN
    private static let flagIPv4: UInt8 = 0x1 // INI_IPV4
    private static let flagIPv6: UInt8 = 0x2 // INI_IPV6

    func scan() throws -> Result {
        let pids = LibProc.allPIDs()
        guard !pids.isEmpty else { throw PortScanError.processListUnavailable }

        var ports: Set<ListeningPort> = []
        var inspected: Set<Int32> = []
        for pid in pids {
            guard let sockets = LibProc.sockets(for: pid) else { continue }
            inspected.insert(pid)
            for socket in sockets {
                if let port = Self.listeningPort(pid: pid, info: socket.info) {
                    ports.insert(port)
                }
            }
        }
        // We can always read our own descriptors; if not, libproc is broken.
        guard !inspected.isEmpty else { throw PortScanError.processListUnavailable }
        return Result(ports: Array(ports), inspectedPIDs: inspected)
    }

    static func listeningPort(pid: Int32, info: socket_fdinfo) -> ListeningPort? {
        let socket = info.psi
        guard socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else { return nil }

        switch socket.soi_kind {
        case socketKindTCP:
            let tcp = socket.soi_proto.pri_tcp
            guard tcp.tcpsi_state == tcpStateListen else { return nil }
            return makePort(pid: pid, transport: .tcp, internet: tcp.tcpsi_ini)
        case socketKindInternet where socket.soi_protocol == IPPROTO_UDP:
            return makePort(pid: pid, transport: .udp, internet: socket.soi_proto.pri_in)
        default:
            return nil
        }
    }

    private static func makePort(pid: Int32, transport: ListeningPort.Transport, internet: in_sockinfo) -> ListeningPort? {
        // The port sits in the low 16 bits, in network byte order.
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: internet.insi_lport))
        guard port != 0 else { return nil }
        return ListeningPort(pid: pid, port: port, transport: transport, address: address(of: internet))
    }

    private static func address(of internet: in_sockinfo) -> String {
        let isIPv4 = internet.insi_vflag & flagIPv4 != 0
        let isIPv6 = internet.insi_vflag & flagIPv6 != 0

        if isIPv6 {
            var address = internet.insi_laddr.ina_6
            let isUnspecified = withUnsafeBytes(of: address) { $0.allSatisfy { $0 == 0 } }
            if isUnspecified { return isIPv4 ? "*" : "::" }
            return presentation(AF_INET6, &address, length: INET6_ADDRSTRLEN) ?? "::"
        }
        var address = internet.insi_laddr.ina_46.i46a_addr4
        if address.s_addr == 0 { return "0.0.0.0" }
        return presentation(AF_INET, &address, length: INET_ADDRSTRLEN) ?? "0.0.0.0"
    }

    private static func presentation(_ family: Int32, _ address: UnsafeRawPointer, length: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(length))
        guard inet_ntop(family, address, &buffer, socklen_t(length)) != nil else { return nil }
        return LibProc.string(fromCString: buffer)
    }
}

// MARK: - lsof (fallback)

/// Parses `lsof -nP -iTCP -sTCP:LISTEN -F pcnPT`.
///
/// The output is one field per line, each prefixed by a type character:
/// `p` starts a process, `f` starts a file, `P` is the protocol and `n` the
/// `host:port` name.
enum LsofParser {
    static let arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcnPT"]

    static func parse(_ output: String) -> [ListeningPort] {
        var ports: Set<ListeningPort> = []
        var pid: Int32?
        var transport: ListeningPort.Transport = .tcp

        for line in output.split(whereSeparator: \.isNewline) {
            guard let type = line.first else { continue }
            let value = line.dropFirst()
            switch type {
            case "p":
                pid = Int32(value)
                transport = .tcp
            case "f":
                transport = .tcp
            case "P":
                transport = value.uppercased() == "UDP" ? .udp : .tcp
            case "n":
                guard let pid, let (host, port) = splitEndpoint(String(value), separator: ":") else { continue }
                ports.insert(ListeningPort(pid: pid, port: port, transport: transport, address: host))
            default:
                continue
            }
        }
        return Array(ports)
    }
}

// MARK: - netstat (supplement for other users' processes)

/// Parses `netstat -anv -p tcp`. Unlike libproc and lsof, netstat reports
/// the owning PID of every listening socket without privileges, so it is the
/// only way to see root-owned listeners.
enum NetstatParser {
    static let arguments = ["-anv", "-p", "tcp"]

    struct Listener: Hashable, Sendable {
        let port: ListeningPort
        /// Possibly truncated to 16 characters by netstat.
        let processName: String
    }

    // proto  recv-q  send-q  local  foreign  LISTEN  rxbytes  txbytes  rhiwat  shiwat  name:pid
    // The process name may contain spaces, so it is matched lazily up to the last colon.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(tcp4|tcp6|tcp46)\s+\d+\s+\d+\s+(\S+)\s+\S+\s+LISTEN\s+\d+\s+\d+\s+\d+\s+\d+\s+(.+?):(\d+)\s"#
    )

    static func parse(_ output: String) -> [Listener] {
        var listeners: Set<Listener> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.firstMatch(in: text, range: range) else { continue }
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            guard let pid = Int32(group(4)), pid > 0,
                  let (host, port) = splitEndpoint(group(2), separator: ".")
            else { continue }

            let address: String
            if host == "*" {
                switch group(1) {
                case "tcp4": address = "0.0.0.0"
                case "tcp6": address = "::"
                default: address = "*"
                }
            } else {
                address = host
            }
            listeners.insert(Listener(
                port: ListeningPort(pid: pid, port: port, transport: .tcp, address: address),
                processName: group(3).trimmingCharacters(in: .whitespaces)
            ))
        }
        return Array(listeners)
    }
}

/// Splits `host<sep>port` at the last separator: `127.0.0.1:80`, `[::1]:80`,
/// `*:80`, and netstat's `fe80::1%lo0.80`.
private func splitEndpoint(_ endpoint: String, separator: Character) -> (host: String, port: UInt16)? {
    guard let index = endpoint.lastIndex(of: separator),
          let port = UInt16(endpoint[endpoint.index(after: index)...]), port != 0
    else { return nil }
    var host = String(endpoint[..<index])
    if host.hasPrefix("["), host.hasSuffix("]") {
        host = String(host.dropFirst().dropLast())
    }
    return (host.isEmpty ? "*" : host, port)
}
