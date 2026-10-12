import Foundation

public enum StackError: Error, Equatable {
    /// A command item has no folder to run in, or the folder is gone.
    case missingDirectory(String)
    /// The container or service the item names does not exist.
    case notFound(String)
    /// Stopped with SIGTERM, but something is still running.
    case stillRunning(String)
    /// Starting a compose project from nothing needs the docker command.
    case dockerCommandNotFound
    case commandFailed(String)
}

/// Works out whether stack items are up, from a snapshot. Pure.
public enum StackStatusResolver {
    public static func status(
        of item: StackItem,
        in snapshot: StraysSnapshot,
        launchedIsAlive: Bool = false
    ) -> StackItemStatus {
        switch item.kind {
        case .command:
            if launchedIsAlive { return .running }
            return matchingProcess(for: item, in: snapshot) == nil ? .stopped : .running
        case .composeProject:
            let containers = snapshot.strays.compactMap(\.container).filter { $0.composeProject == item.value }
            guard !containers.isEmpty else { return .missing }
            let running = containers.filter(\.isRunning).count
            if running == 0 { return .stopped }
            return running == containers.count ? .running : .partial(running: running, total: containers.count)
        case .container:
            guard let container = snapshot.strays.compactMap(\.container).first(where: { $0.name == item.value }) else { return .missing }
            return container.isRunning ? .running : .stopped
        case .brewService:
            guard let service = snapshot.strays.compactMap(\.brewService).first(where: { $0.name == item.value }) else { return .missing }
            return service.isRunning ? .running : .stopped
        }
    }

    /// A running dev process that looks like this command item: same folder,
    /// same command. Used when Strays did not start the process itself.
    public static func matchingProcess(for item: StackItem, in snapshot: StraysSnapshot) -> Stray? {
        guard item.kind == .command, let directory = item.directory else { return nil }
        let wanted = normalize(item.value)
        let folder = (directory as NSString).standardizingPath
        return snapshot.strays.first { stray in
            guard stray.category == .dev, let root = stray.processGroup?.root,
                  let cwd = root.cwd, (cwd as NSString).standardizingPath == folder
            else { return false }
            let line = normalize(root.arguments.joined(separator: " "))
            return stray.title == wanted || line == wanted || line.hasSuffix(" " + wanted) || line.hasSuffix("/" + wanted)
        }
    }

    private static func normalize(_ command: String) -> String {
        command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Finds the `docker` command, which lives in different places depending on
/// whether Docker Desktop, OrbStack, or Homebrew installed it.
public enum DockerCommandLocator {
    public static func candidates(home: String = NSHomeDirectory()) -> [String] {
        [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "\(home)/.docker/bin/docker",
            "\(home)/.orbstack/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
    }

    public static func locate(home: String = NSHomeDirectory()) -> String? {
        candidates(home: home).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

extension Monitor {
    // MARK: - Status

    public func status(of item: StackItem) -> StackItemStatus {
        StackStatusResolver.status(of: item, in: latest, launchedIsAlive: launchedIdentity(for: item) != nil)
    }

    public func statuses(of stack: Stack) -> [UUID: StackItemStatus] {
        Dictionary(uniqueKeysWithValues: stack.items.map { ($0.id, status(of: $0)) })
    }

    // MARK: - Starting

    /// Starts one item. Starting something that is already up does nothing.
    public func start(_ item: StackItem) async throws {
        switch item.kind {
        case .command:
            try startCommand(item)
            await refresh()
        case .composeProject:
            try await startComposeProject(item)
        case .container:
            guard let container = latest.strays.compactMap(\.container).first(where: { $0.name == item.value }) else {
                throw StackError.notFound(item.value)
            }
            if !container.isRunning { try await perform(.start, onContainer: container.id) }
        case .brewService:
            guard let service = latest.strays.compactMap(\.brewService).first(where: { $0.name == item.value }) else {
                throw StackError.notFound(item.value)
            }
            if !service.isRunning { try await perform(.start, onService: service.name) }
        }
    }

    private func startCommand(_ item: StackItem) throws {
        guard status(of: item) == .stopped else { return }
        guard let directory = item.directory, FileManager.default.fileExists(atPath: directory) else {
            throw StackError.missingDirectory(item.directory ?? "")
        }
        // A login, interactive shell, so the command sees the same PATH it
        // would in a terminal: node from nvm, python from pyenv, and so on.
        let environment = ProcessInfo.processInfo.environment
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let name = (shell as NSString).lastPathComponent
        let flags = name == "fish" ? ["-l", "-c"] : ["-l", "-i", "-c"]
        let pid = try ProcessLauncher.launch(
            executable: shell,
            arguments: [name] + flags + [item.value],
            cwd: directory,
            environment: environment
        )
        if let entry = LibProc.entry(for: pid) {
            rememberLaunched(entry.identity, for: item)
        }
    }

    /// Starts the project's existing containers through the Engine API. If
    /// it has none yet, `docker compose up -d` creates them, which needs
    /// the compose file's folder and the docker command.
    private func startComposeProject(_ item: StackItem) async throws {
        let containers = latest.strays.compactMap(\.container).filter { $0.composeProject == item.value }
        if !containers.isEmpty {
            for container in containers where !container.isRunning {
                try await perform(.start, onContainer: container.id)
            }
            return
        }
        guard let directory = item.directory, FileManager.default.fileExists(atPath: directory) else {
            throw StackError.missingDirectory(item.directory ?? "")
        }
        guard let docker = DockerCommandLocator.locate() else { throw StackError.dockerCommandNotFound }
        let result = try await Subprocess.run(docker, ["compose", "-p", item.value, "up", "-d"], cwd: directory, timeout: 600)
        guard result.succeeded else {
            throw StackError.commandFailed(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        await refresh()
    }

    // MARK: - Stopping

    public func stop(_ item: StackItem) async throws {
        switch item.kind {
        case .command:
            try await stopCommand(item)
            await refresh()
        case .composeProject:
            try await stopComposeProject(item.value)
        case .container:
            guard let container = latest.strays.compactMap(\.container).first(where: { $0.name == item.value }) else {
                throw StackError.notFound(item.value)
            }
            if container.isRunning { try await perform(.stop, onContainer: container.id) }
        case .brewService:
            guard let service = latest.strays.compactMap(\.brewService).first(where: { $0.name == item.value }) else {
                throw StackError.notFound(item.value)
            }
            if service.isRunning { try await perform(.stop, onService: service.name) }
        }
    }

    /// Stops what Strays launched for this item, or failing that the
    /// running process that matches it. Always the whole tree, and always
    /// through the same safety checks as any other Stop.
    private func stopCommand(_ item: StackItem) async throws {
        let controller = ProcessController()
        var root: SignalTarget?
        if let identity = launchedIdentity(for: item), let entry = LibProc.entry(for: identity.pid) {
            root = SignalTarget(identity: identity, name: entry.name, uid: entry.uid)
        } else if let stray = StackStatusResolver.matchingProcess(for: item, in: latest) {
            root = stray.signalRoot
        }
        guard let root else { return }

        let result = await controller.stop(controller.tree(of: root))
        guard result.survivors.isEmpty else { throw StackError.stillRunning(item.value) }
        forgetLaunched(for: item)
    }
}
