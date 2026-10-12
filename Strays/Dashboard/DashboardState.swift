import SwiftUI
import StraysCore

/// What the sidebar can show.
enum SidebarItem: Hashable {
    case all
    /// Everything with a port, ordered by port number.
    case ports
    case project(String)
    /// Everything one AI agent started, by agent id.
    case agent(String)
    /// Every container, running or stopped.
    case docker
    /// Every Homebrew service, started or stopped.
    case brew
    /// Apps and system daemons that listen on a port.
    case others
}

/// Narrows whatever the sidebar shows.
enum StrayFilter: String, CaseIterable, Identifiable {
    case lanVisible
    case stale
    case orphaned
    case unknownOrigin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lanVisible: "LAN-Visible"
        case .stale: "Stale"
        case .orphaned: "Orphaned from an Agent"
        case .unknownOrigin: "Unknown Origin"
        }
    }

    var symbol: String {
        switch self {
        case .lanVisible: "wifi.exclamationmark"
        case .stale: "moon.zzz"
        case .orphaned: "exclamationmark.triangle"
        case .unknownOrigin: "questionmark.circle"
        }
    }

    func matches(_ stray: Stray) -> Bool {
        switch self {
        case .lanVisible: stray.isLANVisible
        case .stale: stray.isStale
        case .orphaned: stray.origin.isOrphaned
        // Only dev processes are attributed at all.
        case .unknownOrigin: stray.category == .dev && stray.origin.isUnknown
        }
    }
}

enum DashboardViewMode: String, CaseIterable, Identifiable {
    case cards
    case table
    case timeline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: "Cards"
        case .table: "Table"
        case .timeline: "Timeline"
        }
    }

    var symbol: String {
        switch self {
        case .cards: "square.grid.2x2"
        case .table: "tablecells"
        case .timeline: "chart.bar.xaxis"
        }
    }
}

/// A titled run of strays in the main area.
struct StraySection: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let project: Project?
    let strays: [Stray]
    /// Set when the section is one compose project, which can be stopped whole.
    var composeProject: String?
}

/// The dashboard window's own state: where the user is and what they picked.
@MainActor
@Observable
final class DashboardState {
    private static let viewModeKey = "dashboardViewMode"

    var sidebar: SidebarItem = .all
    var selection: Stray.ID?
    var searchText = ""
    /// A stray must match every active filter.
    var filters: Set<StrayFilter> = []
    var isPaletteOpen = false
    var isInspectorOpen = true

