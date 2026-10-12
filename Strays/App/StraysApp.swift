import SwiftUI
import StraysCore

enum WindowID {
    static let dashboard = "dashboard"
}

@main
struct StraysApp: App {
    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
        } label: {
            Image(systemName: "pawprint.fill")
                .accessibilityLabel("Strays")
        }
        .menuBarExtraStyle(.window)

        Window("Strays", id: WindowID.dashboard) {
            DashboardView()
        }
        .defaultSize(width: 1080, height: 700)
    }
}
