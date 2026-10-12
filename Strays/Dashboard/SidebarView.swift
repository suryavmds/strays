import SwiftUI
import StraysCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: DashboardState

    var body: some View {
        List(selection: selection) {
            Section {
                row(.all, "All", symbol: "square.grid.2x2", count: model.activeStrays.count + model.otherListeners.count, tint: Theme.dev)
                row(.ports, "Listening Ports", symbol: "point.3.connected.trianglepath.dotted", count: model.snapshot.strays.filter { !$0.ports.isEmpty }.count, tint: Theme.docker)
            }

            Section("Projects") {
                // Loose containers and services have their own entries below.
                let groups = model.projectGroups.filter { $0.project != nil || $0.id == "loose:dev" }
                if groups.isEmpty {
                    Text("Nothing running")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                ForEach(groups) { group in
                    row(.project(group.id), group.title, symbol: group.symbol.replacingOccurrences(of: ".fill", with: ""), count: group.strays.count, tint: Theme.dev)
                        .help(group.project?.rootPath ?? "Things that are not inside a project folder")
                }
            }

            if !model.detectedAgents.isEmpty {
                Section("Agents") {
                    ForEach(model.detectedAgents) { agent in
                        agentRow(agent)
                    }
                }
            }

            Section("Services") {
                row(.docker, "Docker", symbol: "shippingbox", count: model.containers.filter(\.isRunning).count, tint: Theme.docker)
                    .help(model.snapshot.isDockerAvailable ? "Containers, running and stopped" : "Docker is not running")
                row(.brew, "Brew Services", symbol: "mug", count: model.brewServices.filter(\.isRunning).count, tint: Theme.brew)
                    .help(model.snapshot.isBrewAvailable ? "Homebrew services, started and stopped" : "Homebrew is not installed")
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

    /// One row per agent that is running or has left something behind.
    private func agentRow(_ agent: DetectedAgent) -> some View {
        Label {
            HStack(spacing: 5) {
                Text(agent.profile.displayName)
                    .lineLimit(1)
                Spacer()
                if !agent.orphans.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.brew)
                        .help("\(agent.orphans.count) orphaned: the session that started them has exited")
                }
                Text(verbatim: "\(agent.strays.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        } icon: {
            Image(systemName: agent.profile.icon)
                .foregroundStyle(agent.profile.color)
        }
        .tag(SidebarItem.agent(agent.id))
        .help(agentHelp(agent))
        .accessibilityLabel("\(agent.profile.displayName), \(agent.strays.count) running, \(agent.orphans.count) orphaned")
    }

    private func agentHelp(_ agent: DetectedAgent) -> String {
        let sessions = agent.sessionCount == 1 ? "1 session running" : "\(agent.sessionCount) sessions running"
        return "\(agent.profile.displayName): \(sessions), \(agent.strays.count) background processes"
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
