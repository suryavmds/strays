import AppKit

/// An editor Strays can open a project in.
enum CodeEditor: String, CaseIterable, Identifiable {
    case vsCode
    case cursor
    case zed
    case xcode

    static let defaultsKey = "preferredEditor"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vsCode: "VS Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .xcode: "Xcode"
        }
    }

    private var bundleIdentifiers: [String] {
        switch self {
        case .vsCode: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .zed: ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        case .xcode: ["com.apple.dt.Xcode"]
        }
    }

    @MainActor var applicationURL: URL? {
        bundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    @MainActor static var installed: [CodeEditor] {
        allCases.filter { $0.applicationURL != nil }
    }

    /// The editor chosen in Settings if it is still installed, otherwise the
    /// first supported editor found on this Mac.
    @MainActor static var preferred: CodeEditor? {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey),
           let editor = CodeEditor(rawValue: stored), editor.applicationURL != nil {
            return editor
        }
        return installed.first
    }
}

/// The things Strays does outside itself: browser, clipboard, Finder,
/// editor, terminal.
@MainActor
enum SystemActions {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func open(folder: String, with editor: CodeEditor) {
        guard let application = editor.applicationURL else { return }
        open(folder: folder, withApplicationAt: application)
    }

    /// Opens a new Terminal window in the folder. Handing a folder to a
    /// terminal app needs no Apple Events permission.
    static func openTerminal(at folder: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        open(folder: folder, withApplicationAt: terminal)
    }

    private static func open(folder: String, withApplicationAt application: URL) {
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: folder, isDirectory: true)],
            withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
