import Foundation

/// One independent source of truth about the machine. Each collector returns
/// a typed snapshot; the `Monitor` merges them.
public protocol Collector<Snapshot>: Sendable {
    associatedtype Snapshot: Sendable

    /// Short name for logs and diagnostics.
    var name: String { get }

    func collect() async throws -> Snapshot
}

/// Lists every process on the machine with its cheap, always-readable facts.
public struct ProcessTableCollector: Collector {
    public let name = "processes"

    public init() {}

    public func collect() async throws -> ProcessTable {
        ProcessTable(entries: LibProc.allEntries())
    }
}
