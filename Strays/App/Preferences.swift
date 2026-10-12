import Foundation
import StraysCore

/// Keys and defaults for everything stored in UserDefaults.
enum Preferences {
    enum Key {
        static let staleNotificationsEnabled = "staleNotificationsEnabled"
        static let staleNotificationMode = "staleNotificationMode"
        static let staleAfterHours = "staleAfterHours"
        static let notificationPlanner = "staleNotificationPlanner"
        static let showsHidden = "showsHidden"
        static let packageNamePolicy = "packageNamePolicy"
        static let preferredTerminal = "preferredTerminal"
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

    /// Where package.json may be opened for a project's name. The default
    /// never triggers a macOS privacy prompt.
    static var packageNamePolicy: ProjectResolver.PackageNamePolicy {
        UserDefaults.standard.string(forKey: Key.packageNamePolicy)
            .flatMap(ProjectResolver.PackageNamePolicy.init(rawValue:)) ?? .unprotectedOnly
    }

    static var notificationMode: StaleNotificationPlanner.Mode {
        UserDefaults.standard.string(forKey: Key.staleNotificationMode)
            .flatMap(StaleNotificationPlanner.Mode.init(rawValue:)) ?? .dailySummary
    }
}

extension StackItem {
    /// How the item is named in the UI.
    var title: String {
        switch kind {
        case .command: value
        case .composeProject: "\(value) (compose)"
        case .brewService, .container: value
        }
    }

    var symbol: String {
        switch kind {
        case .command: "terminal"
        case .composeProject: "square.stack.3d.up"
        case .brewService: "mug"
        case .container: "shippingbox"
        }
    }

    var kindLabel: String {
        switch kind {
        case .command: "Command"
        case .composeProject: "Compose project"
        case .brewService: "Brew service"
        case .container: "Container"
        }
    }
}
