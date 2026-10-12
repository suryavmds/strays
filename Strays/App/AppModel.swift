import AppKit
import Observation
import StraysCore

/// What is happening to one stray right now, beyond simply running.
enum StrayActivity: Equatable {
    /// A macOS daemon: ask before stopping.
    case confirming(reason: String)
    /// Root's or another user's: offer the command, never escalate.
    case needsPrivileges(command: String)
    case stopping
    /// Outlived SIGTERM and the grace period.
    case survived
    case killing
    case failed(String)
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var message: String
}

/// A project and the strays running inside it.
struct StrayGroup: Identifiable {
    let id: String
    let title: String
    let project: Project?
    let strays: [Stray]
}

/// The single source of truth for both the menu bar popover and the dashboard.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: StraysSnapshot = .empty
    private(set) var hasLoaded = false
    private(set) var activity: [Stray.ID: StrayActivity] = [:]
    private(set) var toast: Toast?

    var isPopoverVisible = false { didSet { updateCadence() } }
    var isDashboardVisible = false { didSet { updateCadence() } }

    @ObservationIgnored private let monitor: Monitor?
    @ObservationIgnored private let controller = ProcessController()
    @ObservationIgnored private var survivors: [Stray.ID: [SignalTarget]] = [:]
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var toastDismissal: Task<Void, Never>?
    @ObservationIgnored private var isAsleep = false

    /// Live data from this Mac.
    init() {
        monitor = Monitor()
        observeSleep()
        subscribe()
        updateCadence()
    }

    /// Fixed data, for previews, screenshots, and the `--demo` flag. Nothing
    /// on the machine is scanned or signalled.
    init(demo snapshot: StraysSnapshot) {
        monitor = nil
        self.snapshot = snapshot
        hasLoaded = true
    }

    var isDemo: Bool { monitor == nil }

    // MARK: - Derived views of the snapshot

    var devStrays: [Stray] { snapshot.strays.filter { $0.category == .dev } }

    /// Apps and system daemons that listen on a port.
    var otherListeners: [Stray] { snapshot.strays.filter { $0.category == .app || $0.category == .system } }

    /// The number shown next to the menu bar icon.
    var badgeCount: Int { devStrays.count }

    var lanVisibleCount: Int { devStrays.filter(\.isLANVisible).count }

    /// Drives the dot on the menu bar icon: something was left behind by an
    /// agent session that has since exited.
    var needsAttention: Bool { snapshot.strays.contains { $0.origin.isOrphaned } }

    /// Dev strays grouped by project, the most recently active project first.
    var projectGroups: [StrayGroup] {
        var order: [String] = []
        var buckets: [String: [Stray]] = [:]
        for stray in devStrays {
            let key = stray.project?.id ?? ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(stray)
        }
        return order.map { key in
            let strays = buckets[key] ?? []
            let project = strays.first?.project
            return StrayGroup(id: key.isEmpty ? "no-project" : key, title: project?.name ?? "No project", project: project, strays: strays)
        }
    }

    func activity(for stray: Stray) -> StrayActivity? { activity[stray.id] }

    // MARK: - Monitoring

    private func subscribe() {
        guard let monitor else { return }
        subscription = Task { [weak self] in
            for await snapshot in await monitor.snapshots() {
                self?.receive(snapshot)
            }
        }
    }

    private func receive(_ snapshot: StraysSnapshot) {
        self.snapshot = snapshot
        hasLoaded = true
        // Forget transient state for strays that are gone.
        let alive = Set(snapshot.strays.map(\.id))
        activity = activity.filter { alive.contains($0.key) }
        survivors = survivors.filter { alive.contains($0.key) }
    }

    private func updateCadence() {
        guard let monitor else { return }
        let cadence: Monitor.Cadence = isAsleep ? .paused : (isPopoverVisible || isDashboardVisible) ? .active : .background
        Task { await monitor.setCadence(cadence) }
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAsleep(true) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAsleep(false) }
        }
    }

    private func setAsleep(_ asleep: Bool) {
        isAsleep = asleep
        updateCadence()
    }

    func refresh() {
        guard let monitor else { return }
        Task { await monitor.refresh() }
    }

    // MARK: - Stopping

    /// Entry point for every Stop button. Applies the safety policy first.
    func requestStop(_ stray: Stray) {
        guard let policy = stray.stopPolicy else { return }
        switch policy {
        case .allowed:
            stop(stray)
        case let .needsConfirmation(reason):
            activity[stray.id] = .confirming(reason: reason)
        case let .needsPrivileges(command):
            activity[stray.id] = .needsPrivileges(command: command)
        case let .forbidden(reason):
            activity[stray.id] = .failed(reason)
        }
    }

    /// Called after the user confirmed stopping a macOS daemon.
    func confirmStop(_ stray: Stray) {
        guard case .confirming = activity[stray.id] else { return }
        stop(stray)
    }

    func dismissActivity(for stray: Stray) {
        activity[stray.id] = nil
        survivors[stray.id] = nil
    }

    private func stop(_ stray: Stray) {
        guard let root = stray.signalRoot else { return }
        guard !isDemo else { return showToast("stop.circle", "Demo mode: nothing was stopped") }
        activity[stray.id] = .stopping

        // A dev process is stopped with its whole tree; an app on its own.
        let targets = stray.category == .dev ? controller.tree(of: root) : [root]
        guard !targets.isEmpty else {
            // The PID no longer belongs to this process: it already exited.
            activity[stray.id] = nil
            refresh()
            return
        }

        Task {
            let result = await controller.stop(targets)
            finishStop(of: stray, with: result, forced: false)
        }
    }

    func forceKill(_ stray: Stray) {
        guard let targets = survivors[stray.id], !targets.isEmpty else { return }
        activity[stray.id] = .killing
        Task {
            let result = await controller.forceKill(targets)
            finishStop(of: stray, with: result, forced: true)
        }
    }

    private func finishStop(of stray: Stray, with result: StopResult, forced: Bool) {
        if !result.survivors.isEmpty {
            survivors[stray.id] = result.survivors
            activity[stray.id] = forced ? .failed("Still running after SIGKILL.") : .survived
        } else if result.exited.isEmpty, let skipped = result.skipped.first {
            activity[stray.id] = .failed(Self.explain(skipped.reason))
        } else {
            activity[stray.id] = nil
            survivors[stray.id] = nil
            showToast("checkmark.circle.fill", "Stopped \(stray.title)")
        }
        refresh()
    }

    private static func explain(_ reason: StopResult.SkipReason) -> String {
        switch reason {
        case let .protected(why): why
        case .noLongerTheSameProcess: "It had already exited."
        case .permissionDenied: "macOS refused: it belongs to another user."
        }
    }

    // MARK: - Toasts

    func showToast(_ symbol: String, _ message: String) {
        toast = Toast(symbol: symbol, message: message)
        toastDismissal?.cancel()
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - Other actions

    func open(_ port: PortSummary) {
        guard let url = port.localURL else { return }
        SystemActions.open(url)
    }

    func copyURL(of port: PortSummary) {
        guard let url = port.localURL else { return }
        SystemActions.copy(url.absoluteString)
        showToast("doc.on.doc.fill", "Copied \(url.absoluteString)")
    }

    func copy(_ text: String, label: String) {
        SystemActions.copy(text)
        showToast("doc.on.doc.fill", "Copied \(label)")
    }

    func reveal(_ project: Project) {
        SystemActions.revealInFinder(project.rootPath)
    }
}
