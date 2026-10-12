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
}
