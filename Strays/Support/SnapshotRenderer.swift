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

    static func renderAll(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let model = AppModel(demo: DemoData.snapshot)
            render(popoverCanvas(model), size: CGSize(width: 372, height: 620), scheme: scheme, to: directory.appendingPathComponent("popover-\(suffix).png"))
            render(DashboardView().environment(model), size: CGSize(width: 1080, height: 700), scheme: scheme, to: directory.appendingPathComponent("dashboard-\(suffix).png"))
        }
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
#endif
