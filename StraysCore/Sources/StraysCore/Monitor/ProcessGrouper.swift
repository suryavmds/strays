import Foundation

/// Folds interesting processes into trees, so a dev server started by
/// `npm run dev` shows up once rather than as npm, a shell, and node.
public enum ProcessGrouper {
    /// Maps every interesting PID to the root of the tree it belongs to.
    ///
    /// The root is the topmost ancestor that is allowed to absorb its
    /// descendants (a dev process). Whatever sits in between — a shell, `make`,
    /// a process manager — is part of the same tree. Climbing stops at a
    /// boundary, such as an AI agent's own process: what an agent started is
    /// never folded into the agent.
    ///
    /// - Parameters:
    ///   - interesting: every PID that should appear somewhere.
    ///   - absorbing: the subset that may act as the root of a tree.
    ///   - boundaries: PIDs that the climb must not cross.
    public static func roots(
        of interesting: Set<Int32>,
        absorbing: Set<Int32>,
        boundaries: Set<Int32> = [],
        in table: ProcessTable
    ) -> [Int32: Int32] {
        var result: [Int32: Int32] = [:]
        result.reserveCapacity(interesting.count)
        for pid in interesting {
            var root = pid
            for ancestor in table.ancestors(of: pid) {
                if boundaries.contains(ancestor.pid) { break }
                if absorbing.contains(ancestor.pid) { root = ancestor.pid }
            }
            result[pid] = root
        }
        return result
    }

    /// Maps each PID to the main process of the app it belongs to: the
    /// topmost ancestor whose executable lives in the same `.app` bundle.
    ///
    /// An app is one thing to its user, however many helper processes hold
    /// its ports: three "Code Helper" listeners are just Visual Studio Code.
    /// PIDs that are not inside a bundle are left out.
    public static func appRoots(
        of pids: some Sequence<Int32>,
        executablePaths: [Int32: String],
        in table: ProcessTable
    ) -> [Int32: Int32] {
        var result: [Int32: Int32] = [:]
        for pid in pids {
            guard let path = executablePaths[pid], let bundle = AppBundle.path(forExecutablePath: path) else { continue }
            var root = pid
            for ancestor in table.ancestors(of: pid) {
                guard let ancestorPath = executablePaths[ancestor.pid],
                      AppBundle.path(forExecutablePath: ancestorPath) == bundle
                else { break }
                root = ancestor.pid
            }
            result[pid] = root
        }
        return result
    }
}
