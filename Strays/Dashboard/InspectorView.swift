import SwiftUI
import StraysCore

/// Everything about the selected stray: actions, live load, ports, the full
/// command, the environment (secrets masked), and the process tree.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: DashboardState

    private var stray: Stray? {
        guard let id = state.selection else { return nil }
        return model.snapshot.strays.first { $0.id == id }
    }

    var body: some View {
        if let stray {
            ScrollView {
                InspectorContent(stray: stray)
                    .padding(16)
            }
            .id(stray.id)
        } else {
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "sidebar.trailing",
                description: Text("Pick something to see its command, ports, environment, and process tree.")
            )
        }
    }
}

private struct InspectorContent: View {
    let stray: Stray
    @Environment(AppModel.self) private var model
    @State private var revealsSecrets = false
    @State private var showsEnvironment = false

    private var accent: Color {
        let accent = Theme.accent(for: stray)
        return accent == Theme.neutral ? .secondary : accent
    }

    private var root: ProcessDetails? { stray.processGroup?.root }
    private var samples: [MetricsHistory.Sample] { model.history.samples(for: stray.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            actions
            ActivityPrompt(stray: stray)
            charts
            if !stray.ports.isEmpty { portsSection }
            if let root { detailsSection(root) }
            if let root, !root.arguments.isEmpty { commandSection(root) }
            if let root { environmentSection(root) }
            if let group = stray.processGroup, group.members.count > 1 { treeSection(group) }
        }
        .animation(Theme.hoverSpring, value: model.activity(for: stray))
    }

