import ServiceManagement

/// Launch at login, through the system's own mechanism. macOS lists it under
/// System Settings > General > Login Items, where it can also be turned off.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Throws when macOS refuses, which it does for an app that is not in
    /// the Applications folder or is not properly signed.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
