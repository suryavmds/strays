import SwiftUI
import StraysCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: DashboardState

    var body: some View {
        List(selection: selection) {
            Section {
                row(.all, "All", symbol: "square.grid.2x2", count: model.snapshot.strays.count, tint: Theme.dev)
                row(.ports, "Listening Ports", symbol: "point.3.connected.trianglepath.dotted", count: model.snapshot.strays.filter { !$0.ports.isEmpty }.count, tint: Theme.docker)
            }

            Section("Projects") {
                if model.projectGroups.isEmpty {
                    Text("Nothing running")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                ForEach(model.projectGroups) { group in
                    row(.project(group.id), group.title, symbol: group.project == nil ? "questionmark.folder" : "folder", count: group.strays.count, tint: Theme.dev)
                        .help(group.project?.rootPath ?? "Dev processes that are not inside a project folder")
                }
            }

            Section("Everything else") {
                row(.others, "Apps & System", symbol: "macwindow.on.rectangle", count: model.otherListeners.count, tint: .secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    /// `List` wants an optional selection; the sidebar always has one.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { state.sidebar },
            set: { if let item = $0 { state.sidebar = item } }
        )
    }

    private func row(_ item: SidebarItem, _ title: String, symbol: String, count: Int, tint: Color) -> some View {
        Label {
            HStack {
                Text(title)
                    .lineLimit(1)
                Spacer()
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .tag(item)
        .accessibilityLabel("\(title), \(count)")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isDemo ? Theme.brew : .green)
                .frame(width: 6, height: 6)
            Text(model.isDemo ? "Demo data" : "Live · scan \(Int(model.snapshot.scanDuration * 1_000)) ms")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
