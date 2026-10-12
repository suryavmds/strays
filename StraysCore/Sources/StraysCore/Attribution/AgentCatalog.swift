import Foundation

/// How to recognise a process: by name, by the app it belongs to, by where
/// its executable lives, or by its command line.
public struct ProcessMatcher: Codable, Sendable, Equatable {
    /// Exact executable basenames. Case-sensitive: `claude` is the agent,
    /// `Claude` is the desktop app.
    public var executableNames: [String]?
    /// Names of the outermost `.app` bundle, without the extension.
    public var bundleNames: [String]?
    /// Substrings of the executable path.
    public var pathFragments: [String]?
    /// Regular expressions matched against the whole command line.
    public var argumentPatterns: [String]?

    public init(
        executableNames: [String]? = nil,
        bundleNames: [String]? = nil,
        pathFragments: [String]? = nil,
        argumentPatterns: [String]? = nil
    ) {
        self.executableNames = executableNames
        self.bundleNames = bundleNames
        self.pathFragments = pathFragments
        self.argumentPatterns = argumentPatterns
    }
}

/// An environment variable an agent sets in the shells it spawns.
public struct EnvMarker: Codable, Sendable, Equatable {
    public var name: String
    /// When set, the variable must have exactly this value.
    public var value: String?
    /// When set, the variable's value must start with this.
    public var valuePrefix: String?
    /// When, where, and how this marker was observed. Documentation only.
    public var verified: String?

    public init(name: String, value: String? = nil, valuePrefix: String? = nil, verified: String? = nil) {
        self.name = name
        self.value = value
        self.valuePrefix = valuePrefix
        self.verified = verified
    }

    public func matches(_ environment: [String: String]) -> Bool {
        guard let actual = environment[name] else { return false }
        if let value, actual != value { return false }
        if let valuePrefix, !actual.hasPrefix(valuePrefix) { return false }
        return true
    }
}

/// One AI coding agent.
public struct AgentProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    /// `#RRGGBB`.
    public var badgeColor: String
    /// An SF Symbol name.
    public var icon: String
    public var ancestorMatchers: ProcessMatcher
    public var envMarkers: [EnvMarker]
    /// An environment variable holding the PID of the agent process that
    /// spawned the shell, if the agent sets one. It lets Strays tell a
    /// detached process whose session is alive from a real orphan.
    public var sessionPIDVariable: String?
    /// Believed but unconfirmed markers. Never used for matching.
    public var unverifiedEnvMarkers: [String]?
    public var notes: String?

    public init(
        id: String,
        displayName: String,
        badgeColor: String = "#8E8E93",
        icon: String = "sparkle",
        ancestorMatchers: ProcessMatcher = ProcessMatcher(),
        envMarkers: [EnvMarker] = [],
        sessionPIDVariable: String? = nil,
        unverifiedEnvMarkers: [String]? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.badgeColor = badgeColor
        self.icon = icon
        self.ancestorMatchers = ancestorMatchers
        self.envMarkers = envMarkers
        self.sessionPIDVariable = sessionPIDVariable
        self.unverifiedEnvMarkers = unverifiedEnvMarkers
        self.notes = notes
    }
}

/// A terminal or an IDE: where a process came from when no agent started it.
public struct OriginProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var matchers: ProcessMatcher

    public init(id: String, displayName: String, matchers: ProcessMatcher) {
        self.id = id
        self.displayName = displayName
        self.matchers = matchers
    }
}

/// The contents of `agents.json`.
public struct AgentCatalog: Codable, Sendable, Equatable {
    public var version: Int
    public var notes: [String]?
    public var agents: [AgentProfile]
    public var terminals: [OriginProfile]?
    public var ides: [OriginProfile]?

    public init(version: Int = 1, agents: [AgentProfile], terminals: [OriginProfile]? = nil, ides: [OriginProfile]? = nil) {
        self.version = version
        self.agents = agents
        self.terminals = terminals
        self.ides = ides
    }

    public static let overrideFileName = "agents.json"

    /// The catalog shipped inside StraysCore.
    public static let bundled: AgentCatalog = {
        guard let url = Bundle.module.url(forResource: "agents", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(AgentCatalog.self, from: data)
        else {
            assertionFailure("agents.json is missing or malformed")
            return AgentCatalog(agents: [])
        }
        return catalog
    }()

    /// `~/Library/Application Support/Strays/agents.json`.
    public static var defaultOverrideURL: URL {
        StraysDirectories.applicationSupport.appendingPathComponent(overrideFileName)
    }

    /// The bundled catalog with the user's override file applied, if there
    /// is one and it parses. A broken override is ignored, never fatal.
    public static func load(overrideAt url: URL = defaultOverrideURL) -> AgentCatalog {
        guard let data = try? Data(contentsOf: url),
              let override = try? JSONDecoder().decode(AgentCatalog.self, from: data)
        else { return bundled }
        return bundled.merging(override)
    }

    /// Entries in `override` replace bundled ones with the same id; new ones
    /// are appended. Overriding agents come first so they match first.
    public func merging(_ override: AgentCatalog) -> AgentCatalog {
        var merged = self
        merged.agents = Self.merge(agents, override.agents)
        merged.terminals = Self.merge(terminals ?? [], override.terminals ?? [])
        merged.ides = Self.merge(ides ?? [], override.ides ?? [])
        return merged
    }

    private static func merge<Profile: Identifiable>(_ base: [Profile], _ override: [Profile]) -> [Profile] where Profile.ID == String {
        let replaced = Set(override.map(\.id))
        return override + base.filter { !replaced.contains($0.id) }
    }

    public func agent(withID id: String) -> AgentProfile? {
        agents.first { $0.id == id }
    }
}

/// Where Strays keeps its files.
public enum StraysDirectories {
    /// `~/Library/Application Support/Strays`. Not created until written to.
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Strays", isDirectory: true)
    }
}
