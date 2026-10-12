import Foundation

/// Spots dev processes that have probably been forgotten: running for
/// hours, and doing nothing for the last half hour.
public struct StaleTracker: Sendable {
    /// How long something must have been running before it can be stale.
    public var staleAfter: TimeInterval
    /// How long it must have been idle, as observed by us.
    public var idleWindow: TimeInterval
    /// CPU, in percent of one core, at or above which a process is busy.
    public var busyThreshold: Double

    private var firstSeen: [String: Date] = [:]
    private var lastBusy: [String: Date] = [:]

    public init(staleAfter: TimeInterval = 6 * 3_600, idleWindow: TimeInterval = 30 * 60, busyThreshold: Double = 1) {
        self.staleAfter = staleAfter
        self.idleWindow = idleWindow
        self.busyThreshold = busyThreshold
    }

    /// Records this scan and returns the ids that are stale as of `now`.
    ///
    /// Idleness is only ever claimed for time we watched: a process that
    /// Strays first saw ten minutes ago is not stale yet, however old it is.
    /// Containers and Homebrew services are meant to sit idle and are never
    /// stale.
    public mutating func update(with strays: [Stray], now: Date = Date()) -> Set<String> {
        var stale: Set<String> = []
        var seen: Set<String> = []

        for stray in strays where stray.category == .dev && stray.isRunning {
            seen.insert(stray.id)
            if firstSeen[stray.id] == nil { firstSeen[stray.id] = now }
            if stray.cpuPercent >= busyThreshold { lastBusy[stray.id] = now }

            guard let started = stray.startedAt, now.timeIntervalSince(started) >= staleAfter else { continue }
            let quietSince = max(lastBusy[stray.id] ?? .distantPast, firstSeen[stray.id] ?? now)
            if now.timeIntervalSince(quietSince) >= idleWindow { stale.insert(stray.id) }
        }

        firstSeen = firstSeen.filter { seen.contains($0.key) }
        lastBusy = lastBusy.filter { seen.contains($0.key) }
        return stale
    }
}
