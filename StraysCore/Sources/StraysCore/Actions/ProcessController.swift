import Darwin
import Foundation

/// Delivers a signal to a PID. Abstracted so the safety rules can be tested
/// without signalling anything.
public protocol Signalling: Sendable {
    /// Returns 0 on success, or an errno value.
    func send(_ signal: Int32, to pid: Int32) -> Int32
}

public struct SystemSignaller: Signalling {
    public init() {}

    public func send(_ signal: Int32, to pid: Int32) -> Int32 {
        kill(pid, signal) == 0 ? 0 : errno
    }
}

/// The outcome of asking a set of processes to stop.
public struct StopResult: Sendable, Equatable {
    public enum SkipReason: Sendable, Equatable {
        /// Refused by the protected list.
        case protected(String)
        /// The PID now belongs to a different process, or to none. Never signalled.
        case noLongerTheSameProcess
        /// The kernel refused: the process belongs to another user.
        case permissionDenied
    }

    public struct Skipped: Sendable, Equatable {
        public let target: SignalTarget
        public let reason: SkipReason
    }

    /// Signalled, and gone by the end of the grace period.
    public var exited: [SignalTarget] = []
    /// Signalled, but still running. Candidates for Force Kill.
    public var survivors: [SignalTarget] = []
    public var skipped: [Skipped] = []

    public init(exited: [SignalTarget] = [], survivors: [SignalTarget] = [], skipped: [Skipped] = []) {
        self.exited = exited
        self.survivors = survivors
        self.skipped = skipped
    }

    public var allExited: Bool { survivors.isEmpty && !exited.isEmpty }
    public var nothingHappened: Bool { exited.isEmpty && survivors.isEmpty }
}

/// Stops processes, safely.
///
/// Every signal goes through the same three checks, in this order:
/// 1. the protected list (PID 0 and 1, Strays itself, WindowServer, …);
/// 2. the PID must still have the start time we recorded, because PIDs are
///    reused and we must never kill the wrong process;
/// 3. the kernel's own permission check.
public struct ProcessController: Sendable {
    private let signaller: any Signalling
    private let lookup: @Sendable (Int32) -> ProcessEntry?
    private let table: @Sendable () -> ProcessTable
    private let ownPID: Int32
    /// How long to wait after SIGTERM before reporting survivors.
    public let gracePeriod: TimeInterval
    private let pollInterval: TimeInterval

    public init(
        signaller: any Signalling = SystemSignaller(),
        gracePeriod: TimeInterval = 5,
        pollInterval: TimeInterval = 0.1,
        ownPID: Int32 = getpid(),
        lookup: (@Sendable (Int32) -> ProcessEntry?)? = nil,
        table: (@Sendable () -> ProcessTable)? = nil
    ) {
        self.signaller = signaller
        self.gracePeriod = gracePeriod
        self.pollInterval = pollInterval
        self.ownPID = ownPID
        self.lookup = lookup ?? { LibProc.entry(for: $0) }
        self.table = table ?? { ProcessTable(entries: LibProc.allEntries()) }
    }

    // MARK: - Stopping

    /// Sends SIGTERM and waits up to the grace period for the processes to exit.
    public func stop(_ targets: [SignalTarget]) async -> StopResult {
        await signal(targets, with: SIGTERM, waitingFor: gracePeriod)
    }

    /// Sends SIGKILL. Only meant for the survivors of `stop`.
    public func forceKill(_ targets: [SignalTarget]) async -> StopResult {
        await signal(targets, with: SIGKILL, waitingFor: 2)
    }

    /// The root plus everything that should stop with it: its descendants as
    /// of right now, and, when the root leads a process group, the rest of
    /// that group (children that were reparented but never left the group).
    ///
    /// Returns an empty list if the root is no longer the process we recorded.
    public func tree(of root: SignalTarget) -> [SignalTarget] {
        let table = table()
        guard let entry = table[root.pid], entry.identity == root.identity else { return [] }

        var members = table.descendants(of: root.pid)
        if entry.pgid == entry.pid {
            let known = Set(members.map(\.pid)).union([entry.pid])
            members += table.entries.values
                .filter { $0.pgid == entry.pgid && !known.contains($0.pid) }
                .sorted { $0.pid < $1.pid }
        }
        return [root] + members.map {
            SignalTarget(identity: $0.identity, name: $0.name, uid: $0.uid)
        }
    }

    /// True while the PID still belongs to the process we recorded.
    public func isRunning(_ target: SignalTarget) -> Bool {
        lookup(target.pid)?.identity == target.identity
    }

    // MARK: - Private

    private func signal(_ targets: [SignalTarget], with signal: Int32, waitingFor grace: TimeInterval) async -> StopResult {
        var result = StopResult()
        var signalled: [SignalTarget] = []

        for target in targets {
            if let reason = ProtectedProcesses.isProtected(pid: target.pid, name: target.name, ownPID: ownPID) {
                result.skipped.append(.init(target: target, reason: .protected(reason)))
                continue
            }
            // Re-verify immediately before the signal: the PID may have been
            // reused since the snapshot this target came from.
            guard isRunning(target) else {
                result.skipped.append(.init(target: target, reason: .noLongerTheSameProcess))
                continue
            }
            switch signaller.send(signal, to: target.pid) {
            case 0:
                signalled.append(target)
            case ESRCH:
                // It exited between the check and the signal: that is what
                // was asked for.
                result.exited.append(target)
            default:
                result.skipped.append(.init(target: target, reason: .permissionDenied))
            }
        }

        var remaining = signalled
        let deadline = Date().addingTimeInterval(grace)
        while !remaining.isEmpty {
            remaining.removeAll { !isRunning($0) }
            if remaining.isEmpty || Date() >= deadline { break }
            try? await Task.sleep(for: .seconds(pollInterval))
        }

        let survivors = Set(remaining)
        result.exited += signalled.filter { !survivors.contains($0) }
        result.survivors = remaining
        return result
    }
}

extension Stray {
    /// The process a Stop on this stray is aimed at.
    public var signalRoot: SignalTarget? {
        processGroup.map { SignalTarget($0.root) }
    }

    public var stopPolicy: StopPolicy? {
        signalRoot.map { StopPolicy.evaluate($0) }
    }
}

extension PortSummary {
    /// The address to open in a browser.
    public var localURL: URL? {
        let scheme = [443, 8443].contains(port) ? "https" : "http"
        return URL(string: "\(scheme)://localhost:\(port)")
    }
}
