import Foundation

/// A running agent process: one `claude`, one `codex`, and so on.
public struct AgentSession: Sendable, Equatable, Identifiable {
    public let agentID: String
    public let identity: ProcessIdentity
    /// Where the agent was started; the likely project of what it spawned.
    public let cwd: String?

    public init(agentID: String, identity: ProcessIdentity, cwd: String?) {
        self.agentID = agentID
        self.identity = identity
        self.cwd = cwd
    }

    public var id: ProcessIdentity { identity }
    public var pid: Int32 { identity.pid }
}

/// Decides where a process came from: an AI agent, a terminal, an IDE, or
/// nowhere we can tell. Pure: it only reads the facts it is handed.
public struct AttributionEngine: Sendable {
    /// What the engine needs to know about the rest of the machine.
    public struct Context: Sendable {
        public var table: ProcessTable
        /// Executable paths of our own processes.
        public var executablePaths: [Int32: String]
        /// Live agent processes, by PID.
        public var sessions: [Int32: AgentSession]
        /// Agent sessions seen earlier that have since exited, by PID.
        public var pastSessions: [Int32: AgentSession]

        public init(
            table: ProcessTable,
            executablePaths: [Int32: String] = [:],
            sessions: [Int32: AgentSession] = [:],
            pastSessions: [Int32: AgentSession] = [:]
        ) {
            self.table = table
            self.executablePaths = executablePaths
            self.sessions = sessions
            self.pastSessions = pastSessions
        }
    }

    public struct Result: Sendable, Equatable {
        public var origin: Origin
        /// The session responsible, when we know which one it was.
        public var session: AgentSession?

        public init(origin: Origin, session: AgentSession? = nil) {
            self.origin = origin
            self.session = session
        }
    }

    private struct CompiledMatcher: Sendable {
        let names: Set<String>
        let bundles: Set<String>
        let fragments: [String]
        let arguments: PatternSet

        init(_ matcher: ProcessMatcher) {
            names = Set(matcher.executableNames ?? [])
            bundles = Set(matcher.bundleNames ?? [])
            fragments = matcher.pathFragments ?? []
            arguments = PatternSet(matcher.argumentPatterns ?? [], homeDirectory: NSHomeDirectory())
        }

        /// By executable alone: cheap enough to run on every process.
        func matches(path: String?, name: String) -> Bool {
            let executable = path.map { ($0 as NSString).lastPathComponent } ?? name
            if names.contains(executable) { return true }
            guard let path else { return false }
            if fragments.contains(where: path.contains) { return true }
            if !bundles.isEmpty, let bundle = AppBundle.name(forExecutablePath: path), bundles.contains(bundle) { return true }
            return false
        }

        func matches(arguments list: [String]) -> Bool {
            !list.isEmpty && !arguments.isEmpty && arguments.matches(list.joined(separator: " "))
        }
    }

    public let catalog: AgentCatalog
    private let agents: [(profile: AgentProfile, matcher: CompiledMatcher)]
    private let terminals: [(profile: OriginProfile, matcher: CompiledMatcher)]
    private let ides: [(profile: OriginProfile, matcher: CompiledMatcher)]

    public init(catalog: AgentCatalog = .bundled) {
        self.catalog = catalog
        agents = catalog.agents.map { ($0, CompiledMatcher($0.ancestorMatchers)) }
        terminals = (catalog.terminals ?? []).map { ($0, CompiledMatcher($0.matchers)) }
        ides = (catalog.ides ?? []).map { ($0, CompiledMatcher($0.matchers)) }
    }

    // MARK: - Is this process an agent?

    /// The agent this executable is, judged by name and path only.
    public func agent(forExecutablePath path: String?, name: String) -> AgentProfile? {
        agents.first { $0.matcher.matches(path: path, name: name) }?.profile
    }

    /// The agent this process is, also considering its command line: Aider
    /// is `python … aider`, and older agents were `node …/cli.js`.
    public func agent(for details: ProcessDetails) -> AgentProfile? {
        agents.first {
            $0.matcher.matches(path: details.executablePath, name: details.entry.name)
                || $0.matcher.matches(arguments: details.arguments)
        }?.profile
    }

    /// The agent whose marker is present in this environment.
    public func agent(inEnvironment environment: [String: String]) -> AgentProfile? {
        guard !environment.isEmpty else { return nil }
        return catalog.agents.first { profile in
            profile.envMarkers.contains { $0.matches(environment) }
        }
    }

    // MARK: - Where did this process come from?

    /// 1. The nearest ancestor that is an agent wins.
    /// 2. Otherwise an agent's environment marker: the process was detached
    ///    from the agent, and is an orphan if that session is gone.
    /// 3. Otherwise the nearest terminal or IDE among its ancestors.
    /// 4. Otherwise unknown. A process is never hidden for lack of an origin.
    public func origin(of process: ProcessDetails, in context: Context) -> Result {
        let ancestors = context.table.ancestors(of: process.pid)

        for ancestor in ancestors {
            if let session = context.sessions[ancestor.pid] {
                return Result(origin: .agent(id: session.agentID, orphaned: false), session: session)
            }
        }

        if let profile = agent(inEnvironment: process.environment) {
            let session = liveSession(of: profile, for: process, in: context)
            return Result(
                origin: .agent(id: profile.id, orphaned: session == nil),
                session: session ?? pastSession(of: profile, for: process, in: context)
            )
        }

        for ancestor in ancestors {
            if let origin = fallbackOrigin(forExecutablePath: context.executablePaths[ancestor.pid], name: ancestor.name) {
                return Result(origin: origin)
            }
        }
        return Result(origin: .unknown)
    }

    /// The terminal or IDE this executable is, if the catalog lists it.
    public func fallbackOrigin(forExecutablePath path: String?, name: String) -> Origin? {
        if let terminal = terminals.first(where: { $0.matcher.matches(path: path, name: name) }) {
            return .terminal(name: terminal.profile.displayName)
        }
        if let ide = ides.first(where: { $0.matcher.matches(path: path, name: name) }) {
            return .ide(name: ide.profile.displayName)
        }
        return nil
    }

    /// The live session that started a detached process, if there is one.
    ///
    /// When the agent records its own PID in the environment we can be
    /// exact. Otherwise any session of the same agent that is older than the
    /// process could have started it, so the process gets the benefit of the
    /// doubt and is not called an orphan.
    private func liveSession(of profile: AgentProfile, for process: ProcessDetails, in context: Context) -> AgentSession? {
        let started = process.identity.startDate
        if let pid = sessionPID(of: profile, in: process.environment) {
            guard let session = context.sessions[pid], session.agentID == profile.id, session.identity.startDate <= started else {
                return nil
            }
            return session
        }
        return context.sessions.values
            .filter { $0.agentID == profile.id && $0.identity.startDate <= started }
            .max { $0.identity.startDate < $1.identity.startDate }
    }

    /// The exited session that started an orphan, if we saw it while it ran.
    private func pastSession(of profile: AgentProfile, for process: ProcessDetails, in context: Context) -> AgentSession? {
        guard let pid = sessionPID(of: profile, in: process.environment),
              let session = context.pastSessions[pid],
              session.agentID == profile.id,
              session.identity.startDate <= process.identity.startDate
        else { return nil }
        return session
    }

    private func sessionPID(of profile: AgentProfile, in environment: [String: String]) -> Int32? {
        profile.sessionPIDVariable.flatMap { environment[$0] }.flatMap(Int32.init)
    }
}
