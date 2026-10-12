import Foundation

/// Finds every listening port on the machine.
///
/// 1. libproc walks our own user's processes on every call (fast, no fork).
/// 2. If libproc fails outright, `lsof` is the fallback.
/// 3. `netstat` runs on a slower cadence to add listeners owned by root or
///    other users, which neither libproc nor lsof can see without privileges.
public actor PortCollector: Collector {
    public nonisolated let name = "ports"

    private let scanner = LibprocPortScanner()
    private let supplementInterval: TimeInterval
    private let includeOtherUsers: Bool
    private var supplement: [ListeningPort] = []
    private var supplementDate: Date = .distantPast

    /// What the last scan used, for diagnostics.
    public private(set) var lastSource: Source = .libproc

    public enum Source: String, Sendable {
        case libproc
        case lsof
    }

    public init(includeOtherUsers: Bool = true, supplementInterval: TimeInterval = 15) {
        self.includeOtherUsers = includeOtherUsers
        self.supplementInterval = supplementInterval
    }

    public func collect() async throws -> [ListeningPort] {
        var ports: [ListeningPort]
        var inspected: Set<Int32>

        do {
            let result = try scanner.scan()
            ports = result.ports
            inspected = result.inspectedPIDs
            lastSource = .libproc
        } catch {
            ports = try await Self.scanWithLsof()
            inspected = Set(ports.map(\.pid))
            lastSource = .lsof
        }

        if includeOtherUsers {
            await refreshSupplementIfNeeded()
            ports += supplement.filter { !inspected.contains($0.pid) }
        }
        return ports
    }

    private func refreshSupplementIfNeeded() async {
        guard Date().timeIntervalSince(supplementDate) >= supplementInterval else { return }
        supplementDate = Date()
        // Best effort: a missing or failing netstat only costs us root's ports.
        guard let result = try? await Subprocess.run("/usr/sbin/netstat", NetstatParser.arguments, timeout: 5),
              result.succeeded
        else { return }
        supplement = NetstatParser.parse(result.stdoutText).map(\.port)
    }

    static func scanWithLsof() async throws -> [ListeningPort] {
        let result = try await Subprocess.run("/usr/sbin/lsof", LsofParser.arguments, timeout: 10)
        // lsof exits 1 when nothing matched, which is a valid empty answer.
        guard result.succeeded || result.stdout.isEmpty else {
            throw PortScanError.toolFailed(result.stderrText)
        }
        return LsofParser.parse(result.stdoutText)
    }
}
