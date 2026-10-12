import XCTest
@testable import StraysCore

final class AgentCatalogTests: XCTestCase {
    func testBundledCatalogHasEveryBuiltInAgent() {
        let catalog = AgentCatalog.bundled
        XCTAssertEqual(catalog.agents.map(\.id), ["claude-code", "codex", "gemini-cli", "aider", "cursor-agent"])
        for agent in catalog.agents {
            XCTAssertFalse(agent.displayName.isEmpty, agent.id)
            XCTAssertTrue(agent.badgeColor.hasPrefix("#") && agent.badgeColor.count == 7, "\(agent.id): \(agent.badgeColor)")
            XCTAssertFalse(agent.icon.isEmpty, agent.id)
            let matcher = agent.ancestorMatchers
            XCTAssertFalse((matcher.executableNames ?? []).isEmpty && (matcher.argumentPatterns ?? []).isEmpty, "\(agent.id) has no way to be recognised")
        }
        XCTAssertFalse((catalog.terminals ?? []).isEmpty)
        XCTAssertFalse((catalog.ides ?? []).isEmpty)
    }

    /// The project rule: no environment marker ships unless someone saw it.
    func testEveryShippedEnvMarkerSaysHowItWasVerified() {
        for agent in AgentCatalog.bundled.agents {
            for marker in agent.envMarkers {
                XCTAssertFalse((marker.verified ?? "").isEmpty, "\(agent.id): \(marker.name) has no verification note")
            }
        }
    }

    func testEveryArgumentPatternCompiles() {
        for agent in AgentCatalog.bundled.agents {
            for pattern in agent.ancestorMatchers.argumentPatterns ?? [] {
                XCTAssertNoThrow(try NSRegularExpression(pattern: pattern), "\(agent.id): \(pattern)")
            }
        }
    }

    func testClaudeCodeMarkersAreTheVerifiedOnes() throws {
        let claude = try XCTUnwrap(AgentCatalog.bundled.agent(withID: "claude-code"))
        XCTAssertEqual(claude.envMarkers.map(\.name), ["CLAUDECODE", "AI_AGENT"])
        XCTAssertEqual(claude.sessionPIDVariable, "CLAUDE_PID")
    }

    func testEnvMarkerMatching() {
        let exact = EnvMarker(name: "CLAUDECODE", value: "1")
        XCTAssertTrue(exact.matches(["CLAUDECODE": "1"]))
        XCTAssertFalse(exact.matches(["CLAUDECODE": "0"]))
        XCTAssertFalse(exact.matches(["OTHER": "1"]))

        let prefix = EnvMarker(name: "AI_AGENT", valuePrefix: "claude-code")
        XCTAssertTrue(prefix.matches(["AI_AGENT": "claude-code_2-1-283_agent"]))
        XCTAssertFalse(prefix.matches(["AI_AGENT": "some-other-agent"]))

        let nameOnly = EnvMarker(name: "CODEX_SANDBOX")
        XCTAssertTrue(nameOnly.matches(["CODEX_SANDBOX": ""]))
        XCTAssertFalse(nameOnly.matches([:]))
    }

    func testOverrideReplacesByIDAndAppendsNewAgents() {
        let base = AgentCatalog(
            agents: [AgentProfile(id: "a", displayName: "A"), AgentProfile(id: "b", displayName: "B")],
            terminals: [OriginProfile(id: "t", displayName: "T", matchers: ProcessMatcher())]
        )
        let override = AgentCatalog(agents: [AgentProfile(id: "b", displayName: "B2"), AgentProfile(id: "c", displayName: "C")])
        let merged = base.merging(override)
        XCTAssertEqual(merged.agents.map(\.displayName), ["B2", "C", "A"], "overrides come first so they match first")
        XCTAssertEqual(merged.terminals?.map(\.id), ["t"])
    }

    func testLoadAppliesAValidOverrideFileAndIgnoresABrokenOne() throws {
        let directory = try TemporaryDirectory()
        let missing = directory.url.appendingPathComponent("missing.json")
        XCTAssertEqual(AgentCatalog.load(overrideAt: missing), .bundled)

        let broken = try directory.write("{ not json", to: "broken.json")
        XCTAssertEqual(AgentCatalog.load(overrideAt: broken), .bundled)

        let valid = try directory.write(
            ##"{"version": 1, "agents": [{"id": "my-agent", "displayName": "My Agent", "badgeColor": "#FF00FF", "icon": "bolt", "ancestorMatchers": {"executableNames": ["myagent"]}, "envMarkers": [{"name": "MY_AGENT", "verified": "locally"}]}]}"##,
            to: "agents.json"
        )
        let loaded = AgentCatalog.load(overrideAt: valid)
        XCTAssertEqual(loaded.agents.first?.id, "my-agent")
        XCTAssertEqual(loaded.agents.count, AgentCatalog.bundled.agents.count + 1)
        XCTAssertNotNil(loaded.agent(withID: "claude-code"))
    }

