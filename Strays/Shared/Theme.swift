import SwiftUI
import StraysCore

/// One accent colour per kind of thing, used consistently everywhere.
enum Theme {
    static let dev = Color(red: 0.25, green: 0.52, blue: 1.0)
    static let docker = Color(red: 0.18, green: 0.75, blue: 0.9)
    static let brew = Color(red: 1.0, green: 0.7, blue: 0.2)
    static let lan = Color(red: 1.0, green: 0.32, blue: 0.3)
    static let neutral = Color.secondary

    static func accent(for category: Stray.Category) -> Color {
        switch category {
        case .dev: dev
        case .docker: docker
        case .brew: brew
        case .app, .system: neutral
        }
    }

    static func accent(for stray: Stray) -> Color {
        accent(for: stray.category)
    }

    /// A process counts as busy, and gets a livelier indicator, above this.
    static let busyCPUThreshold = 3.0

    static let hoverSpring = Animation.spring(response: 0.28, dampingFraction: 0.72)
    static let listSpring = Animation.spring(response: 0.4, dampingFraction: 0.82)
}

extension Stray {
    /// `Node.js · 2h 14m`, plus load figures once they are worth reading.
    func statusLine(now: Date = Date()) -> String {
        var parts: [String] = []
        if let subtitle { parts.append(subtitle) }
        parts.append(StraysFormat.uptime(since: startedAt, now: now))
        if cpuPercent >= 1 { parts.append(StraysFormat.cpu(cpuPercent)) }
        if memoryBytes > 0 { parts.append(StraysFormat.memory(memoryBytes)) }
        return parts.joined(separator: " · ")
    }

    var isBusy: Bool { cpuPercent >= Theme.busyCPUThreshold }
}
