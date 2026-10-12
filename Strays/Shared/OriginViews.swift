import SwiftUI
import StraysCore

extension Color {
    /// `#RRGGBB`, as written in `agents.json`. Grey when it does not parse.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .secondary
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension AgentProfile {
    var color: Color { Color(hex: badgeColor) }
}

/// How an origin is shown: a name, a symbol, and a colour.
struct OriginPresentation {
    let label: String
    let symbol: String
    let color: Color
    /// Orphans are the ones worth noticing.
    let isAlert: Bool

    @MainActor
    init?(_ origin: Origin, catalog: AgentCatalog) {
        switch origin {
        case let .agent(id, orphaned):
            let profile = catalog.agent(withID: id)
            let name = profile?.displayName ?? id
            label = orphaned ? "Orphaned from \(name)" : name
            symbol = orphaned ? "exclamationmark.triangle.fill" : (profile?.icon ?? "sparkle")
            color = profile?.color ?? .secondary
            isAlert = orphaned
        case let .terminal(name):
            label = name
            symbol = "terminal"
            color = .secondary
            isAlert = false
        case let .ide(name):
            label = name
            symbol = "chevron.left.forwardslash.chevron.right"
            color = .secondary
            isAlert = false
        case .unknown:
            return nil
        }
    }
}

/// A capsule naming where a stray came from. Agents get their own colour;
/// an orphan gets an outline so it stands out.
///
/// The catalog is passed in rather than read from the environment: cells of
/// a macOS `Table` do not inherit environment objects.
struct OriginBadge: View {
    enum Style {
        /// "Orphaned from Claude Code".
        case full
        /// "Claude Code", with the warning symbol carrying the rest.
        case short
        /// The symbol alone.
        case icon
    }

    let origin: Origin
    let catalog: AgentCatalog
    var style: Style = .full

    init(origin: Origin, catalog: AgentCatalog, style: Style = .full) {
        self.origin = origin
        self.catalog = catalog
        self.style = style
    }

    init(origin: Origin, catalog: AgentCatalog, isCompact: Bool) {
        self.init(origin: origin, catalog: catalog, style: isCompact ? .icon : .full)
    }

    var body: some View {
        if let presentation = OriginPresentation(origin, catalog: catalog) {
            HStack(spacing: 3) {
                Image(systemName: presentation.symbol)
                    .font(.system(size: 8.5, weight: .bold))
                if style != .icon {
                    Text(style == .short ? shortLabel(presentation) : presentation.label)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(presentation.color)
            .padding(.horizontal, style == .icon ? 5 : 6)
            .padding(.vertical, 2.5)
            .background(presentation.color.opacity(presentation.isAlert ? 0.2 : 0.13), in: Capsule())
            .overlay {
                if presentation.isAlert {
                    Capsule().strokeBorder(presentation.color.opacity(0.8), lineWidth: 1)
                }
            }
            .fixedSize()
            .help(help(presentation))
            .accessibilityLabel(presentation.label)
        }
    }

    private func shortLabel(_ presentation: OriginPresentation) -> String {
        origin.agentID.flatMap { catalog.agent(withID: $0)?.displayName } ?? presentation.label
    }

    private func help(_ presentation: OriginPresentation) -> String {
        switch origin {
        case .agent(_, true): "\(presentation.label): the agent session that started this has exited"
        case .agent: "Started by \(presentation.label)"
        default: "Started from \(presentation.label)"
        }
    }
}

/// The widest form of the origin and stale badges that fits the space.
struct AdaptiveOriginBadges: View {
    let stray: Stray
    let catalog: AgentCatalog

    var body: some View {
        if stray.isStale || !stray.origin.isUnknown {
            ViewThatFits(in: .horizontal) {
                row(.full, compactStale: false)
                row(.short, compactStale: true)
                row(.icon, compactStale: true)
            }
        }
    }

    private func row(_ style: OriginBadge.Style, compactStale: Bool) -> some View {
        HStack(spacing: 4) {
            OriginBadge(origin: stray.origin, catalog: catalog, style: style)
            if stray.isStale { StaleBadge(isCompact: compactStale) }
        }
    }
}

/// Marks something that has been running for hours and idle for a while.
struct StaleBadge: View {
    var isCompact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 8.5, weight: .bold))
            if !isCompact { Text("Stale") }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Theme.brew)
        .padding(.horizontal, isCompact ? 5 : 6)
        .padding(.vertical, 2.5)
        .background(Theme.brew.opacity(0.15), in: Capsule())
        .fixedSize()
        .help("Running for hours and idle for the last half hour")
        .accessibilityLabel("Stale")
    }
}
