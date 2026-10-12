import SwiftUI

struct MenuBarPopover: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No strays yet")
                .font(.headline)
            Button("Open Dashboard") {
                openWindow(id: WindowID.dashboard)
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit Strays") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 320)
    }
}