    func testOverrideLivesInApplicationSupport() {
        XCTAssertTrue(AgentCatalog.defaultOverrideURL.path.hasSuffix("/Library/Application Support/Strays/agents.json"))
    }
}

final class AttributionEngineTests: XCTestCase {
    private let engine = AttributionEngine(catalog: .bundled)

    // MARK: - Recognising agents

    func testRecognisesClaudeCodeInItsRealLocations() {
        // Both paths were observed on a real machine on 2026-10-12.
        let desktop = "/Users/me/Library/Application Support/Claude/claude-code/2.1.295/9d6405864fdc/claude.app/Contents/MacOS/claude"
        let npm = "/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
        XCTAssertEqual(engine.agent(forExecutablePath: desktop, name: "claude")?.id, "claude-code")
        XCTAssertEqual(engine.agent(forExecutablePath: npm, name: "claude.exe")?.id, "claude-code")
        XCTAssertEqual(engine.agent(forExecutablePath: "/Users/me/.local/bin/claude", name: "claude")?.id, "claude-code")
    }

    func testTheClaudeDesktopAppItselfIsNotTheAgent() {
        XCTAssertNil(engine.agent(forExecutablePath: "/Applications/Claude.app/Contents/MacOS/Claude", name: "Claude"))
        XCTAssertNil(engine.agent(forExecutablePath: "/Applications/Claude.app/Contents/Helpers/disclaimer", name: "disclaimer"))
    }

    func testRecognisesTheOtherAgentsByExecutable() {
        XCTAssertEqual(engine.agent(forExecutablePath: "/opt/homebrew/bin/codex", name: "codex")?.id, "codex")
        XCTAssertEqual(engine.agent(forExecutablePath: "/usr/local/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex", name: "codex")?.id, "codex")
        XCTAssertEqual(engine.agent(forExecutablePath: "/Users/me/.local/bin/cursor-agent", name: "cursor-agent")?.id, "cursor-agent")
        XCTAssertEqual(engine.agent(forExecutablePath: "/opt/homebrew/bin/aider", name: "aider")?.id, "aider")
        XCTAssertNil(engine.agent(forExecutablePath: "/usr/local/bin/node", name: "node"))
        XCTAssertNil(engine.agent(forExecutablePath: nil, name: "zsh"))
    }

    func testRecognisesInterpretedAgentsByCommandLine() {
        func agent(_ path: String, _ arguments: [String]) -> String? {
            engine.agent(for: makeDetails(makeEntry(1, name: (path as NSString).lastPathComponent), path: path, arguments: arguments))?.id
        }
        XCTAssertEqual(agent("/usr/local/bin/node", ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), "claude-code")
        XCTAssertEqual(agent("/usr/local/bin/node", ["node", "/opt/homebrew/bin/gemini"]), "gemini-cli")
        XCTAssertEqual(agent("/usr/local/bin/node", ["node", "/usr/local/lib/node_modules/@google/gemini-cli/dist/index.js"]), "gemini-cli")
        XCTAssertEqual(agent("/opt/homebrew/bin/python3.12", ["/Users/me/.venv/bin/python", "/Users/me/.venv/bin/aider", "--model", "sonnet"]), "aider")
        XCTAssertEqual(agent("/opt/homebrew/bin/python3.12", ["python", "-m", "aider"]), "aider")
        XCTAssertNil(agent("/usr/local/bin/node", ["node", "server.js"]))
        XCTAssertNil(agent("/opt/homebrew/bin/python3.12", ["python", "train.py", "--model", "codex"]), "a word in the arguments is not the program")
    }

    func testCursorEditorHelpersAreAnIDENotTheAgent() {
        let helper = "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"
        XCTAssertNil(engine.agent(forExecutablePath: helper, name: "Cursor Helper (Plu"))
        XCTAssertEqual(engine.fallbackOrigin(forExecutablePath: helper, name: "Cursor Helper (Plu"), .ide(name: "Cursor"))
    }

    func testEnvironmentMarkers() {
        XCTAssertEqual(engine.agent(inEnvironment: ["CLAUDECODE": "1", "PATH": "/bin"])?.id, "claude-code")
        XCTAssertEqual(engine.agent(inEnvironment: ["AI_AGENT": "claude-code_2-1-283_agent"])?.id, "claude-code")
        XCTAssertNil(engine.agent(inEnvironment: ["CLAUDECODE": "0"]))
        XCTAssertNil(engine.agent(inEnvironment: [:]))
        // Unverified markers must never match.
        XCTAssertNil(engine.agent(inEnvironment: ["CODEX_SANDBOX": "seatbelt", "GEMINI_CLI": "1", "CURSOR_AGENT": "1"]))
    }