    var viewMode: DashboardViewMode {
        didSet {
            guard persistsViewMode else { return }
            UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeKey)
        }
    }

    /// Off for previews and snapshots, which must not change the user's choice.
    @ObservationIgnored var persistsViewMode = true

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.viewModeKey)
        viewMode = stored.flatMap(DashboardViewMode.init(rawValue:)) ?? .cards
    }

    func select(_ stray: Stray) {
        selection = stray.id
        isInspectorOpen = true
    }

    func title(in model: AppModel) -> String {
        switch sidebar {
        case .all: "All"
        case .ports: "Listening Ports"
        case .others: "Apps & System"
        case .docker: "Docker"
        case .brew: "Brew Services"
        case let .agent(id): model.catalog.agent(withID: id)?.displayName ?? "Agent"
        case let .project(id): model.projectGroups.first { $0.id == id }?.title ?? "Project"
        }
    }

    /// The strays the current sidebar item and search text leave visible,
    /// already split into sections.
    func sections(in model: AppModel) -> [StraySection] {
        let sections: [StraySection]
        switch sidebar {
        case .all:
            var result = model.projectGroups.map(Self.section(for:))
            if !model.otherListeners.isEmpty {
                result.append(StraySection(id: "others", title: "Apps & System", symbol: "macwindow.on.rectangle", project: nil, strays: model.otherListeners))
            }
            sections = result
        case .ports:
            let listening = model.snapshot.strays
                .filter { !$0.ports.isEmpty }
                .sorted { ($0.primaryPort?.port ?? 0) < ($1.primaryPort?.port ?? 0) }
            sections = [StraySection(id: "ports", title: "By port number", symbol: "point.3.connected.trianglepath.dotted", project: nil, strays: listening)]
        case .others:
            sections = [StraySection(id: "others", title: "Apps & System", symbol: "macwindow.on.rectangle", project: nil, strays: model.otherListeners)]
        case .docker:
            sections = Self.dockerSections(model.containers)
        case .brew:
            sections = [
                StraySection(id: "brew-running", title: "Started", symbol: "mug.fill", project: nil, strays: model.brewServices.filter(\.isRunning)),
                StraySection(id: "brew-stopped", title: "Stopped", symbol: "mug", project: nil, strays: model.brewServices.filter { !$0.isRunning }),
            ]
        case let .project(id):
            sections = model.projectGroups.filter { $0.id == id }.map(Self.section(for:))
        case let .agent(id):
            let strays = model.detectedAgents.first { $0.id == id }?.strays ?? []
            sections = [
                StraySection(id: "agent-orphans", title: "Orphaned: their session has exited", symbol: "exclamationmark.triangle.fill", project: nil, strays: strays.filter(\.origin.isOrphaned)),
                StraySection(id: "agent-live", title: "Started by a running session", symbol: "sparkle", project: nil, strays: strays.filter { !$0.origin.isOrphaned }),
            ]
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty || !filters.isEmpty else { return sections.filter { !$0.strays.isEmpty } }
        return sections.compactMap { section in
            let matching = section.strays.filter { stray in
                stray.matches(query: query) && filters.allSatisfy { $0.matches(stray) }
            }
            return matching.isEmpty ? nil : StraySection(id: section.id, title: section.title, symbol: section.symbol, project: section.project, strays: matching, composeProject: section.composeProject)
        }
    }

    func visibleStrays(in model: AppModel) -> [Stray] {
        sections(in: model).flatMap(\.strays)
    }

    /// Containers by compose project, running projects first, with loose
    /// containers at the end.
    private static func dockerSections(_ containers: [Stray]) -> [StraySection] {
        var order: [String] = []
        var buckets: [String: [Stray]] = [:]
        for stray in containers {
            let key = stray.container?.composeProject ?? ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(stray)
        }
        return order.sorted { ($0.isEmpty ? 1 : 0, $0) < ($1.isEmpty ? 1 : 0, $1) }.map { key in
            let strays = buckets[key] ?? []
            return StraySection(
                id: "compose:\(key)",
                title: key.isEmpty ? "Standalone containers" : key,
                symbol: key.isEmpty ? "shippingbox" : "square.stack.3d.up.fill",
                project: key.isEmpty ? nil : strays.first?.project,
                strays: strays,
                composeProject: key.isEmpty ? nil : key
            )
        }
    }

    private static func section(for group: StrayGroup) -> StraySection {
        StraySection(
            id: group.id,
            title: group.title,
            symbol: group.symbol,
            project: group.project,
            strays: group.strays,
            composeProject: group.composeProject
        )
    }
}

// Sort keys for the table, which needs non-optional comparable values.
extension Stray {
    var projectName: String { project?.name ?? "" }
    var firstPortNumber: Int { primaryPort.map { Int($0.port) } ?? Int.max }
    var rootPID: Int32 { processGroup?.root.pid ?? 0 }
    var startDate: Date { startedAt ?? .distantPast }
    var memoryMegabytes: Double { Double(memoryBytes) / 1_048_576 }

    /// Orphans first, then agents by name, then terminals and IDEs.
    var originSortKey: String {
        switch origin {
        case let .agent(id, orphaned): (orphaned ? "0" : "1") + id
        case let .terminal(name): "2" + name
        case let .ide(name): "3" + name
        case .unknown: "9"
        }
    }

    /// The SF Symbol that stands for this stray's runtime or kind.
    var symbol: String {
        if let symbol = processGroup?.runtime?.symbol { return symbol }
        switch category {
        case .dev: return "terminal"
        case .app: return "macwindow"
        case .system: return "gearshape.2"
        case .docker: return "shippingbox"
        case .brew: return "mug"
        }
    }

    var categoryLabel: String {
        switch category {
        case .dev: "Dev process"
        case .app: "App"
        case .system: "System"
        case .docker: "Docker"
        case .brew: "Brew service"
        }
    }
}
