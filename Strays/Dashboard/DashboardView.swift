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
                .inspector(isPresented: $state.isInspectorOpen) {
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
        .frame(minWidth: 900, minHeight: 540)
    }

    private var subtitle: String {
        let count = state.visibleStrays(in: model).count
        return count == 1 ? "1 item" : "\(count) items"
    }

    // MARK: - Main area

    @ViewBuilder private var mainArea: some View {
        let sections = state.sections(in: model)
        ZStack {
            VisualEffectBackground()
                .ignoresSafeArea()
            if !model.hasLoaded {
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
        if state.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView(
                "Nothing running here",
                systemImage: "pawprint",
                description: Text("Dev servers, watchers, and whatever your coding agents leave behind will show up as soon as they start.")
            )
        } else {
            ContentUnavailableView.search(text: state.searchText)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
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
            Button {
                state.isPaletteOpen.toggle()
            } label: {
                Label("Command Palette", systemImage: "command")
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("Command palette (⌘K)")
        }
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
