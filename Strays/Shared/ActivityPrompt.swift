import SwiftUI
import StraysCore

/// The question or notice that goes with a stray's current activity: confirm
/// stopping a macOS daemon, copy a sudo command, force kill a survivor.
///
/// It is shown inline, next to the stray, rather than as a modal alert: an
/// alert would dismiss the menu bar popover.
struct ActivityPrompt: View {
    let stray: Stray
    @Environment(AppModel.self) private var model

    var body: some View {
        if let activity = model.activity(for: stray), let content = content(for: activity) {
            content
                .padding(.top, 7)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func content(for activity: StrayActivity) -> InlinePrompt? {
        switch activity {
        case .stopping, .killing:
            return nil
        case let .confirming(reason):
            return InlinePrompt(symbol: "exclamationmark.triangle.fill", tint: Theme.brew, message: "\(reason) Stop it anyway?") {
                PromptButton("Stop", role: .destructive) { model.confirmStop(stray) }
                PromptButton("Cancel") { model.dismissActivity(for: stray) }
            }
        case let .needsPrivileges(command):
            return InlinePrompt(symbol: "lock.fill", tint: .secondary, message: "Owned by another user. Strays never asks for your password; run this yourself:") {
                PromptButton("Copy  \(command)") {
                    model.copy(command, label: command)
                    model.dismissActivity(for: stray)
                }
                PromptButton("Cancel") { model.dismissActivity(for: stray) }
            }
        case .survived:
            return InlinePrompt(symbol: "hourglass", tint: Theme.brew, message: "Still running after 5 seconds.") {
                PromptButton("Force Kill", role: .destructive) { model.forceKill(stray) }
                PromptButton("Leave It") { model.dismissActivity(for: stray) }
            }
        case let .failed(message):
            return InlinePrompt(symbol: "xmark.octagon.fill", tint: Theme.lan, message: message) {
                PromptButton("OK") { model.dismissActivity(for: stray) }
            }
        }
    }
}

struct InlinePrompt: View {
    let symbol: String
    let tint: Color
    let message: String
    let buttons: AnyView

    init(symbol: String, tint: Color, message: String, @ViewBuilder buttons: () -> some View) {
        self.symbol = symbol
        self.tint = tint
        self.message = message
        self.buttons = AnyView(buttons())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) { buttons }
        }
    }
}

struct PromptButton: View {
    let title: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: title.hasPrefix("Copy") ? .monospaced : .default))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(role == .destructive ? Theme.lan : nil)
    }
}

extension Stray {
    /// Protected processes get no Stop button at all.
    var canBeStopped: Bool {
        guard let policy = stopPolicy else { return false }
        if case .forbidden = policy { return false }
        return true
    }
}
