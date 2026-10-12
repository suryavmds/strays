import Foundation
import StraysCore

/// Keys and defaults for everything stored in UserDefaults.
enum Preferences {
    enum Key {
        static let staleNotificationsEnabled = "staleNotificationsEnabled"
        static let staleNotificationMode = "staleNotificationMode"
        static let staleAfterHours = "staleAfterHours"
        static let notificationPlanner = "staleNotificationPlanner"
    }

    static let defaultStaleAfterHours = 6.0

    static var staleAfterHours: Double {
        let stored = UserDefaults.standard.double(forKey: Key.staleAfterHours)
        return stored > 0 ? stored : defaultStaleAfterHours
    }

    /// Off until the user turns it on: asking for notification permission
    /// at first launch would be presumptuous.
    static var areStaleNotificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Key.staleNotificationsEnabled)
    }

    static var notificationMode: StaleNotificationPlanner.Mode {
        UserDefaults.standard.string(forKey: Key.staleNotificationMode)
            .flatMap(StaleNotificationPlanner.Mode.init(rawValue:)) ?? .dailySummary
    }
}
