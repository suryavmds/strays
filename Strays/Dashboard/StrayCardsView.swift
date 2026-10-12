import SwiftUI
import StraysCore

/// The dashboard's default view: a grid of cards, sectioned by project.
struct StrayCardsView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: DashboardState
    let sections: [StraySection]

    private let columns = [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(section: section)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(section.strays) { stray in
                                StrayCard(stray: stray, isSelected: state.selection == stray.id) {
                                    state.select(stray)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .animation(Theme.listSpring, value: sections.flatMap { $0.strays.map(\.id) })
        }
    }
}

struct SectionHeader: View {
    let section: StraySection
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: section.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(section.title)
                .font(.system(size: 13, weight: .semibold))
            Text(verbatim: "\(section.strays.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            if let project = section.project, project.rootPath.hasPrefix("/") {
                Text(abbreviated(project.rootPath))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let compose = section.composeProject, section.strays.contains(where: \.isRunning) {
                Button {
                    model.stopComposeProject(compose)
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(Theme.lan)
                .help("Stop every running container of the compose project \(compose)")
            }
            if let project = section.project, project.rootPath.hasPrefix("/") {
                Button {
                    model.reveal(project)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reveal \(project.name) in Finder")
                .accessibilityLabel("Reveal \(project.name) in Finder")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// One stray as a card. Click to inspect; hover for actions.
struct StrayCard: View {
    let stray: Stray
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    private var accent: Color { Theme.accent(for: stray) }
    private var activity: StrayActivity? { model.activity(for: stray) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ports
            footer
            ActivityPrompt(stray: stray)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(.ultraThinMaterial)
            shape.fill(LinearGradient(
                colors: [accent.opacity(isHovering ? 0.13 : 0.07), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
        .overlay { shape.strokeBorder(borderStyle, lineWidth: isSelected || stray.isLANVisible ? 1.5 : 1) }
        .shadow(color: .black.opacity(isHovering ? 0.22 : 0.1), radius: isHovering ? 12 : 5, y: isHovering ? 6 : 2)
        .scaleEffect(isHovering ? 1.012 : 1)
        .opacity(stray.isRunning ? 1 : 0.62)
        .contentShape(shape)
        .onTapGesture(perform: onSelect)
        .onAppear { model.setVisible(true, stray) }
        .onDisappear { model.setVisible(false, stray) }
        .onHover { hovering in
            withAnimation(Theme.hoverSpring) { isHovering = hovering }
        }
        .animation(Theme.hoverSpring, value: activity)
        .animation(Theme.hoverSpring, value: isSelected)
        .contextMenu { StrayContextMenu(stray: stray) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Inspect", onSelect)
    }

    /// Selection wins over the LAN warning, which wins over the resting hairline.
    private var borderStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(accent == Theme.neutral ? Color.accentColor : accent) }
        if stray.isLANVisible { return AnyShapeStyle(Theme.lan.opacity(0.7)) }
        return AnyShapeStyle(.primary.opacity(isHovering ? 0.16 : 0.08))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: stray.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accent == Theme.neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
                .frame(width: 32, height: 32)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: accent.opacity(stray.isBusy ? 0.55 : 0), radius: stray.isBusy ? 6 : 0)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(stray.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(secondLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var secondLine: String {
        if let progress = activity?.progressLabel { return progress }
        var parts: [String] = []
        if let subtitle = stray.subtitle { parts.append(subtitle) }
        if let container = stray.container {
            parts.append(container.shortID)
        } else if let pid = stray.processGroup?.root.pid {
            parts.append("PID \(pid)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var ports: some View {
        if stray.ports.isEmpty {
            Text(stray.isRunning ? "No listening port" : stray.container?.status ?? stray.brewService?.statusLabel ?? "Stopped")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(height: 20)
        } else {
            PortChips(ports: stray.ports, limit: 4, tint: accent == Theme.neutral ? .secondary : accent)
                .frame(height: 20)
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Sparkline(values: stray.isRunning ? model.history.samples(for: stray.id).map(\.cpuPercent) : [], color: accent == Theme.neutral ? .secondary : accent)
                    .frame(width: 84, height: 20)
                HStack(spacing: 8) {
                    if stray.isRunning {
                        stat(StraysFormat.cpu(stray.cpuPercent), "CPU")
                        stat(StraysFormat.memory(stray.memoryBytes), nil)
                        stat(StraysFormat.uptime(since: stray.startedAt), "up")
                    } else {
                        stat("Not running", nil)
                    }
                }
            }
            Spacer(minLength: 0)
            actions
                .opacity(isHovering && activity == nil ? 1 : 0)
                .scaleEffect(isHovering && activity == nil ? 1 : 0.85, anchor: .bottomTrailing)
                .allowsHitTesting(isHovering && activity == nil)
        }
    }

    private func stat(_ value: String, _ unit: String?) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 5) {
            if let port = stray.primaryPort, port.transport == .tcp {
                IconButton(symbol: "safari", label: "Open localhost:\(port.port) in the browser", tint: accent == Theme.neutral ? .primary : accent) {
                    model.open(port)
                }
                IconButton(symbol: "doc.on.doc", label: "Copy http://localhost:\(port.port)") {
                    model.copyURL(of: port)
                }
            }
            if stray.canBeStarted {
                IconButton(symbol: "play.fill", label: "Start \(stray.title)", tint: .green) {
                    model.start(stray)
                }
            }
            if stray.canBeStopped {
                IconButton(symbol: "stop.fill", label: "Stop \(stray.title)", tint: Theme.lan) {
                    model.requestStop(stray)
                }
            }
        }
    }

    private var accessibilityText: String {
        var parts = [stray.title, stray.categoryLabel, stray.statusLine()]
        if !stray.ports.isEmpty { parts.append("ports " + stray.ports.map { String($0.port) }.joined(separator: ", ")) }
        if stray.isLANVisible { parts.append("visible on your network") }
        return parts.joined(separator: ", ")
    }
}

/// The actions available on any stray, wherever it is shown.
struct StrayContextMenu: View {
    let stray: Stray
    @Environment(AppModel.self) private var model

    var body: some View {
        if let port = stray.primaryPort, port.transport == .tcp {
            Button("Open localhost:\(String(port.port))") { model.open(port) }
            Button("Copy URL") { model.copyURL(of: port) }
            Divider()
        }
        if let project = stray.project, project.rootPath.hasPrefix("/") {
            Button("Reveal \(project.name) in Finder") { model.reveal(project) }
        }
        if model.workingFolder(of: stray) != nil {
            Button("Open in \(CodeEditor.preferred?.displayName ?? "Editor")") { model.openInEditor(stray) }
            Button("Open Terminal Here") { model.openTerminal(at: stray) }
        }
        if let group = stray.processGroup {
            Divider()
            Button("Copy PID") { model.copy(String(group.root.pid), label: "PID \(group.root.pid)") }
            if !group.root.arguments.isEmpty {
                Button("Copy Command") {
                    model.copy(SecretMasker.maskArguments(group.root.arguments).joined(separator: " "), label: "command")
                }
            }
        }
        if let container = stray.container {
            Divider()
            Button("Copy Container ID") { model.copy(container.id, label: "container ID") }
        }

        Divider()
        if stray.canBeStarted {
            Button("Start") { model.start(stray) }
        }
        if stray.canBeRestarted {
            Button(stray.category == .dev ? "Restart (Experimental)" : "Restart") { model.restart(stray) }
        }
        if stray.canBeStopped {
            Button("Stop", role: .destructive) { model.requestStop(stray) }
        }
        if let compose = stray.container?.composeProject, stray.isRunning {
            Button("Stop Compose Project “\(compose)”", role: .destructive) { model.stopComposeProject(compose) }
        }
        if stray.container != nil {
            Button("Remove Container…", role: .destructive) { model.requestRemove(stray) }
        }
    }
}
