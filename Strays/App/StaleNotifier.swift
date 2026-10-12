import AppKit
import StraysCore
import UserNotifications

/// Posts the notifications that `StaleNotificationPlanner` asks for, and
/// carries out their Stop and Snooze actions.
@MainActor
final class StaleNotifier: NSObject, UNUserNotificationCenterDelegate {
    // Plain constants, readable from the delegate callbacks, which macOS
    // does not deliver on the main actor.
    private nonisolated static let category = "STALE"
    private nonisolated static let stopAction = "STOP"
    private nonisolated static let snoozeAction = "SNOOZE"
    private nonisolated static let idsKey = "strayIDs"
    private nonisolated static let snoozeDuration: TimeInterval = 24 * 3_600

    /// Stops the strays with these ids. Supplied by the app model, which
    /// applies the same safety policy as a click on Stop.
    var stop: ([String]) -> Void = { _ in }
    /// Opens the dashboard on the Stale filter.
    var review: () -> Void = {}

    private var planner: StaleNotificationPlanner
    private let center = UNUserNotificationCenter.current()

    override init() {
        let stored = UserDefaults.standard.data(forKey: Preferences.Key.notificationPlanner)
        planner = stored.flatMap { try? JSONDecoder().decode(StaleNotificationPlanner.self, from: $0) } ?? StaleNotificationPlanner()
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.stopAction, title: "Stop", options: [.destructive]),
                    UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze for a Day", options: []),
                ],
                intentIdentifiers: []
            ),
        ])
    }

    /// Asks for permission. Called when the user turns notifications on.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Called with the stale strays after every scan.
    func update(stale: [Stray]) {
        guard Preferences.areStaleNotificationsEnabled else { return }
        planner.mode = Preferences.notificationMode
        let before = planner
        let notifications = planner.plan(stale: stale)
        if planner != before { save() }
        for notification in notifications {
            post(notification)
        }
    }

    private func post(_ notification: StaleNotificationPlanner.Notification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.idsKey: notification.strayIDs]
        content.sound = nil
        center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(planner), forKey: Preferences.Key.notificationPlanner)
    }

    private func handle(action: String, ids: [String]) {
        switch action {
        case Self.stopAction:
            stop(ids)
        case Self.snoozeAction:
            planner.snooze(ids, until: Date().addingTimeInterval(Self.snoozeDuration))
            save()
        default:
            review()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let ids = response.notification.request.content.userInfo[Self.idsKey] as? [String] ?? []
        await MainActor.run { self.handle(action: action, ids: ids) }
    }

    /// Strays is a menu bar app and usually "frontmost" in no useful sense;
    /// show the banner regardless.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
