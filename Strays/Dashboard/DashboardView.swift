import SwiftUI
import StraysCore

/// The full management window: sidebar, main area, inspector, palette.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var state: DashboardState

    init() {
        _state = State(initialValue: DashboardState())
    }

    /// Starts in a given state. Used by previews and the snapshot renderer.
    init(configure: (DashboardState) -> Void) {
        let state = DashboardState()
        configure(state)
        _state = State(initialValue: state)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            mainArea
                .inspector(isPresented: Binding(
                    get: { state.isInspectorOpen && !state.sidebar.isPane },
                    set: { state.isInspectorOpen = $0 }
                )) {
                    InspectorView(state: state)
                        .inspectorColumnWidth(min: 300, ideal: 350, max: 520)
                }
        }
        .navigationTitle(state.title(in: model))
        .navigationSubtitle(subtitle)
        .searchable(text: $state.searchText, placement: .toolbar, prompt: "Name, port, project, PID")
        .toolbar { toolbar }
        .overlay {
            if state.isPaletteOpen {
                CommandPalette(state: state)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.hoverSpring, value: state.isPaletteOpen)
        .animation(Theme.listSpring, value: model.toast)
        .background(WindowVisibilityReader { model.isDashboardVisible = $0 })
        .background(DashboardWindowTracker())
        .onChange(of: model.dashboardRequest, initial: true) {
            // Asked from outside: a clicked notification, or the popover.
            switch model.dashboardRequest {
            case let .filter(filter):
                state.sidebar = .all
                state.filters = [filter]
            case let .pane(item):
                state.sidebar = item
            case nil:
                return
            }
            model.dashboardRequest = nil
        }
        .frame(minWidth: 900, minHeight: 540)
    }

    private var subtitle: String {
        switch state.sidebar {
        case .stacks:
            return model.stacks.count == 1 ? "1 stack" : "\(model.stacks.count) stacks"
        case .hidden:
            return model.hideRules.count == 1 ? "1 rule" : "\(model.hideRules.count) rules"
        case .settings:
            return "Strays \(StraysCore.version)"
        default:
            let count = state.visibleStrays(in: model).count
            return count == 1 ? "1 item" : "\(count) items"
        }
    }

    // MARK: - Main area

    @ViewBuilder private var mainArea: some View {
        let sections = state.sections(in: model)
        ZStack {
            VisualEffectBackground()
                .ignoresSafeArea()
            if state.sidebar == .stacks {
                StacksView()
            } else if state.sidebar == .hidden {
                HiddenView()
            } else if state.sidebar == .settings {
                SettingsView()
            } else if !model.hasLoaded {
                ProgressView("Looking around…")
            } else if sections.isEmpty {
                emptyState
            } else {
                switch state.viewMode {
                case .cards:
                    StrayCardsView(state: state, sections: sections)
                case .table:
                    StrayTableView(state: state, strays: sections.flatMap(\.strays))
                case .timeline:
                    StrayTimelineView(state: state, strays: sections.flatMap(\.strays))
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !state.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: state.searchText)
        } else if !state.filters.isEmpty {
            ContentUnavailableView {
                Label("Nothing matches", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing here is " + state.filters.map { $0.title.lowercased() }.sorted().joined(separator: " and ") + ".")
            } actions: {
                Button("Clear Filters") { state.filters.removeAll() }
            }
        } else if state.sidebar == .docker {
            ContentUnavailableView(
                model.snapshot.isDockerAvailable ? "No containers" : "Docker isn’t running",
                systemImage: "shippingbox",
                description: Text(model.snapshot.isDockerAvailable
                    ? "Containers you create will show up here, running or stopped."
                    : "Start Docker Desktop, OrbStack, or Colima and your containers will appear here.")
            )
        } else if state.sidebar == .brew {
            ContentUnavailableView(
                model.snapshot.isBrewAvailable ? "No Homebrew services" : "Homebrew isn’t installed",
                systemImage: "mug",
                description: Text(model.snapshot.isBrewAvailable
                    ? "Formulae with a service, like Redis or Postgres, show up here once installed."
                    : "Services managed with brew services would be listed here.")
            )
        } else {
            ContentUnavailableView(
                "Nothing running here",
                systemImage: "pawprint",
                description: Text("Dev servers, watchers, and whatever your coding agents leave behind will show up as soon as they start.")
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // View mode and filters only mean something for a list of strays.
        if !state.sidebar.isPane {
            listToolbar
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                state.isPaletteOpen.toggle()
            } label: {
                Label("Command Palette", systemImage: "command")
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("Command palette (⌘K)")
        }
        if !state.sidebar.isPane {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.isInspectorOpen.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide the inspector (⌥⌘I)")
            }
        }
    }

    @ToolbarContentBuilder private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $state.viewMode) {
                ForEach(DashboardViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Switch between cards, a dense table, and today's timeline")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(StrayFilter.allCases) { filter in
                    Toggle(isOn: Binding(
                        get: { state.filters.contains(filter) },
                        set: { isOn in
                            if isOn { state.filters.insert(filter) } else { state.filters.remove(filter) }
                        }
                    )) {
                        Label(filter.title, systemImage: filter.symbol)
                    }
                }
                if !state.filters.isEmpty {
                    Divider()
                    Button("Clear Filters") { state.filters.removeAll() }
                }
            } label: {
                Label("Filter", systemImage: state.filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help(state.filters.isEmpty ? "Filter by LAN-visible, stale, orphaned, or unknown origin" : "Filtering: " + state.filters.map(\.title).sorted().joined(separator: ", "))
        }
    }
}

/// Gives Strays a Dock icon and a place in ⌘-Tab while the dashboard is
/// open, and takes them away again when it closes, so the app lives in the
/// menu bar the rest of the time.
struct DashboardWindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        @objc private func windowWillClose() {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
