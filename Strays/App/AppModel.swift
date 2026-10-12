import AppKit
import Observation
import StraysCore

/// What is happening to one stray right now, beyond simply running.
enum StrayActivity: Equatable {
    /// A macOS daemon or an app: ask before stopping.
    case confirming(reason: String)
    /// Removing a container cannot be undone: ask first.
    case confirmingRemoval(reason: String)
    /// Root's or another user's: offer the command, never escalate.
    case needsPrivileges(command: String)
    case stopping
    case starting
    case restarting
    case removing
    /// Outlived SIGTERM and the grace period.
    case survived
    case killing
    case failed(String)

    /// The word to show while work is in flight, if any.
    var progressLabel: String? {
        switch self {
        case .stopping, .killing: "Stopping…"
        case .starting: "Starting…"
        case .restarting: "Restarting…"
        case .removing: "Removing…"
        default: nil
        }
    }

    var isInFlight: Bool { progressLabel != nil }
}

struct Toast: Identifiable, Equatable {
    /// What the toast's button does: the undo for a stop.
    enum Action: Equatable {
        case startContainer(id: String, name: String)
        case startService(name: String)

        var title: String { "Start Again" }
    }

    let id = UUID()
    var symbol: String
    var message: String
    var action: Action?
}

/// A project and the strays running inside it.
struct StrayGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let project: Project?
    let strays: [Stray]

    /// Set when every container in the group belongs to one compose project.
    var composeProject: String? {
        let names = Set(strays.compactMap { $0.container?.composeProject })
        let containers = strays.filter { $0.container != nil }
        guard names.count == 1, containers.count > 1, containers.allSatisfy({ $0.container?.composeProject != nil }) else { return nil }
        return names.first
    }
}

/// A place in the dashboard to jump to.
enum DashboardRequest: Equatable {
    case filter(StrayFilter)
    case pane(SidebarItem)
}

/// An agent that has something to show: a running session, or strays it started.
struct DetectedAgent: Identifiable {
    let profile: AgentProfile
    let strays: [Stray]
    let sessionCount: Int

    var id: String { profile.id }
    var orphans: [Stray] { strays.filter(\.origin.isOrphaned) }
}

