import Foundation

/// A short rolling record of CPU and memory per stray, for sparklines.
public struct MetricsHistory: Sendable, Equatable {
    public struct Sample: Sendable, Equatable, Identifiable {
        public let date: Date
        public let cpuPercent: Double
        public let memoryBytes: UInt64

        public init(date: Date, cpuPercent: Double, memoryBytes: UInt64) {
            self.date = date
            self.cpuPercent = cpuPercent
            self.memoryBytes = memoryBytes
        }

        public var id: Date { date }
    }

    public let capacity: Int
    private var storage: [String: [Sample]] = [:]

    public init(capacity: Int = 90) {
        self.capacity = max(1, capacity)
    }

    /// Adds one sample for every stray in the snapshot and forgets strays
    /// that are no longer running.
    public mutating func record(_ snapshot: StraysSnapshot) {
        var next: [String: [Sample]] = [:]
        next.reserveCapacity(snapshot.strays.count)
        for stray in snapshot.strays {
            var samples = storage[stray.id] ?? []
            samples.append(Sample(date: snapshot.capturedAt, cpuPercent: stray.cpuPercent, memoryBytes: stray.memoryBytes))
            if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
            next[stray.id] = samples
        }
        storage = next
    }

    public func samples(for id: String) -> [Sample] {
        storage[id] ?? []
    }

    public var trackedCount: Int { storage.count }
}
