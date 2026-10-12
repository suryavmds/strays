import Foundation

/// Everything Strays can say about one PID and where it came from. Used by
/// `strays inspect`, which is how new agent markers get verified.
public struct ProcessInspection: Sendable {
    public struct Ancestor: Sendable {
        public let entry: ProcessEntry
        public let executablePath: String?
        /// "agent: Claude Code", "terminal: iTerm2", or nil.
        public let role: String?
    }

    public let details: ProcessDetails
    /// Nearest first.
    public let ancestors: [Ancestor]
    public let origin: Origin
    public let session: AgentSession?
    /// Environment variables whose names suggest an AI agent set them.
    /// Candidates for `envMarkers`, to be confirmed by a human.
    public let candidateMarkers: [String: String]
}

extension AttributionEngine {
    private static let agentishName = try! NSRegularExpression(
        pattern: "agent|claude|anthropic|codex|openai|gemini|aider|cursor|copilot|windsurf|cline|amp_|opencode|goose",
        options: .caseInsensitive
    )

    /// Variables worth a look when hunting for an agent's marker.
    public static func candidateMarkers(in environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in
            agentishName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
    }

    /// What an ancestor is, if the catalog knows it.
    public func role(forExecutablePath path: String?, name: String) -> String? {
        if let agent = agent(forExecutablePath: path, name: name) { return "agent: \(agent.displayName)" }
        switch fallbackOrigin(forExecutablePath: path, name: name) {
        case let .terminal(name): return "terminal: \(name)"
        case let .ide(name): return "IDE: \(name)"
        default: return nil
        }
    }
}

extension Monitor {
    /// Inspects one process the way a scan would, without waiting for one.
    public func inspect(pid: Int32) async -> ProcessInspection? {
        let table = (try? await ProcessTableCollector().collect()) ?? ProcessTable(entries: [])
        guard let entry = table[pid] else { return nil }
        return await inspect(entry, in: table)
    }
}
