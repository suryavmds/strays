import Foundation

/// Decides which stale notifications to send, and keeps them from becoming
/// a nuisance. Pure and Codable: the app only posts what it is handed and
/// saves the planner between launches.
public struct StaleNotificationPlanner: Sendable, Codable, Equatable {
    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// One notification a day, however many things are stale. The default.
        case dailySummary
        /// One notification for each thing, the first time it goes stale.
        case eachItem
    }

    public struct Notification: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let body: String
        /// The strays this notification is about; its Stop and Snooze act on these.
        public let strayIDs: [String]
    }

    public var mode: Mode
    /// The day the last summary was sent, as `yyyy-MM-dd` in local time.
    public private(set) var lastSummaryDay: String?
    public private(set) var snoozedUntil: [String: Date]
    /// Strays already announced in `eachItem` mode.
    public private(set) var announced: Set<String>

    public init(mode: Mode = .dailySummary) {
        self.mode = mode
        lastSummaryDay = nil
        snoozedUntil = [:]
        announced = []
    }

    /// The notifications to post for the current set of stale strays.
    public mutating func plan(stale: [Stray], now: Date = Date(), calendar: Calendar = .current) -> [Notification] {
        snoozedUntil = snoozedUntil.filter { $0.value > now }
        let staleIDs = Set(stale.map(\.id))
        // Something that stopped being stale may be announced afresh later.
        announced.formIntersection(staleIDs)

        let due = stale.filter { snoozedUntil[$0.id] == nil }
        guard !due.isEmpty else { return [] }

        switch mode {
        case .dailySummary:
            let today = Self.day(of: now, calendar: calendar)
            guard lastSummaryDay != today else { return [] }
            lastSummaryDay = today
            return [Self.summary(of: due, now: now)]
        case .eachItem:
            let fresh = due.filter { !announced.contains($0.id) }
            announced.formUnion(fresh.map(\.id))
            return fresh.map { Self.single($0, now: now) }
        }
    }

    /// Keeps quiet about these strays until `date`.
    public mutating func snooze(_ ids: [String], until date: Date) {
        for id in ids { snoozedUntil[id] = date }
    }

    // MARK: - Wording

    private static func single(_ stray: Stray, now: Date) -> Notification {
        Notification(
            id: "stale:\(stray.id)",
            title: "\(stray.title) looks forgotten",
            body: "\(describe(stray, now: now)) It has done nothing for the last half hour.",
            strayIDs: [stray.id]
        )
    }

    private static func summary(of strays: [Stray], now: Date) -> Notification {
        guard strays.count > 1 else {
            let only = single(strays[0], now: now)
            return Notification(id: "stale:summary", title: only.title, body: only.body, strayIDs: only.strayIDs)
        }
        let names = strays.prefix(3).map(\.title).joined(separator: ", ")
        let more = strays.count > 3 ? ", and \(strays.count - 3) more" : ""
        return Notification(
            id: "stale:summary",
            title: "\(strays.count) things look forgotten",
            body: "\(names)\(more) have been running for hours without doing anything.",
            strayIDs: strays.map(\.id)
        )
    }

    private static func describe(_ stray: Stray, now: Date) -> String {
        let uptime = StraysFormat.uptime(since: stray.startedAt, now: now)
        if let project = stray.project { return "Running in \(project.name) for \(uptime)." }
        return "Running for \(uptime)."
    }

    private static func day(of date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
