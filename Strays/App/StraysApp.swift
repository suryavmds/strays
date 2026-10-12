import SwiftUI
import StraysCore

enum WindowID {
    static let dashboard = "dashboard"
}

@main
struct StraysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        // `--demo` shows made-up data and never scans or signals anything.
        let arguments = CommandLine.arguments
        let rendersDemoSnapshots = arguments.contains("--render-snapshots") && !arguments.contains("--live")
        let isDemo = arguments.contains("--demo") || rendersDemoSnapshots
        _model = State(initialValue: isDemo ? AppModel(demo: DemoData.snapshot) : AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Strays", id: WindowID.dashboard) {
            DashboardView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 760)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let directory = SnapshotRenderer.requestedDirectory {
            SnapshotRenderer.renderAll(to: directory)
            exit(0)
        }
        #endif
    }
}
