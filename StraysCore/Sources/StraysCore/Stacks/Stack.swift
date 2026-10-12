import Foundation

/// One thing a stack starts and stops.
public struct StackItem: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A shell command run in a folder.
        case command
        /// Every container of a docker compose project.
        case composeProject
        case brewService
        /// One existing container, by name.
        case container
    }

    public var id: UUID
    public var kind: Kind
    /// The shell command, or the name of the compose project, Homebrew
    /// service, or container.
    public var value: String
    /// For a command: where to run it. For a compose project: the folder
    /// its compose file lives in.
    public var directory: String?

    public init(id: UUID = UUID(), kind: Kind, value: String, directory: String? = nil) {
        self.id = id
        self.kind = kind
        self.value = value
        self.directory = directory
    }

    public static func command(_ command: String, in directory: String) -> StackItem {
        StackItem(kind: .command, value: command, directory: directory)
    }

    public static func composeProject(_ name: String, directory: String? = nil) -> StackItem {
        StackItem(kind: .composeProject, value: name, directory: directory)
    }

    public static func brewService(_ name: String) -> StackItem {
        StackItem(kind: .brewService, value: name)
    }

    public static func container(_ name: String) -> StackItem {
        StackItem(kind: .container, value: name)
    }

    /// A stack item that would bring this stray back, if it can be described.
    public init?(recreating stray: Stray) {
        switch stray.kind {
        case let .container(container):
            if let compose = container.composeProject {
                self = .composeProject(compose, directory: container.composeWorkingDirectory)
            } else {
                self = .container(container.name)
            }
        case let .brewService(service, _):
            self = .brewService(service.name)
        case let .process(group):
            guard stray.category == .dev, !group.root.arguments.isEmpty, let cwd = group.root.cwd else { return nil }
            // Secrets on the command line are masked rather than written to
            // a plain-text file. The item then needs editing before it can
            // run, which is the lesser evil.
            let words = SecretMasker.maskArguments(group.root.arguments).map(Self.shellWord)
            self = .command(words.joined(separator: " "), in: cwd)
        }
    }

    /// Quotes an argument only when the shell would otherwise split it.
    private static func shellWord(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        guard argument.isEmpty || argument.unicodeScalars.contains(where: { !safe.contains($0) }) else { return argument }
        return ProcessLauncher.shellQuoted(argument)
    }
}

/// A named group of things that are started and stopped together:
/// "Shop local = API + worker + Redis + Postgres container".
public struct Stack: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var items: [StackItem]

    public init(id: UUID = UUID(), name: String, items: [StackItem] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

/// Whether a stack item is up.
public enum StackItemStatus: Sendable, Equatable {
    case running
    case stopped
    /// Some containers of a compose project are up and some are not.
    case partial(running: Int, total: Int)
    /// The container or service does not exist on this Mac.
    case missing

    public var isRunning: Bool {
        switch self {
        case .running, .partial: true
        case .stopped, .missing: false
        }
    }
}

/// What a user chose not to see.
public struct HideRule: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Anything listening on this port.
        case port
        /// Any process, container, or service with this name.
        case name
        /// Everything in this project, by root path.
        case project
    }

    public var id: UUID
    public var kind: Kind
    public var value: String

    public init(id: UUID = UUID(), kind: Kind, value: String) {
        self.id = id
        self.kind = kind
        self.value = value
    }

    public static func port(_ port: UInt16) -> HideRule { HideRule(kind: .port, value: String(port)) }
    public static func name(_ name: String) -> HideRule { HideRule(kind: .name, value: name) }
    public static func project(_ project: Project) -> HideRule { HideRule(kind: .project, value: project.rootPath) }

    public func matches(_ stray: Stray) -> Bool {
        switch kind {
        case .port:
            guard let port = UInt16(value) else { return false }
            return stray.ports.contains { $0.port == port }
        case .name:
            return stray.hideName == value
        case .project:
            return stray.project?.rootPath == value
        }
    }

    public var summary: String {
        switch kind {
        case .port: "Port \(value)"
        case .name: "Named “\(value)”"
        case .project: "Project \((value as NSString).lastPathComponent)"
        }
    }
}

extension Stray {
    /// The name a "hide by name" rule matches: the executable for a
    /// process, otherwise the container or service name.
    public var hideName: String {
        switch kind {
        case let .process(group): group.root.executableName
        case let .container(container): container.name
        case let .brewService(service, _): service.name
        }
    }
}

extension [HideRule] {
    public func hides(_ stray: Stray) -> Bool {
        contains { $0.matches(stray) }
    }
}

/// Reads and writes Strays' JSON files in Application Support.
public struct StackStore: Sendable {
    public let directory: URL

    public init(directory: URL = StraysDirectories.applicationSupport) {
        self.directory = directory
    }

    public var stacksURL: URL { directory.appendingPathComponent("stacks.json") }
    public var hideRulesURL: URL { directory.appendingPathComponent("hidden.json") }
    var launchedURL: URL { directory.appendingPathComponent("stack-processes.json") }

    public func loadStacks() -> [Stack] { load(stacksURL) ?? [] }
    public func save(_ stacks: [Stack]) throws { try write(stacks, to: stacksURL) }

    public func loadHideRules() -> [HideRule] { load(hideRulesURL) ?? [] }
    public func save(_ rules: [HideRule]) throws { try write(rules, to: hideRulesURL) }

    /// The processes Strays started for command items, by item id, so their
    /// status survives a relaunch.
    func loadLaunched() -> [UUID: ProcessIdentity] { load(launchedURL) ?? [:] }
    func save(launched: [UUID: ProcessIdentity]) { try? write(launched, to: launchedURL) }

    /// A missing or unreadable file is an empty list, never an error: a
    /// hand-edited file with a typo must not stop the app from starting.
    private func load<Value: Decodable>(_ url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