    // MARK: - Header and actions

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: stray.symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
                .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(stray.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 5) {
                    Badge(text: stray.categoryLabel, color: accent)
                    if let subtitle = stray.subtitle { Badge(text: subtitle, color: .secondary) }
                    if stray.isLANVisible { Badge(text: "On your network", color: Theme.lan, symbol: "wifi.exclamationmark") }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let port = stray.primaryPort, port.transport == .tcp {
                ActionButton(title: "Open", symbol: "safari", tint: accent) { model.open(port) }
                ActionButton(title: "Copy URL", symbol: "doc.on.doc") { model.copyURL(of: port) }
            }
            if stray.canBeStopped {
                ActionButton(title: isStopping ? "Stopping…" : "Stop", symbol: "stop.fill", tint: Theme.lan) {
                    model.requestStop(stray)
                }
                .disabled(isStopping)
            }
            Menu {
                StrayContextMenu(stray: stray)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
    }

    private var isStopping: Bool {
        let activity = model.activity(for: stray)
        return activity == .stopping || activity == .killing
    }

    // MARK: - Sections

    private var charts: some View {
        HStack(spacing: 10) {
            MetricChart(title: "CPU", value: StraysFormat.cpu(stray.cpuPercent), samples: samples, color: accent) { $0.cpuPercent }
            MetricChart(title: "Memory", value: StraysFormat.memory(stray.memoryBytes), samples: samples, color: Theme.docker, includesZero: false) { Double($0.memoryBytes) / 1_048_576 }
        }
    }

    private var portsSection: some View {
        InspectorSection(title: "Ports", symbol: "point.3.connected.trianglepath.dotted") {
            ForEach(stray.ports) { port in
                HStack(spacing: 8) {
                    PortChip(port: port, tint: accent)
                    Text(port.addresses.joined(separator: ", "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(port.isLANVisible ? "Reachable from your network" : "This Mac only")
                        .font(.system(size: 10.5))
                        .foregroundStyle(port.isLANVisible ? AnyShapeStyle(Theme.lan) : AnyShapeStyle(.tertiary))
                }
            }
        }
    }

    private func detailsSection(_ root: ProcessDetails) -> some View {
        InspectorSection(title: "Process", symbol: "cpu") {
            DetailRow(label: "PID", value: String(root.pid))
            DetailRow(label: "Parent", value: String(root.entry.ppid))
            DetailRow(label: "User", value: root.username)
            DetailRow(label: "Started", value: started(root))
            if let project = stray.project {
                DetailRow(label: "Project", value: project.name) { model.reveal(project) }
            }
            if let cwd = root.cwd {
                DetailRow(label: "Directory", value: (cwd as NSString).abbreviatingWithTildeInPath) { model.reveal(path: cwd) }
            }
            if let path = root.executablePath {
                DetailRow(label: "Executable", value: (path as NSString).abbreviatingWithTildeInPath)
            }
            if !root.isInspectable {
                Text("This process belongs to another user, so macOS only reveals the basics.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func started(_ root: ProcessDetails) -> String {
        let date = root.identity.startDate
        // Today needs no date; anything older needs no year.
        let when = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "\(when) · \(StraysFormat.uptime(since: date)) ago"
    }

    private func commandSection(_ root: ProcessDetails) -> some View {
        let command = SecretMasker.maskArguments(root.arguments).joined(separator: " ")
        return InspectorSection(title: "Command", symbol: "terminal") {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } accessory: {
            SectionButton(symbol: "doc.on.doc", label: "Copy command") { model.copy(command, label: "command") }
        }
    }

    private func environmentSection(_ root: ProcessDetails) -> some View {
        let variables = root.environment.sorted { $0.key < $1.key }
        let hidden = variables.filter { SecretMasker.hidesSomething(name: $0.key, value: $0.value) }.count

        return InspectorSection(title: "Environment", symbol: "list.bullet.rectangle", count: variables.count) {
            if variables.isEmpty {
                Text(root.isInspectable
                    ? "macOS does not reveal the environment of its own system binaries."
                    : "Not available for another user's process.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else if showsEnvironment {
                ForEach(variables, id: \.key) { name, value in
                    EnvironmentRow(name: name, value: revealsSecrets ? value : SecretMasker.display(name: name, value: value), isMasked: !revealsSecrets && SecretMasker.hidesSomething(name: name, value: value))
                }
            } else {
                Text(hidden == 0 ? "\(variables.count) variables." : "\(variables.count) variables, \(hidden) masked as secrets.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        } accessory: {
            if !variables.isEmpty {
                if showsEnvironment, hidden > 0 {
                    SectionButton(symbol: revealsSecrets ? "eye.slash" : "eye", label: revealsSecrets ? "Mask secrets" : "Reveal secrets") {
                        revealsSecrets.toggle()
                    }
                }
                SectionButton(symbol: showsEnvironment ? "chevron.up" : "chevron.down", label: showsEnvironment ? "Hide variables" : "Show variables") {
                    withAnimation(Theme.hoverSpring) { showsEnvironment.toggle() }
                }
            }
        }
    }

    private func treeSection(_ group: ProcessGroup) -> some View {
        var depths: [Int32: Int] = [group.root.pid: 0]
        for member in group.descendants {
            depths[member.pid] = (depths[member.entry.ppid] ?? 0) + 1
        }
        return InspectorSection(title: "Process tree", symbol: "list.bullet.indent", count: group.members.count) {
            ForEach(group.members) { member in
                HStack(spacing: 6) {
                    Text(verbatim: "\(member.pid)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing)
                    Text(CommandSummary.title(arguments: SecretMasker.maskArguments(member.arguments), executableName: member.executableName))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, CGFloat(min(depths[member.pid] ?? 0, 6)) * 12)
                    Spacer(minLength: 4)
                    Text(StraysFormat.memory(member.residentBytes))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct Badge: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.14), in: Capsule())
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 22)
        }
        .buttonStyle(.bordered)
        .tint(tint == .primary ? nil : tint)
    }
}

private struct SectionButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    let symbol: String
    var count: Int?
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    init(
        title: String,
        symbol: String,
        count: Int? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                accessory
            }
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 6) { content }
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var reveal: (() -> Void)?

    init(label: String, value: String, reveal: (() -> Void)? = nil) {
        self.label = label
        self.value = value
        self.reveal = reveal
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let reveal {
                Button(action: reveal) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(label.lowercased()) in Finder")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EnvironmentRow: View {
    let name: String
    let value: String
    let isMasked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                if isMasked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.brew)
                        .accessibilityLabel("masked")
                }
            }
            Text(value.isEmpty ? "(empty)" : value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
