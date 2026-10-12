import SwiftUI
import StraysCore

/// The menu bar popover: a quick glance at what is running, with one-click
/// open and stop.
struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showsOthers = false
    @State private var listHeight: CGFloat = 0

    private static let width: CGFloat = 372
    private static let maximumListHeight: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
            Divider().opacity(0.6)
            footer
        }
        .frame(width: Self.width)
        .background(WindowVisibilityReader { model.isPopoverVisible = $0 })
        .overlay(alignment: .bottom) { toast }
        .animation(Theme.listSpring, value: model.toast)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(LinearGradient(colors: [Theme.dev, Theme.docker], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Strays")
                    .font(.system(size: 13, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Spacer()

            if model.lanVisibleCount > 0 {
                Label("\(model.lanVisibleCount) on LAN", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.lan)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.lan.opacity(0.13), in: Capsule())
                    .help("Dev processes with a port other machines on your network can reach")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var summary: String {
        guard model.hasLoaded else { return "Looking around…" }
        let count = model.devStrays.count
        switch count {
        case 0: return "Nothing running in the background"
        case 1: return "1 thing running"
        default: return "\(count) things running"
        }
    }

    // MARK: - List

    @ViewBuilder private var content: some View {
        if !model.hasLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(height: 96)
        } else if model.devStrays.isEmpty && model.otherListeners.isEmpty {
            emptyState
        } else {
            ScrollView {
                list
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 1), Self.maximumListHeight))
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.devStrays.isEmpty {
                allQuietBanner
            }
            ForEach(model.projectGroups) { group in
                ProjectHeader(group: group)
                ForEach(group.strays) { stray in
                    StrayRow(stray: stray)
                }
            }
            if !model.otherListeners.isEmpty {
                othersSection
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .animation(Theme.listSpring, value: model.snapshot.strays.map(\.id))
        .animation(Theme.listSpring, value: showsOthers)
    }

    private var allQuietBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.secondary)
            Text("No dev processes running")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private var othersSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                showsOthers.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showsOthers ? 90 : 0))
                    Text("Apps & system")
                        .font(.system(size: 11, weight: .semibold))
                    Text(verbatim: "\(model.otherListeners.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Apps and system, \(model.otherListeners.count) listening")
            .accessibilityHint(showsOthers ? "Collapses the list" : "Expands the list")

            if showsOthers {
                ForEach(model.otherListeners) { stray in
                    StrayRow(stray: stray)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.top, model.devStrays.isEmpty ? 0 : 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "pawprint")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No strays")
                .font(.system(size: 13, weight: .semibold))
            Text("Dev servers, watchers, and anything your\ncoding agents leave running will show up here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: WindowID.dashboard)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Dashboard", systemImage: "macwindow")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut("d", modifiers: .command)

            Spacer()

            Menu {
                Button("Refresh Now") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Quit Strays") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var toast: some View {
        if let toast = model.toast {
            ToastView(toast: toast)
                .padding(.bottom, 54)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Project header

private struct ProjectHeader: View {
    let group: StrayGroup
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.project == nil ? "questionmark.folder" : "folder.fill")
                .font(.system(size: 10))
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Text(verbatim: "\(group.strays.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            if let project = group.project, isHovering {
                Button {
                    model.reveal(project)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Reveal \(project.name) in Finder")
                .accessibilityLabel("Reveal \(project.name) in Finder")
                .transition(.opacity)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Theme.hoverSpring) { isHovering = hovering }
        }
        .help(group.project?.rootPath ?? "Processes that are not inside a project folder")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Row

/// One stray as a compact card. Hovering swaps the port chips for actions.
struct StrayRow: View {
    let stray: Stray
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    private var activity: StrayActivity? { model.activity(for: stray) }
    private var accent: Color { Theme.accent(for: stray) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainLine
            ActivityPrompt(stray: stray)
                .padding(.leading, 17)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.primary.opacity(isHovering || activity != nil ? 0.07 : 0))
        }
        .overlay {
            if stray.isLANVisible {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.lan.opacity(isHovering ? 0.55 : 0.28), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering in
            withAnimation(Theme.hoverSpring) { isHovering = hovering }
        }
        .animation(Theme.hoverSpring, value: activity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private var mainLine: some View {
        HStack(spacing: 9) {
            StatusDot(color: accent, isBusy: stray.isBusy)

            VStack(alignment: .leading, spacing: 1) {
                Text(stray.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(activity == .stopping || activity == .killing ? "Stopping…" : stray.statusLine())
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 6)

            ZStack(alignment: .trailing) {
                PortChips(ports: stray.ports, tint: accent == Theme.neutral ? .secondary : accent)
                    .opacity(showsActions ? 0 : 1)
                    .scaleEffect(showsActions ? 0.92 : 1, anchor: .trailing)
                actions
                    .opacity(showsActions ? 1 : 0)
                    .scaleEffect(showsActions ? 1 : 0.8, anchor: .trailing)
                    .allowsHitTesting(showsActions)
            }
        }
    }

    private var showsActions: Bool {
        isHovering && activity == nil
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 5) {
            if let port = stray.primaryPort, port.transport == .tcp {
                IconButton(symbol: "safari", label: "Open localhost:\(port.port) in the browser", tint: accent == Theme.neutral ? .primary : accent) {
                    model.open(port)
                }
                IconButton(symbol: "doc.on.doc", label: "Copy http://localhost:\(port.port)") {
                    model.copyURL(of: port)
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
        var parts = [stray.title, stray.statusLine()]
        if !stray.ports.isEmpty {
            parts.append("ports " + stray.ports.map { String($0.port) }.joined(separator: ", "))
        }
        if stray.isLANVisible { parts.append("visible on your network") }
        return parts.joined(separator: ", ")
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.symbol)
                .foregroundStyle(.green)
            Text(toast.message)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
