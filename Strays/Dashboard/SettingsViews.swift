import SwiftUI
import StraysCore

/// What the hide rules are hiding, and the rules themselves.
struct HiddenView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.hideRules.isEmpty {
            ContentUnavailableView(
                "Nothing is hidden",
                systemImage: "eye.slash",
                description: Text("Right-click anything and choose Hide to keep it out of the lists: by port, by name, or a whole project.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("Show hidden items everywhere", isOn: $model.showsHidden)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    PaneSection(title: "Rules", symbol: "eye.slash") {
                        ForEach(model.hideRules) { rule in
                            HStack(spacing: 8) {
                                Image(systemName: symbol(for: rule))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(rule.summary)
                                    .font(.system(size: 12, weight: .medium))
                                if rule.kind == .project {
                                    Text((rule.value as NSString).abbreviatingWithTildeInPath)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer()
                                let count = model.snapshot.strays.filter(rule.matches).count
                                Text(count == 0 ? "hiding nothing right now" : "hiding \(count)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                Button("Unhide") { model.unhide(rule) }
                                    .controlSize(.small)
                            }
                        }
                    }

                    if !model.hiddenStrays.isEmpty {
                        PaneSection(title: "Hidden right now", symbol: "list.bullet") {
                            ForEach(model.hiddenStrays) { stray in
                                HStack(spacing: 8) {
                                    StatusDot(color: Theme.accent(for: stray))
                                    Text(stray.title)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                    Text(stray.statusLine())
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    PortChips(ports: stray.ports, tint: .secondary)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func symbol(for rule: HideRule) -> String {
        switch rule.kind {
        case .port: "point.3.connected.trianglepath.dotted"
        case .name: "textformat"
        case .project: "folder"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var launchesAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var notificationsEnabled = Preferences.areStaleNotificationsEnabled
    @State private var notificationsRefused = false
    @AppStorage(Preferences.Key.staleNotificationMode) private var notificationMode = StaleNotificationPlanner.Mode.dailySummary.rawValue
    @State private var staleHours = Preferences.staleAfterHours
    @AppStorage(CodeEditor.defaultsKey) private var editor = CodeEditor.preferred?.rawValue ?? ""
    @AppStorage(Preferences.Key.preferredTerminal) private var terminal = TerminalApp.preferred.rawValue

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                general
                stale
                PaneSection(title: "Hidden items", symbol: "eye.slash") {
                    Toggle("Show hidden items everywhere", isOn: $model.showsHidden)
                    Text(model.hideRules.isEmpty ? "Nothing is hidden." : "\(model.hideRules.count) rules are hiding \(model.hiddenStrays.count) things. Manage them under Hidden.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                agents
                about
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(22)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - General

    private var general: some View {
        PaneSection(title: "General", symbol: "gearshape") {
            Toggle("Launch Strays at login", isOn: Binding(
                get: { launchesAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if let loginItemError {
                Text(loginItemError)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.brew)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Open projects in") {
                Picker("Editor", selection: $editor) {
                    if CodeEditor.installed.isEmpty { Text("None found").tag("") }
                    ForEach(CodeEditor.installed) { editor in
                        Text(editor.displayName).tag(editor.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledContent("Open terminals in") {
                Picker("Terminal", selection: $terminal) {
                    ForEach(TerminalApp.installed) { terminal in
                        Text(terminal.displayName).tag(terminal.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = "macOS would not change this: \(error.localizedDescription) Move Strays to the Applications folder and try again."
        }
        launchesAtLogin = LoginItem.isEnabled
    }

    // MARK: - Stale detection

    private var stale: some View {
        PaneSection(title: "Stale detection", symbol: "moon.zzz") {
            LabeledContent("Flag as stale after") {
                Stepper(value: $staleHours, in: 1...72, step: 1) {
                    Text(staleHours == 1 ? "1 hour" : "\(Int(staleHours)) hours")
                        .monospacedDigit()
                }
                .onChange(of: staleHours) { model.setStaleThreshold(hours: staleHours) }
                .fixedSize()
            }
            Text("Something is stale when it has been running that long and has done nothing for the last half hour. Containers and Homebrew services are meant to idle, and are never stale.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Notify me about stale things", isOn: Binding(
                get: { notificationsEnabled },
                set: { setNotifications($0) }
            ))
            if notificationsRefused {
                Text("Notifications are turned off for Strays in System Settings > Notifications.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.brew)
            }
            if notificationsEnabled {
                Picker("How often", selection: $notificationMode) {
                    Text("One summary a day").tag(StaleNotificationPlanner.Mode.dailySummary.rawValue)
                    Text("Each time something goes stale").tag(StaleNotificationPlanner.Mode.eachItem.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text("Each notification offers Stop and Snooze for a Day.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func setNotifications(_ enabled: Bool) {
        Task {
            let granted = await model.setStaleNotifications(enabled: enabled)
            notificationsEnabled = enabled && granted
            notificationsRefused = enabled && !granted
        }
    }

    // MARK: - Agents

    private var agents: some View {
        PaneSection(title: "AI agents", symbol: "sparkles") {
            ForEach(model.catalog.agents) { agent in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: agent.icon)
                        .foregroundStyle(agent.color)
                        .frame(width: 18)
                    Text(agent.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if agent.envMarkers.isEmpty {
                        Text("Running sessions only")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .help("No environment marker has been verified for \(agent.displayName), so processes that outlive its session cannot be recognised as orphans.")
                    } else {
                        Text("Orphans too: \(agent.envMarkers.map(\.name).joined(separator: ", "))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .help("Verified environment markers let Strays recognise processes left behind after a \(agent.displayName) session exits.")
                    }
                }
            }
            Text("Add or change agents without rebuilding by putting an agents.json in Strays' Application Support folder.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show Application Support Folder") {
                let folder = StraysDirectories.applicationSupport
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                model.reveal(path: folder.path)
            }
        }
    }

    // MARK: - About

    private var about: some View {
        PaneSection(title: "About", symbol: "pawprint") {
            LabeledContent("Version", value: StraysCore.version)
            Text("Strays is free and open source, under the MIT license. It never asks for your password and sends nothing anywhere.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A titled group in the Stacks, Hidden, and Settings panes.
struct PaneSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 9) { content }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