/// The single source of truth for both the menu bar popover and the dashboard.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: StraysSnapshot = .empty
    private(set) var hasLoaded = false
    private(set) var activity: [Stray.ID: StrayActivity] = [:]
    private(set) var toast: Toast?
    /// Recent CPU and memory per stray, for sparklines.
    private(set) var history = MetricsHistory()

    var isPopoverVisible = false { didSet { updateCadence() } }
    var isDashboardVisible = false { didSet { updateCadence() } }

    /// Agent, terminal, and IDE profiles, with the user's overrides applied.
    let catalog: AgentCatalog

    // Stacks and hide rules, mirrored to JSON in Application Support.
    private(set) var stacks: [Stack] = []
    private(set) var stackStatuses: [UUID: StackItemStatus] = [:]
    /// Stack items with a start or stop in flight.
    private(set) var busyStackItems: Set<UUID> = []
    private(set) var hideRules: [HideRule] = []
    var showsHidden = UserDefaults.standard.bool(forKey: Preferences.Key.showsHidden) {
        didSet { UserDefaults.standard.set(showsHidden, forKey: Preferences.Key.showsHidden) }
    }

    @ObservationIgnored private let store: StackStore?
    /// A newer release on GitHub, if the daily check found one. Strays
    /// only reports it; it never downloads or installs anything.
    private(set) var availableUpdate: ReleaseInfo?
    private(set) var isCheckingForUpdates = false

    /// Where the dashboard should go next, set from outside it: a clicked
    /// notification, or "Settings…" in the menu bar popover.
    var dashboardRequest: DashboardRequest?

    @ObservationIgnored private var notifier: StaleNotifier?
    /// Held for as long as the app runs; see `stayAwake()`.
    @ObservationIgnored private var appNapOptOut: NSObjectProtocol?
    @ObservationIgnored private let monitor: Monitor?
    @ObservationIgnored private let controller = ProcessController()
    @ObservationIgnored private var survivors: [Stray.ID: [SignalTarget]] = [:]
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var toastDismissal: Task<Void, Never>?
    @ObservationIgnored private var isAsleep = false
    @ObservationIgnored private var visibleContainers: Set<String> = []

    /// Live data from this Mac.
    init() {
        let catalog = AgentCatalog.load()
        self.catalog = catalog
        let store = StackStore()
        self.store = store
        stacks = store.loadStacks()
        hideRules = store.loadHideRules()
        let monitor = Monitor(agents: catalog, stackStore: store)
        self.monitor = monitor
        Task {
            await monitor.setStaleThreshold(hours: Preferences.staleAfterHours)
            await monitor.setPackageNamePolicy(Preferences.packageNamePolicy)
        }
        stayAwake()
        observeSleep()
        subscribe()
        updateCadence()
        startNotifier()
        checkForUpdatesIfDue()
    }

    /// Opts out of App Nap.
    ///
    /// A menu bar app with no window open is exactly what App Nap puts to
    /// sleep: after half a minute its timers stop firing altogether, the
    /// scans stop, and the count in the menu bar goes stale. Strays' whole
    /// job is to notice things while you are not looking at it. The work
    /// it stays awake for is a few milliseconds every ten seconds, and
    /// this still lets the Mac itself go to sleep.
    private func stayAwake() {
        appNapOptOut = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Watching for background processes so the menu bar count stays current"
        )
    }

    /// Fixed data, for previews, screenshots, and the `--demo` flag. Nothing
    /// on the machine is scanned or signalled.
    init(demo snapshot: StraysSnapshot) {
        catalog = .bundled
        store = nil
        monitor = nil
        stacks = DemoData.stacks
        stackStatuses = DemoData.stackStatuses
        self.snapshot = snapshot
        hasLoaded = true
        history = DemoData.history(for: snapshot)
    }

    var isDemo: Bool { monitor == nil }

    // MARK: - Derived views of the snapshot

    /// Everything, minus what the user chose to hide. Every list in the UI
    /// is built from this, so hiding something hides it everywhere.
    var strays: [Stray] {
        guard !showsHidden, !hideRules.isEmpty else { return snapshot.strays }
        return snapshot.strays.filter { !hideRules.hides($0) }
    }

    /// What the hide rules are currently hiding.
    var hiddenStrays: [Stray] {
        hideRules.isEmpty ? [] : snapshot.strays.filter { hideRules.hides($0) }
    }

    /// What a developer left running: dev processes, containers, services.
    /// These are counted in the menu bar and listed in the popover.
    var activeStrays: [Stray] {
        strays.filter { $0.isRunning && ($0.category == .dev || $0.category == .docker || $0.category == .brew) }
    }

    /// Apps and system daemons that listen on a port.
    var otherListeners: [Stray] { strays.filter { $0.category == .app || $0.category == .system } }

    /// Every container, running or not.
    var containers: [Stray] { strays.filter { $0.category == .docker } }

    /// Every Homebrew service, running or not.
    var brewServices: [Stray] { strays.filter { $0.category == .brew } }

    /// The number shown next to the menu bar icon.
    var badgeCount: Int { activeStrays.count }

    var lanVisibleCount: Int { activeStrays.filter(\.isLANVisible).count }

    /// Left behind by an agent session that has since exited.
    var orphanedStrays: [Stray] { strays.filter(\.origin.isOrphaned) }

    /// Running for hours and idle for the last half hour.
    var staleStrays: [Stray] { strays.filter(\.isStale) }

    /// Drives the dot on the menu bar icon.
    var needsAttention: Bool { strays.contains { $0.origin.isOrphaned || $0.isStale } }

    /// One entry per agent that is running or has left something behind,
    /// in the catalog's order.
    var detectedAgents: [DetectedAgent] {
        let byAgent = Dictionary(grouping: strays.filter { $0.origin.agentID != nil }) { $0.origin.agentID ?? "" }
        let sessions = Dictionary(grouping: snapshot.agentSessions, by: \.agentID)
        return catalog.agents.compactMap { profile in
            let strays = byAgent[profile.id] ?? []
            let sessionCount = sessions[profile.id]?.count ?? 0
            guard !strays.isEmpty || sessionCount > 0 else { return nil }
            return DetectedAgent(profile: profile, strays: strays, sessionCount: sessionCount)
        }
    }

    /// Active strays grouped by project, the most recently active first.
    /// Things without a project are grouped by what they are.
    var projectGroups: [StrayGroup] {
        var order: [String] = []
        var buckets: [String: [Stray]] = [:]
        for stray in activeStrays {
            let key = Self.groupKey(for: stray)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(stray)
        }
        return order.map { key in
            let strays = buckets[key] ?? []
            let project = strays.first?.project
            let (title, symbol) = Self.groupHeading(key: key, project: project)
            return StrayGroup(id: key, title: title, symbol: symbol, project: project, strays: strays)
        }
    }

    private static func groupKey(for stray: Stray) -> String {
        if let project = stray.project { return project.id }
        switch stray.category {
        case .docker: return "loose:docker"
        case .brew: return "loose:brew"
        default: return "loose:dev"
        }
    }

    private static func groupHeading(key: String, project: Project?) -> (title: String, symbol: String) {
        if let project { return (project.name, "folder.fill") }
        switch key {
        case "loose:docker": return ("Containers", "shippingbox.fill")
        case "loose:brew": return ("Homebrew services", "mug.fill")
        default: return ("No project", "questionmark.folder")
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
        history.record(snapshot)
        // Forget transient state for strays that are gone.
        let alive = Set(snapshot.strays.map(\.id))
        activity = activity.filter { alive.contains($0.key) }
        survivors = survivors.filter { alive.contains($0.key) }
        // Hidden things do not nag.
        notifier?.update(stale: snapshot.strays.filter { $0.isStale && !hideRules.hides($0) })
        refreshStackStatuses()
    }

    // MARK: - Notifications

    private func startNotifier() {
        let notifier = StaleNotifier()
        notifier.stop = { [weak self] ids in
            guard let self else { return }
            for stray in self.snapshot.strays where ids.contains(stray.id) {
                self.requestStop(stray)
            }
        }
        notifier.review = { [weak self] in
            self?.dashboardRequest = .filter(.stale)
            NSApp.activate(ignoringOtherApps: true)
        }
        self.notifier = notifier
    }

    /// Turns stale notifications on or off. Turning them on asks macOS for
    /// permission; returns false if it was refused.
    func setStaleNotifications(enabled: Bool) async -> Bool {
        guard enabled else {
            UserDefaults.standard.set(false, forKey: Preferences.Key.staleNotificationsEnabled)
            return true
        }
        let granted = await notifier?.requestAuthorization() ?? false
        UserDefaults.standard.set(granted, forKey: Preferences.Key.staleNotificationsEnabled)
        return granted
    }

    func setPackageNamePolicy(_ policy: ProjectResolver.PackageNamePolicy) {
        UserDefaults.standard.set(policy.rawValue, forKey: Preferences.Key.packageNamePolicy)
        guard let monitor else { return }
        Task {
            await monitor.setPackageNamePolicy(policy)
            await monitor.refresh()
        }
    }

    func setStaleThreshold(hours: Double) {
        UserDefaults.standard.set(hours, forKey: Preferences.Key.staleAfterHours)
        guard let monitor else { return }
        Task { await monitor.setStaleThreshold(hours: hours) }
    }

    private func updateCadence() {
        guard let monitor else { return }
        let isWatched = isPopoverVisible || isDashboardVisible
        let cadence: Monitor.Cadence = isAsleep ? .paused : isWatched ? .active : .background
        Task { await monitor.setCadence(cadence) }
        if !isWatched { setVisibleContainers([]) }
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

    /// Rows report when they scroll in and out of view, so that container
    /// stats, which cost a request each, are only fetched for what is shown.
    func setVisible(_ isVisible: Bool, _ stray: Stray) {
        guard let container = stray.container else { return }
        var next = visibleContainers
        if isVisible { next.insert(container.id) } else { next.remove(container.id) }
        setVisibleContainers(next)
    }

    private func setVisibleContainers(_ ids: Set<String>) {
        guard ids != visibleContainers, let monitor else { return }
        visibleContainers = ids
        Task { await monitor.setVisibleContainers(ids) }
    }

    // MARK: - Stopping

    /// Entry point for every Stop button.
    func requestStop(_ stray: Stray) {
        switch stray.kind {
        case .process:
            requestProcessStop(stray)
        case let .container(container):
            run(.stopping, on: stray, undo: .startContainer(id: container.id, name: container.name), success: "Stopped \(stray.title)") { monitor in
                try await monitor.perform(.stop, onContainer: container.id)
            }
        case let .brewService(service, _):
            run(.stopping, on: stray, undo: .startService(name: service.name), success: "Stopped \(stray.title)") { monitor in
                try await monitor.perform(.stop, onService: service.name)
            }
        }
    }

    /// Applies the safety policy before any signal is sent.
    private func requestProcessStop(_ stray: Stray) {
        guard let policy = stray.stopPolicy else { return }
        switch policy {
        case .allowed where stray.category == .app:
            // Stopping an app means quitting it, unsaved work and all.
            activity[stray.id] = .confirming(reason: "This quits \(stray.title).")
        case .allowed:
            stopProcess(stray)
        case let .needsConfirmation(reason):
            activity[stray.id] = .confirming(reason: reason)
        case let .needsPrivileges(command):
            activity[stray.id] = .needsPrivileges(command: command)
        case let .forbidden(reason):
            activity[stray.id] = .failed(reason)
        }
    }

    /// Called after the user confirmed stopping a macOS daemon or an app.
    func confirmStop(_ stray: Stray) {
        guard case .confirming = activity[stray.id] else { return }
        stopProcess(stray)
    }

    func dismissActivity(for stray: Stray) {
        activity[stray.id] = nil
        survivors[stray.id] = nil
    }

    private func stopProcess(_ stray: Stray) {
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

    // MARK: - Starting and restarting

    /// Starts a stopped container or Homebrew service.
    func start(_ stray: Stray) {
        switch stray.kind {
        case let .container(container):
            run(.starting, on: stray, success: "Started \(stray.title)") { monitor in
                try await monitor.perform(.start, onContainer: container.id)
            }
        case let .brewService(service, _):
            run(.starting, on: stray, success: "Started \(stray.title)") { monitor in
                try await monitor.perform(.start, onService: service.name)
            }
        case .process:
            break
        }
    }

    /// Restarts a container or a service properly. For a dev process this is
    /// experimental: it stops the tree, then runs the root's original
    /// command line again in its original working directory.
    func restart(_ stray: Stray) {
        switch stray.kind {
        case let .container(container):
            run(.restarting, on: stray, success: "Restarted \(stray.title)") { monitor in
                try await monitor.perform(.restart, onContainer: container.id)
            }
        case let .brewService(service, _):
            run(.restarting, on: stray, success: "Restarted \(stray.title)") { monitor in
                try await monitor.perform(.restart, onService: service.name)
            }
        case let .process(group):
            restartProcess(stray, group)
        }
    }

    private func restartProcess(_ stray: Stray, _ group: ProcessGroup) {
        guard let root = stray.signalRoot else { return }
        guard !isDemo else { return showToast("arrow.clockwise.circle", "Demo mode: nothing was restarted") }
        guard case .allowed = StopPolicy.evaluate(root) else { return requestStop(stray) }
        activity[stray.id] = .restarting

        let targets = controller.tree(of: root)
        guard !targets.isEmpty else {
            activity[stray.id] = nil
            return refresh()
        }
        Task {
            let result = await controller.stop(targets)
            guard result.survivors.isEmpty, !result.exited.isEmpty else {
                return finishStop(of: stray, with: result, forced: false)
            }
            activity[stray.id] = nil
            do {
                try ProcessLauncher.relaunch(group.root)
                showToast("arrow.clockwise.circle.fill", "Restarted \(stray.title)")
            } catch {
                showToast("exclamationmark.triangle.fill", "Stopped \(stray.title), but could not start it again")
            }
            refresh()
        }
    }

    // MARK: - Containers

    /// Removing a container deletes it, so it always asks first.
    func requestRemove(_ stray: Stray) {
        guard let container = stray.container else { return }
        activity[stray.id] = .confirmingRemoval(reason: container.isRunning
            ? "\(container.name) is running. Removing it stops it and deletes the container."
            : "This deletes the container \(container.name). Its image and volumes stay.")
    }

    func confirmRemove(_ stray: Stray) {
        guard case .confirmingRemoval = activity[stray.id], let container = stray.container else { return }
        run(.removing, on: stray, success: "Removed \(stray.title)") { monitor in
            try await monitor.perform(.remove(force: container.isRunning), onContainer: container.id)
        }
    }

    /// Stops every running container of a compose project in one go.
    func stopComposeProject(_ name: String) {
        guard let monitor else { return showToast("stop.circle", "Demo mode: nothing was stopped") }
        Task {
            do {
                try await monitor.stopComposeProject(name)
                showToast("checkmark.circle.fill", "Stopped compose project \(name)")
            } catch {
                showToast("exclamationmark.triangle.fill", "Could not stop \(name): \(Self.describe(error))")
            }
        }
    }

    /// The last lines of a container's output.
    func logs(for stray: Stray) async -> Result<String, Error> {
        guard let container = stray.container else { return .success("") }
        guard let monitor else { return .success(DemoData.logs) }
        do {
            return .success(try await monitor.containerLogs(id: container.id))
        } catch {
            return .failure(error)
        }
    }

    /// Runs a Docker or Homebrew action, showing progress on the row and
    /// the outcome in a toast or, on failure, inline.
    private func run(
        _ progress: StrayActivity,
        on stray: Stray,
        undo: Toast.Action? = nil,
        success: String,
        _ action: @escaping @Sendable (Monitor) async throws -> Void
    ) {
        guard let monitor else { return showToast("hand.raised", "Demo mode: nothing was changed") }
        activity[stray.id] = progress
        Task {
            do {
                try await action(monitor)
                activity[stray.id] = nil
                showToast("checkmark.circle.fill", success, action: undo)
            } catch {
                activity[stray.id] = .failed(Self.describe(error))
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DockerError.unavailable: "Docker is not running."
        case let DockerError.api(_, message): message.isEmpty ? "Docker refused the request." : message
        case BrewError.notInstalled: "Homebrew is not installed."
        case let BrewError.failed(message): message
        case SubprocessError.timedOut: "The command took too long to answer."
        case let StackError.missingDirectory(path): path.isEmpty ? "It has no folder to run in." : "The folder \((path as NSString).abbreviatingWithTildeInPath) does not exist."
        case let StackError.notFound(name): "\(name) does not exist on this Mac."
        case StackError.stillRunning: "It is still running after 5 seconds. Stop it from the list to force it."
        case StackError.dockerCommandNotFound: "Its containers do not exist yet, and the docker command was not found to create them."
        case let StackError.commandFailed(message): message.isEmpty ? "The command failed." : message
        default: error.localizedDescription
        }
    }

    // MARK: - Updates

    /// At most once a day, and only if the user has not turned it off.
    private func checkForUpdatesIfDue() {
        guard Preferences.checksForUpdates else { return }
        let last = UserDefaults.standard.double(forKey: Preferences.Key.lastUpdateCheck)
        guard Date().timeIntervalSince1970 - last > 24 * 3_600 else { return }
        checkForUpdates()
    }

    func checkForUpdates() {
        guard !isDemo, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        Task {
            availableUpdate = await UpdateChecker().update(newerThan: Preferences.appVersion)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Preferences.Key.lastUpdateCheck)
            isCheckingForUpdates = false
        }
    }

    func openUpdatePage() {
        guard let update = availableUpdate else { return }
        SystemActions.open(update.pageURL)
    }

    // MARK: - Stacks

    private func refreshStackStatuses() {
        guard let monitor, !stacks.isEmpty else { return }
        let stacks = stacks
        Task {
            var statuses: [UUID: StackItemStatus] = [:]
            for stack in stacks {
                statuses.merge(await monitor.statuses(of: stack)) { _, new in new }
            }
            stackStatuses = statuses
        }
    }

    func status(of item: StackItem) -> StackItemStatus {
        stackStatuses[item.id] ?? .stopped
    }

    @discardableResult
    func addStack(named name: String, items: [StackItem] = []) -> Stack {
        let stack = Stack(name: name, items: items)
        stacks.append(stack)
        saveStacks()
        return stack
    }

    func rename(_ stack: Stack, to name: String) {
        update(stack) { $0.name = name }
    }

    func delete(_ stack: Stack) {
        stacks.removeAll { $0.id == stack.id }
        saveStacks()
    }

    func add(_ item: StackItem, to stack: Stack) {
        update(stack) { stack in
            // The same thing twice would only be started and stopped twice.
            guard !stack.items.contains(where: { $0.kind == item.kind && $0.value == item.value && $0.directory == item.directory }) else { return }
            stack.items.append(item)
        }
    }

    func remove(_ item: StackItem, from stack: Stack) {
        update(stack) { $0.items.removeAll { $0.id == item.id } }
    }

    private func update(_ stack: Stack, _ change: (inout Stack) -> Void) {
        guard let index = stacks.firstIndex(where: { $0.id == stack.id }) else { return }
        change(&stacks[index])
        saveStacks()
    }

    private func saveStacks() {
        guard let store else { return }
        do {
            try store.save(stacks)
        } catch {
            showToast("exclamationmark.triangle.fill", "Could not save stacks: \(error.localizedDescription)")
        }
        refreshStackStatuses()
    }

    /// Starts everything in the stack that is not already up.
    func start(_ stack: Stack) {
        // A partly running compose project still has containers to start.
        for item in stack.items where status(of: item) != .running {
            start(item)
        }
    }

    /// Stops everything in the stack that is up.
    func stop(_ stack: Stack) {
        for item in stack.items where status(of: item).isRunning {
            stop(item)
        }
    }

    func start(_ item: StackItem) {
        perform(on: item, verb: "start") { monitor in try await monitor.start(item) }
    }

    func stop(_ item: StackItem) {
        perform(on: item, verb: "stop") { monitor in try await monitor.stop(item) }
    }

    private func perform(on item: StackItem, verb: String, _ action: @escaping @Sendable (Monitor) async throws -> Void) {
        guard let monitor else { return showToast("hand.raised", "Demo mode: nothing was changed") }
        guard !busyStackItems.contains(item.id) else { return }
        busyStackItems.insert(item.id)
        Task {
            do {
                try await action(monitor)
            } catch {
                showToast("exclamationmark.triangle.fill", "Could not \(verb) \(item.title): \(Self.describe(error))")
            }
            busyStackItems.remove(item.id)
            stackStatuses[item.id] = await monitor.status(of: item)
        }
    }

    // MARK: - Hiding

    func hide(_ rule: HideRule) {
        guard !hideRules.contains(where: { $0.kind == rule.kind && $0.value == rule.value }) else { return }
        hideRules.append(rule)
        saveHideRules()
        showToast("eye.slash.fill", "Hidden: \(rule.summary)")
    }

    func unhide(_ rule: HideRule) {
        hideRules.removeAll { $0.id == rule.id }
        saveHideRules()
    }

    private func saveHideRules() {
        try? store?.save(hideRules)
    }

    // MARK: - Toasts

    func showToast(_ symbol: String, _ message: String, action: Toast.Action? = nil) {
        toast = Toast(symbol: symbol, message: message, action: action)
        toastDismissal?.cancel()
        toastDismissal = Task { [weak self] in
            // An undo deserves longer than a plain notice.
            try? await Task.sleep(for: .seconds(action == nil ? 3.5 : 7))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// The toast's "Start Again" button.
    func performToastAction() {
        guard let action = toast?.action, let monitor else { return }
        toast = nil
        Task {
            do {
                switch action {
                case let .startContainer(id, name):
                    try await monitor.perform(.start, onContainer: id)
                    showToast("checkmark.circle.fill", "Started \(name)")
                case let .startService(name):
                    try await monitor.perform(.start, onService: name)
                    showToast("checkmark.circle.fill", "Started \(name)")
                }
            } catch {
                showToast("exclamationmark.triangle.fill", Self.describe(error))
            }
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

    func reveal(path: String) {
        SystemActions.revealInFinder(path)
    }

    /// The folder that "open in editor" and "terminal here" act on. A
    /// compose project that only exists as a label has no folder.
    func workingFolder(of stray: Stray) -> String? {
        let folder = stray.project?.rootPath ?? stray.processGroup?.root.cwd
        return folder.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    func openInEditor(_ stray: Stray) {
        guard let folder = workingFolder(of: stray) else { return }
        guard let editor = CodeEditor.preferred else {
            return showToast("questionmark.app", "No supported editor found (VS Code, Cursor, Zed, Xcode)")
        }
        SystemActions.open(folder: folder, with: editor)
    }

    func openTerminal(at stray: Stray) {
        guard let folder = stray.processGroup?.root.cwd ?? workingFolder(of: stray) else { return }
        SystemActions.openTerminal(at: folder)
    }
}