    // MARK: - Origins

    private func session(_ agent: String, pid: Int32, start: UInt64, cwd: String? = nil) -> AgentSession {
        AgentSession(agentID: agent, identity: ProcessIdentity(pid: pid, startSeconds: start, startMicroseconds: 0), cwd: cwd)
    }

    private func context(
        _ entries: [ProcessEntry],
        paths: [Int32: String] = [:],
        sessions: [AgentSession] = [],
        past: [AgentSession] = []
    ) -> AttributionEngine.Context {
        .init(
            table: ProcessTable(entries: entries),
            executablePaths: paths,
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0) }),
            pastSessions: Dictionary(uniqueKeysWithValues: past.map { ($0.pid, $0) })
        )
    }

    func testAncestorThatIsAnAgentWins() {
        let entries = [
            makeEntry(1, parent: 0, name: "launchd"),
            makeEntry(10, parent: 1, name: "iTerm2"),
            makeEntry(20, parent: 10, name: "claude", start: 100),
            makeEntry(30, parent: 20, name: "zsh"),
            makeEntry(40, parent: 30, name: "node", start: 200),
        ]
        let claude = session("claude-code", pid: 20, start: 100, cwd: "/Users/me/shop")
        let result = engine.origin(
            of: makeDetails(entries[4]),
            in: context(entries, paths: [10: "/Applications/iTerm.app/Contents/MacOS/iTerm2"], sessions: [claude])
        )
        XCTAssertEqual(result.origin, .agent(id: "claude-code", orphaned: false), "the agent, not the terminal it runs in")
        XCTAssertEqual(result.session, claude)
    }

    func testNearestAgentAncestorWinsWhenAgentsAreNested() {
        let entries = [
            makeEntry(20, parent: 1, name: "claude", start: 100),
            makeEntry(25, parent: 20, name: "codex", start: 150),
            makeEntry(40, parent: 25, name: "node", start: 200),
        ]
        let result = engine.origin(
            of: makeDetails(entries[2]),
            in: context(entries, sessions: [session("claude-code", pid: 20, start: 100), session("codex", pid: 25, start: 150)])
        )
        XCTAssertEqual(result.origin, .agent(id: "codex", orphaned: false))
    }

    func testAncestorMatchBeatsAnEnvironmentMarkerOfAnotherAgent() {
        // Started by Codex, from a shell that had been launched by Claude Code.
        let entries = [makeEntry(25, parent: 1, name: "codex", start: 150), makeEntry(40, parent: 25, name: "node", start: 200)]
        let result = engine.origin(
            of: makeDetails(entries[1], environment: ["CLAUDECODE": "1"]),
            in: context(entries, sessions: [session("codex", pid: 25, start: 150)])
        )
        XCTAssertEqual(result.origin, .agent(id: "codex", orphaned: false))
    }

    func testDetachedProcessWhoseSessionIsAliveIsNotAnOrphan() {
        // `npm run dev &`: the shell exited, launchd adopted the server, and
        // the agent session named in its environment is still running.
        let entries = [makeEntry(20, parent: 10, name: "claude", start: 100), makeEntry(40, parent: 1, name: "node", start: 200)]
        let claude = session("claude-code", pid: 20, start: 100)
        let result = engine.origin(
            of: makeDetails(entries[1], environment: ["CLAUDECODE": "1", "CLAUDE_PID": "20"]),
            in: context(entries, sessions: [claude])
        )
        XCTAssertEqual(result.origin, .agent(id: "claude-code", orphaned: false))
        XCTAssertEqual(result.session, claude)
    }

    func testProcessWhoseSessionHasExitedIsAnOrphan() {
        let entries = [makeEntry(40, parent: 1, name: "node", start: 200)]
        let result = engine.origin(
            of: makeDetails(entries[0], environment: ["CLAUDECODE": "1", "CLAUDE_PID": "20"]),
            in: context(entries)
        )
        XCTAssertEqual(result.origin, .agent(id: "claude-code", orphaned: true))
        XCTAssertNil(result.session)
    }

    func testAnotherLiveSessionOfTheSameAgentDoesNotRescueAnOrphan() {
        // A different Claude Code session is open; ours (PID 20) is gone.
        let entries = [makeEntry(77, parent: 1, name: "claude", start: 50), makeEntry(40, parent: 1, name: "node", start: 200)]
        let result = engine.origin(
            of: makeDetails(entries[1], environment: ["CLAUDECODE": "1", "CLAUDE_PID": "20"]),
            in: context(entries, sessions: [session("claude-code", pid: 77, start: 50)])
        )
        XCTAssertEqual(result.origin, .agent(id: "claude-code", orphaned: true))
    }

    func testSessionPIDReusedByALaterSessionIsStillAnOrphan() {
        // PID 20 belongs to a session that started after the process did,
        // so it cannot be the one that spawned it.
        let entries = [makeEntry(20, parent: 1, name: "claude", start: 900), makeEntry(40, parent: 1, name: "node", start: 200)]
        let result = engine.origin(
            of: makeDetails(entries[1], environment: ["CLAUDECODE": "1", "CLAUDE_PID": "20"]),
            in: context(entries, sessions: [session("claude-code", pid: 20, start: 900)])
        )
        XCTAssertEqual(result.origin, .agent(id: "claude-code", orphaned: true))
    }

    func testOrphanRemembersTheSessionItCameFrom() {
        let entries = [makeEntry(40, parent: 1, name: "node", start: 200)]
        let gone = session("claude-code", pid: 20, start: 100, cwd: "/Users/me/shop")
        let result = engine.origin(
            of: makeDetails(entries[0], environment: ["CLAUDECODE": "1", "CLAUDE_PID": "20"]),
            in: context(entries, past: [gone])
        )
        XCTAssertEqual(result.origin, .agent(id: "claude-code", orphaned: true))
        XCTAssertEqual(result.session, gone, "so the orphan can be filed under that session's project")
    }

    func testWithoutASessionPIDAnOlderLiveSessionGetsTheBenefitOfTheDoubt() {
        let catalog = AgentCatalog(agents: [AgentProfile(id: "x", displayName: "X", envMarkers: [EnvMarker(name: "X_AGENT")])])
        let engine = AttributionEngine(catalog: catalog)
        let entries = [makeEntry(40, parent: 1, name: "node", start: 200)]
        let process = makeDetails(entries[0], environment: ["X_AGENT": "1"])

        let older = engine.origin(of: process, in: context(entries, sessions: [session("x", pid: 5, start: 100)]))
        XCTAssertEqual(older.origin, .agent(id: "x", orphaned: false))

        let newerOnly = engine.origin(of: process, in: context(entries, sessions: [session("x", pid: 5, start: 500)]))
        XCTAssertEqual(newerOnly.origin, .agent(id: "x", orphaned: true), "a session younger than the process did not start it")

        let none = engine.origin(of: process, in: context(entries))
        XCTAssertEqual(none.origin, .agent(id: "x", orphaned: true))
    }

    func testFallsBackToTheNearestTerminalOrIDE() {
        let entries = [
            makeEntry(1, parent: 0, name: "launchd"),
            makeEntry(10, parent: 1, name: "Electron"),
            makeEntry(11, parent: 10, name: "Code Helper"),
            makeEntry(12, parent: 11, name: "tmux"),
            makeEntry(13, parent: 12, name: "zsh"),
            makeEntry(14, parent: 13, name: "node"),
            makeEntry(20, parent: 1, name: "Terminal"),
            makeEntry(21, parent: 20, name: "login", uid: 0),
            makeEntry(22, parent: 21, name: "zsh"),
            makeEntry(23, parent: 22, name: "python3"),
        ]
        let paths: [Int32: String] = [
            10: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
            11: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
            12: "/opt/homebrew/bin/tmux",
            20: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        ]
        let table = context(entries, paths: paths)
        XCTAssertEqual(engine.origin(of: makeDetails(entries[5]), in: table).origin, .terminal(name: "tmux"), "nearest first")
        XCTAssertEqual(engine.origin(of: makeDetails(entries[9]), in: table).origin, .terminal(name: "Terminal"), "through root-owned login")
        XCTAssertEqual(engine.origin(of: makeDetails(entries[3]), in: table).origin, .ide(name: "VS Code"))
    }

    func testUnknownWhenNothingMatches() {
        let entries = [makeEntry(1, parent: 0, name: "launchd"), makeEntry(40, parent: 1, name: "node")]
        XCTAssertEqual(engine.origin(of: makeDetails(entries[1]), in: context(entries)).origin, .unknown)
        XCTAssertTrue(Origin.unknown.isUnknown)
        XCTAssertFalse(Origin.unknown.isOrphaned)
    }

    func testCandidateMarkersAndRoles() {
        let candidates = AttributionEngine.candidateMarkers(in: ["CLAUDECODE": "1", "CODEX_SANDBOX": "x", "PATH": "/bin", "AI_AGENT": "y", "HOME": "/Users/me"])
        XCTAssertEqual(Set(candidates.keys), ["CLAUDECODE", "CODEX_SANDBOX", "AI_AGENT"])
        XCTAssertEqual(engine.role(forExecutablePath: "/opt/homebrew/bin/codex", name: "codex"), "agent: Codex")
        XCTAssertEqual(engine.role(forExecutablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty", name: "ghostty"), "terminal: Ghostty")
        XCTAssertEqual(engine.role(forExecutablePath: "/Applications/Zed.app/Contents/MacOS/zed", name: "zed"), "IDE: Zed")
        XCTAssertNil(engine.role(forExecutablePath: "/bin/zsh", name: "zsh"))
    }
}

final class StaleTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func stray(_ id: String, ageHours: Double, cpu: Double = 0, category: Stray.Category = .dev, running: Bool = true, at now: Date) -> Stray {
        Stray(
            id: id,
            kind: .process(ProcessGroup(root: makeDetails(makeEntry(1)))),
            category: category,
            title: id,
            startedAt: now.addingTimeInterval(-ageHours * 3_600),
            cpuPercent: cpu,
            isRunning: running
        )
    }

    func testOldAndIdleForTheWholeWindowIsStale() {
        var tracker = StaleTracker(staleAfter: 6 * 3_600, idleWindow: 30 * 60)
        XCTAssertTrue(tracker.update(with: [stray("a", ageHours: 8, at: start)], now: start).isEmpty, "not until we have watched it idle")
        let later = start.addingTimeInterval(29 * 60)
        XCTAssertTrue(tracker.update(with: [stray("a", ageHours: 8.5, at: later)], now: later).isEmpty)
        let enough = start.addingTimeInterval(31 * 60)
        XCTAssertEqual(tracker.update(with: [stray("a", ageHours: 8.5, at: enough)], now: enough), ["a"])
    }

    func testYoungProcessesAreNeverStale() {
        var tracker = StaleTracker(staleAfter: 6 * 3_600, idleWindow: 60)
        _ = tracker.update(with: [stray("a", ageHours: 1, at: start)], now: start)
        let later = start.addingTimeInterval(3_600)
        XCTAssertTrue(tracker.update(with: [stray("a", ageHours: 2, at: later)], now: later).isEmpty)
    }

    func testActivityResetsTheIdleClock() {
        var tracker = StaleTracker(staleAfter: 3_600, idleWindow: 30 * 60)
        _ = tracker.update(with: [stray("a", ageHours: 5, at: start)], now: start)
        let busy = start.addingTimeInterval(25 * 60)
        _ = tracker.update(with: [stray("a", ageHours: 5.4, cpu: 40, at: busy)], now: busy)
        let soonAfter = start.addingTimeInterval(40 * 60)
        XCTAssertTrue(tracker.update(with: [stray("a", ageHours: 5.6, at: soonAfter)], now: soonAfter).isEmpty)
        let longAfter = start.addingTimeInterval(56 * 60)
        XCTAssertEqual(tracker.update(with: [stray("a", ageHours: 5.9, at: longAfter)], now: longAfter), ["a"])
    }

    func testCPUBelowTheThresholdDoesNotCountAsActivity() {
        var tracker = StaleTracker(staleAfter: 3_600, idleWindow: 60, busyThreshold: 1)
        _ = tracker.update(with: [stray("a", ageHours: 5, cpu: 0.4, at: start)], now: start)
        let later = start.addingTimeInterval(120)
        XCTAssertEqual(tracker.update(with: [stray("a", ageHours: 5, cpu: 0.4, at: later)], now: later), ["a"])
    }

    func testContainersServicesAppsAndStoppedThingsAreNeverStale() {
        var tracker = StaleTracker(staleAfter: 3_600, idleWindow: 60)
        func all(at now: Date) -> [Stray] {
            [
                stray("docker", ageHours: 99, category: .docker, at: now),
                stray("brew", ageHours: 99, category: .brew, at: now),
                stray("app", ageHours: 99, category: .app, at: now),
                stray("stopped", ageHours: 99, running: false, at: now),
            ]
        }
        _ = tracker.update(with: all(at: start), now: start)
        let later = start.addingTimeInterval(3_600)
        XCTAssertTrue(tracker.update(with: all(at: later), now: later).isEmpty)
    }

    func testAProcessThatComesBackStartsItsClockAgain() {
        var tracker = StaleTracker(staleAfter: 3_600, idleWindow: 600)
        _ = tracker.update(with: [stray("a", ageHours: 5, at: start)], now: start)
        _ = tracker.update(with: [], now: start.addingTimeInterval(300))
        let back = start.addingTimeInterval(900)
        XCTAssertTrue(tracker.update(with: [stray("a", ageHours: 5, at: back)], now: back).isEmpty, "we only just started watching it again")
    }
}

