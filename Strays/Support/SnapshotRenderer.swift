#if DEBUG
import AppKit
import SwiftUI

/// Renders the app's own views to PNG files, off screen, with demo data.
///
///     Strays --render-snapshots <directory>
///
/// This is how the UI gets checked from the command line without recording
/// the screen. Materials do not blur off screen, so a flat backdrop stands in.
@MainActor
enum SnapshotRenderer {
    static var requestedDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-snapshots"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    /// `--live` renders this Mac's real data instead of the demo set.
    static var usesLiveData: Bool { CommandLine.arguments.contains("--live") }

    private static func makeModel() -> AppModel {
        guard usesLiveData else { return AppModel(demo: DemoData.snapshot) }
        let model = AppModel()
        model.isDashboardVisible = true
        // Two scans, so CPU figures have something to compare against.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        return model
    }

    static func renderAll(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if usesLiveData {
            let model = makeModel()
            render(popoverCanvas(model), size: CGSize(width: 372, height: 620), scheme: .dark, to: directory.appendingPathComponent("live-popover.png"))
            for mode in [DashboardViewMode.cards, .table] {
                let dashboard = DashboardView { state in
                    state.persistsViewMode = false
                    state.viewMode = mode
                    state.selection = model.activeStrays.first?.id ?? model.snapshot.strays.first?.id
                }
                renderWindow(dashboard.environment(model), size: CGSize(width: 1180, height: 760), scheme: .dark, to: directory.appendingPathComponent("live-dashboard-\(mode.rawValue).png"))
            }
            return
        }
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let model = AppModel(demo: DemoData.snapshot)
            render(popoverCanvas(model), size: CGSize(width: 372, height: 620), scheme: scheme, to: directory.appendingPathComponent("popover-\(suffix).png"))
            for mode in DashboardViewMode.allCases where scheme == .dark || mode == .cards {
                let dashboard = DashboardView { state in
                    state.persistsViewMode = false
                    state.viewMode = mode
                    state.selection = model.snapshot.strays.first?.id
                }
                renderWindow(dashboard.environment(model), size: CGSize(width: 1180, height: 760), scheme: scheme, to: directory.appendingPathComponent("dashboard-\(mode.rawValue)-\(suffix).png"))
            }
        }
        let model = AppModel(demo: DemoData.snapshot)
        let docker = DashboardView { state in
            state.persistsViewMode = false
            state.viewMode = .cards
            state.sidebar = .docker
            state.selection = model.containers.first?.id
        }
        renderWindow(docker.environment(model), size: CGSize(width: 1180, height: 760), scheme: .dark, to: directory.appendingPathComponent("dashboard-docker-dark.png"))
        let agent = DashboardView { state in
            state.persistsViewMode = false
            state.viewMode = .cards
            state.sidebar = .agent("claude-code")
            state.selection = model.orphanedStrays.first?.id
        }
        renderWindow(agent.environment(model), size: CGSize(width: 1180, height: 760), scheme: .dark, to: directory.appendingPathComponent("dashboard-agent-dark.png"))
        for (name, item) in [("stacks", SidebarItem.stacks), ("settings", .settings)] {
            let pane = DashboardView { state in
                state.persistsViewMode = false
                state.sidebar = item
                state.isInspectorOpen = false
            }
            renderWindow(pane.environment(model), size: CGSize(width: 1180, height: 760), scheme: .dark, to: directory.appendingPathComponent("dashboard-\(name)-dark.png"))
        }
        let palette = DashboardView { state in
            state.persistsViewMode = false
            state.viewMode = .cards
            state.isPaletteOpen = true
            state.isInspectorOpen = false
        }
        renderWindow(palette.environment(model), size: CGSize(width: 1180, height: 760), scheme: .dark, to: directory.appendingPathComponent("dashboard-palette-dark.png"))
        renderMenuBarIcons(to: directory.appendingPathComponent("menubar-icons.png"))
    }

    /// The popover sizes itself, so it is pinned to the top of a fixed canvas.
    private static func popoverCanvas(_ model: AppModel) -> some View {
        VStack(spacing: 0) {
            MenuBarPopover().environment(model)
            Spacer(minLength: 0)
        }
    }

    static func render(_ view: some View, size: CGSize, scheme: ColorScheme, to url: URL) {
        let backdrop = scheme == .dark ? Color(white: 0.13) : Color(white: 0.95)
        let hosting = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(backdrop)
            .environment(\.colorScheme, scheme))
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI finish its first layout and any onAppear work.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Renders a view in a real, composited window and captures that window.
    ///
    /// `cacheDisplay` cannot draw AppKit's vibrancy-backed panes (the sidebar,
    /// the inspector), so the dashboard needs the window server. The window
    /// is placed far off screen: nothing flashes, and nothing of the desktop
    /// behind it can show through.
    static func renderWindow(_ view: some View, size: CGSize, scheme: ColorScheme, to url: URL) {
        let controller = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        controller.sceneBridgingOptions = [.all]

        let window = OffscreenWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.setFrame(CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height), display: true)
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))

        if let image = captureWindow(number: window.windowNumber) {
            let bitmap = NSBitmapImageRep(cgImage: image)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        } else {
            FileHandle.standardError.write(Data("window capture unavailable for \(url.lastPathComponent)\n".utf8))
        }
        window.close()
    }

    /// Captures one of this app's own windows. `CGWindowListCreateImage` is
    /// hidden from Swift in current SDKs but remains the only way to grab a
    /// single window without the Screen Recording permission, which an app
    /// does not need for its own windows. Debug builds only.
    private static func captureWindow(number: Int) -> CGImage? {
        typealias Function = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: Function.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        return createImage(.null, includingWindow, UInt32(number), boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
    }

    /// The menu bar icon in its states, on light and dark bars, enlarged.
    private static func renderMenuBarIcons(to url: URL) {
        let states: [(Int, Bool)] = [(0, false), (3, false), (12, true), (128, true)]
        let view = VStack(spacing: 0) {
            ForEach([ColorScheme.dark, .light], id: \.self) { scheme in
                HStack(spacing: 22) {
                    ForEach(states, id: \.0) { count, attention in
                        Image(nsImage: MenuBarIcon.image(count: count, needsAttention: attention))
                            .renderingMode(.template)
                            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                    }
                }
                .scaleEffect(2.5)
                .frame(width: 520, height: 70)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.92))
            }
        }
        render(view, size: CGSize(width: 520, height: 140), scheme: .dark, to: url)
    }
}
/// A window that AppKit will not drag back onto a screen.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
#endif
