import SwiftUI
import StraysCore

/// The dense view: one sortable row per stray.
struct StrayTableView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: DashboardState
    let strays: [Stray]

    @State private var sortOrder = [KeyPathComparator(\Stray.startDate, order: .reverse)]

    private var sorted: [Stray] { strays.sorted(using: sortOrder) }

    var body: some View {
        // Captured here because table cells cannot read the environment.
        let catalog = model.catalog
        Table(sorted, selection: selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.title) { stray in
                HStack(spacing: 8) {
                    StatusDot(color: Theme.accent(for: stray), isBusy: stray.isBusy)
                    Text(stray.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(stray.isRunning ? .primary : .secondary)
                        .help(stray.subtitle.map { "\(stray.title) · \($0)" } ?? stray.title)
                }
            }
            .width(min: 140, ideal: 210)

            TableColumn("Project", value: \.projectName) { stray in
                Text(stray.project?.name ?? "–")
                    .foregroundStyle(stray.project == nil ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 88)

            TableColumn("Origin", value: \.originSortKey) { stray in
                AdaptiveOriginBadges(stray: stray, catalog: catalog)
            }
            .width(min: 70, ideal: 128)

            TableColumn("Ports", value: \.firstPortNumber) { stray in
                PortChips(ports: stray.ports, limit: 2, tint: Theme.accent(for: stray) == Theme.neutral ? .secondary : Theme.accent(for: stray))
            }
            .width(min: 76, ideal: 132)

            TableColumn("CPU", value: \.cpuPercent) { stray in
                Text(StraysFormat.cpu(stray.cpuPercent))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(stray.isBusy ? .primary : .secondary)
                    .contentTransition(.numericText())
            }
            .width(min: 40, ideal: 46)

            TableColumn("Memory", value: \.memoryMegabytes) { stray in
                Text(StraysFormat.memory(stray.memoryBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .width(min: 52, ideal: 62)

            TableColumn("Uptime", value: \.startDate) { stray in
                Text(stray.isRunning ? StraysFormat.uptime(since: stray.startedAt) : "stopped")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(stray.isRunning ? .secondary : .tertiary)
            }
            .width(min: 58, ideal: 68)

            TableColumn("PID", value: \.rootPID) { stray in
                Text(verbatim: stray.rootPID == 0 ? "–" : "\(stray.rootPID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .width(min: 44, ideal: 54)
        }
        .contextMenu(forSelectionType: Stray.ID.self) { ids in
            if let stray = strays.first(where: { ids.contains($0.id) }) {
                StrayContextMenu(stray: stray)
            }
        } primaryAction: { ids in
            if let stray = strays.first(where: { ids.contains($0.id) }), let port = stray.primaryPort {
                model.open(port)
            }
        }
        .scrollContentBackground(.hidden)
        // A table has no per-row appearance callback, so everything it
        // lists is treated as visible.
        .onAppear { strays.forEach { model.setVisible(true, $0) } }
        .onChange(of: strays.map(\.id)) { strays.forEach { model.setVisible(true, $0) } }
        .onDisappear { strays.forEach { model.setVisible(false, $0) } }
    }

    /// Selecting a row also opens the inspector.
    private var selection: Binding<Stray.ID?> {
        Binding(
            get: { state.selection },
            set: { newValue in
                state.selection = newValue
                if newValue != nil { state.isInspectorOpen = true }
            }
        )
    }
}