final class AgentAwareClassificationTests: XCTestCase {
    private var home: TemporaryDirectory!
    private var classifier: DevProcessClassifier!

    override func setUpWithError() throws {
        home = try TemporaryDirectory()
        classifier = DevProcessClassifier(rules: .bundled, homeDirectory: home.path, minimumAge: 8)
    }

    private func node(cwd: String, arguments: [String] = ["node", "server.js"], secondsOld: Double = 600) -> ProcessDetails {
        makeDetails(
            ProcessEntry(
                identity: ProcessIdentity(pid: 9, startSeconds: UInt64(Date().timeIntervalSince1970 - secondsOld), startMicroseconds: 0),
                ppid: 1, pgid: 9, uid: getuid(), name: "node"
            ),
            path: "/usr/local/bin/node", arguments: arguments, cwd: cwd
        )
    }

    func testOutsideHomeIsOnlyADevProcessWithEvidence() {
        let process = node(cwd: "/private/tmp/scratch")
        XCTAssertNil(classifier.classify(process))
        XCTAssertNotNil(classifier.classify(process, listens: true), "it serves a port")
        XCTAssertNotNil(classifier.classify(process, startedByAgent: true), "an agent started it")
    }

    func testEvidenceDoesNotOverrideIgnoredLocationsOrCommandLines() {
        let inLibrary = node(cwd: home.path + "/Library/Application Support/Tool")
        XCTAssertNil(classifier.classify(inLibrary, listens: true, startedByAgent: true))
        let inBundle = node(cwd: "/Applications/Tool.app/Contents/Resources")
        XCTAssertNil(classifier.classify(inBundle, listens: true))
        let languageServer = node(cwd: "/private/tmp/x", arguments: ["node", "/x/typescript-language-server", "--stdio"])
        XCTAssertNil(classifier.classify(languageServer, listens: true, startedByAgent: true))
    }

    func testAListenerIsShownAtOnceButOtherProcessesWaitOutTheMinimumAge() {
        let fresh = node(cwd: home.path, secondsOld: 2)
        XCTAssertNil(classifier.classify(fresh))
        XCTAssertNil(classifier.classify(fresh, startedByAgent: true), "agents run many short commands")
        XCTAssertNotNil(classifier.classify(fresh, listens: true))
    }

    func testOnlyRuntimesQualifyEvenWithEvidence() {
        let shell = makeDetails(makeEntry(9, name: "zsh"), path: "/bin/zsh", cwd: "/private/tmp")
        XCTAssertNil(classifier.classify(shell, listens: true, startedByAgent: true))
    }
}

final class AttributedBuilderTests: XCTestCase {
    private var home: TemporaryDirectory!
    private var builder: StrayBuilder!
    private let me: UInt32 = 501
    private let node = DevClassification(runtimeID: "node", runtimeName: "Node.js", isInterpreter: true)

    override func setUpWithError() throws {
        home = try TemporaryDirectory()
        try home.write(#"{"name": "shop"}"#, to: "code/shop/package.json")
        builder = StrayBuilder(
            projectResolver: ProjectResolver(homeDirectory: home.path),
            currentUID: me,
            attribution: AttributionEngine(catalog: .bundled)
        )
    }

    private var project: String { home.path + "/code/shop" }

    func testDevStrayCarriesItsAgentAndTheAgentIsNotAStray() throws {
        // The agent is itself a node process in the project: it must be a
        // boundary, not the root of a tree that swallows the server.
        let agent = makeDetails(makeEntry(20, name: "node", uid: me, start: 100), path: "/usr/local/bin/node", arguments: ["node", "/x/@anthropic-ai/claude-code/cli.js"], cwd: project)
        let shell = makeDetails(makeEntry(21, parent: 20, name: "zsh", uid: me), path: "/bin/zsh")
        let server = makeDetails(makeEntry(22, parent: 21, name: "node", uid: me, start: 200), path: "/usr/local/bin/node", arguments: ["node", "server.js"], cwd: "/private/tmp/elsewhere")
        let session = AgentSession(agentID: "claude-code", identity: agent.identity, cwd: project)

        let all = [agent, shell, server]
        let strays = builder.build(from: ProcessScan(
            table: ProcessTable(entries: all.map(\.entry)),
            ports: [],
            details: Dictionary(uniqueKeysWithValues: all.map { ($0.pid, $0) }),
            devProcesses: [22: node],
            sessions: [20: session]
        ))

        XCTAssertEqual(strays.count, 1)
        let stray = try XCTUnwrap(strays.first)
        XCTAssertEqual(stray.processGroup?.root.pid, 22)
        XCTAssertEqual(stray.origin, .agent(id: "claude-code", orphaned: false))
        XCTAssertEqual(stray.agentSession, session)
        XCTAssertEqual(stray.project?.name, "shop", "filed under the project the agent was working in")
    }

    func testOrphanIsFiledUnderItsPastSessionsProject() throws {
        let server = makeDetails(makeEntry(22, parent: 1, name: "node", uid: me, start: 200), path: "/usr/local/bin/node", arguments: ["node", "server.js"], environment: ["CLAUDECODE": "1", "CLAUDE_PID": "20"], cwd: "/private/tmp/elsewhere")
        let gone = AgentSession(agentID: "claude-code", identity: ProcessIdentity(pid: 20, startSeconds: 100, startMicroseconds: 0), cwd: project)

        let stray = try XCTUnwrap(builder.build(from: ProcessScan(
            table: ProcessTable(entries: [server.entry]),
            ports: [],
            details: [22: server],
            devProcesses: [22: node],
            pastSessions: [20: gone]
        )).first)
        XCTAssertEqual(stray.origin, .agent(id: "claude-code", orphaned: true))
        XCTAssertTrue(stray.origin.isOrphaned)
        XCTAssertEqual(stray.project?.name, "shop")
    }

    func testOwnProjectWinsOverTheSessionsProject() throws {
        try home.write(#"{"name": "other"}"#, to: "code/other/package.json")
        let agent = makeDetails(makeEntry(20, name: "claude", uid: me, start: 100), path: "/Users/me/.local/bin/claude", cwd: project)
        let server = makeDetails(makeEntry(22, parent: 20, name: "node", uid: me, start: 200), path: "/usr/local/bin/node", arguments: ["node", "server.js"], cwd: home.path + "/code/other")
        let stray = try XCTUnwrap(builder.build(from: ProcessScan(
            table: ProcessTable(entries: [agent.entry, server.entry]),
            ports: [],
            details: [20: agent, 22: server],
            devProcesses: [22: node],
            sessions: [20: AgentSession(agentID: "claude-code", identity: agent.identity, cwd: project)]
        )).first)
        XCTAssertEqual(stray.project?.name, "other")
    }

    func testAppsAreNotAttributed() throws {
        let terminal = makeDetails(makeEntry(10, name: "Terminal", uid: me), path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        let daemon = makeDetails(makeEntry(30, parent: 10, name: "redis-server", uid: me), path: "/opt/homebrew/bin/redis-server", environment: ["CLAUDECODE": "1"])
        let stray = try XCTUnwrap(builder.build(from: ProcessScan(
            table: ProcessTable(entries: [terminal.entry, daemon.entry]),
            ports: [ListeningPort(pid: 30, port: 6379, transport: .tcp, address: "127.0.0.1")],
            details: [10: terminal, 30: daemon],
            devProcesses: [:],
            executablePaths: [10: terminal.executablePath!]
        )).first)
        XCTAssertEqual(stray.category, .app)
        XCTAssertEqual(stray.origin, .unknown)
    }

    func testTerminalOriginForAnOrdinaryDevServer() throws {
        let terminal = makeDetails(makeEntry(10, name: "Terminal", uid: me), path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        let shell = makeDetails(makeEntry(11, parent: 10, name: "zsh", uid: me), path: "/bin/zsh")
        let server = makeDetails(makeEntry(12, parent: 11, name: "node", uid: me), path: "/usr/local/bin/node", arguments: ["node", "server.js"], cwd: project)
        let stray = try XCTUnwrap(builder.build(from: ProcessScan(
            table: ProcessTable(entries: [terminal.entry, shell.entry, server.entry]),
            ports: [],
            details: [10: terminal, 11: shell, 12: server],
            devProcesses: [12: node],
            executablePaths: [10: terminal.executablePath!, 11: "/bin/zsh", 12: "/usr/local/bin/node"]
        )).first)
        XCTAssertEqual(stray.origin, .terminal(name: "Terminal"))
        XCTAssertNil(stray.agentSession)
    }
}

/// The whole pipeline against real processes: a throwaway "agent" (a Python
/// script the test starts) spawns a background worker and later exits.
final class AgentAttributionLiveTests: XCTestCase {
    private var home: TemporaryDirectory!
    private var agent: ThrowawayProcess?
    private var workerPID: Int32 = 0

    private let catalog = AgentCatalog(agents: [
        AgentProfile(
            id: "fake-agent",
            displayName: "Fake Agent",
            ancestorMatchers: ProcessMatcher(argumentPatterns: ["strays-fake-agent\\.py"]),
            envMarkers: [EnvMarker(name: "STRAYS_FAKE_AGENT", value: "1")],
            sessionPIDVariable: "STRAYS_FAKE_AGENT_PID"
        ),
    ])

    override func setUpWithError() throws {
        home = try TemporaryDirectory()
        try home.write(#"{"name": "agent-project"}"#, to: "code/agent-project/package.json")
        try home.makeDirectory("loose")
    }

    override func tearDown() {
        agent?.stop()
        if workerPID > 0 { kill(workerPID, SIGKILL) }
    }

    /// Starts the fake agent in the project. It launches a worker in a
    /// folder that is not a project, then waits to be told to exit.
    private func startAgent() async throws {
        let script = try home.write("""
        import os, subprocess, sys, time
        env = dict(os.environ, STRAYS_FAKE_AGENT="1", STRAYS_FAKE_AGENT_PID=str(os.getpid()))
        worker = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"], cwd=sys.argv[1], env=env, start_new_session=True)
        open(sys.argv[2], "w").write(str(worker.pid))
        while not os.path.exists(sys.argv[3]):
            time.sleep(0.05)
        """, to: "strays-fake-agent.py")
        let pidFile = home.url.appendingPathComponent("worker.pid")
        agent = try ThrowawayProcess(
            ThrowawayProcess.python,
            [script.path, home.path + "/loose", pidFile.path, home.path + "/exit-now"],
            cwd: home.url.appendingPathComponent("code/agent-project")
        )
        let started = await eventually { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init) != nil }
        XCTAssertTrue(started, "the fake agent did not start its worker")
        workerPID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
    }

    private func worker(in snapshot: StraysSnapshot) -> Stray? {
        snapshot.strays.first { $0.processGroup?.root.pid == workerPID }
    }

    func testWorkerIsAttributedThenOrphanedWhenItsAgentExits() async throws {
        try await startAgent()
        let monitor = Monitor(homeDirectory: home.path, minimumAge: 0, sources: [], agents: catalog)

        // While the agent runs.
        var attributed: Stray?
        let found = await eventually {
            let snapshot = await monitor.refresh()
            attributed = self.worker(in: snapshot)
            return attributed?.origin == .agent(id: "fake-agent", orphaned: false)
        }
        XCTAssertTrue(found, "origin was \(String(describing: attributed?.origin))")
        let alive = try XCTUnwrap(attributed)
        XCTAssertEqual(alive.category, .dev)
        XCTAssertEqual(alive.agentSession?.pid, agent?.pid)
        XCTAssertEqual(alive.project?.name, "agent-project", "its own folder is no project, so the session's is used")

        let snapshot = await monitor.latest
        XCTAssertEqual(snapshot.agentSessions.map(\.agentID), ["fake-agent"])
        XCTAssertFalse(snapshot.strays.contains { $0.processGroup?.root.pid == agent?.pid }, "the agent itself is not a stray")

        // The agent exits and leaves its worker behind.
        FileManager.default.createFile(atPath: home.path + "/exit-now", contents: nil)
        var orphan: Stray?
        let orphaned = await eventually {
            let snapshot = await monitor.refresh()
            orphan = self.worker(in: snapshot)
            return orphan?.origin == .agent(id: "fake-agent", orphaned: true)
        }
        XCTAssertTrue(orphaned, "origin was \(String(describing: orphan?.origin))")
        let left = try XCTUnwrap(orphan)
        XCTAssertEqual(left.processGroup?.root.entry.ppid, 1, "adopted by launchd")
        XCTAssertEqual(left.project?.name, "agent-project", "remembered from the session that has gone")
        let after = await monitor.latest
        XCTAssertTrue(after.agentSessions.isEmpty)

        // And it can be inspected on its own.
        let inspection = await monitor.inspect(pid: workerPID)
        XCTAssertEqual(inspection?.origin, .agent(id: "fake-agent", orphaned: true))
        XCTAssertEqual(inspection?.candidateMarkers["STRAYS_FAKE_AGENT"], "1")
    }

    /// Without the profile the "agent" is just a Python script: the worker
    /// is part of its tree, and nothing is attributed to an agent.
    func testWithoutTheProfileTheAgentIsAnOrdinaryDevTree() async throws {
        try await startAgent()
        let monitor = Monitor(homeDirectory: home.path, minimumAge: 0, sources: [], agents: AgentCatalog(agents: []))
        var stray: Stray?
        let found = await eventually {
            let snapshot = await monitor.refresh()
            stray = snapshot.strays.first { $0.processGroup?.members.contains { $0.pid == self.workerPID } ?? false }
            return stray != nil
        }
        XCTAssertTrue(found)
        XCTAssertEqual(stray?.processGroup?.root.pid, agent?.pid, "the script that started the worker is the root")
        XCTAssertNil(stray?.origin.agentID)
        XCTAssertNil(stray?.agentSession)
        let snapshot = await monitor.latest
        XCTAssertTrue(snapshot.agentSessions.isEmpty)
    }
}
