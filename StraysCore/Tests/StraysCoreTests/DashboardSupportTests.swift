import XCTest
@testable import StraysCore

final class SecretMaskerTests: XCTestCase {
    func testSensitiveNames() {
        for name in ["API_KEY", "GITHUB_TOKEN", "client_secret", "DB_PASSWORD", "PGPASSWD", "AWS_SECRET_ACCESS_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "SSH_PRIVATE"] {
            XCTAssertTrue(SecretMasker.isSensitive(name: name), name)
        }
        for name in ["PATH", "HOME", "PWD", "NODE_ENV", "PORT", "SSH_AUTH_SOCK", "LANG", "CLAUDECODE"] {
            XCTAssertFalse(SecretMasker.isSensitive(name: name), name)
        }
    }

    func testDisplayHidesSecretsAndKeepsEverythingElse() {
        XCTAssertEqual(SecretMasker.display(name: "API_KEY", value: "sk-live-123"), SecretMasker.mask)
        XCTAssertEqual(SecretMasker.display(name: "NODE_ENV", value: "development"), "development")
        XCTAssertEqual(SecretMasker.display(name: "API_KEY", value: ""), "", "nothing to hide in an empty value")
        XCTAssertTrue(SecretMasker.hidesSomething(name: "API_KEY", value: "x"))
        XCTAssertFalse(SecretMasker.hidesSomething(name: "PORT", value: "3000"))
    }

    func testMaskNeverLeaksAnyPartOfTheSecret() {
        let masked = SecretMasker.display(name: "STRIPE_SECRET_KEY", value: "sk_live_abcdef123456")
        XCTAssertFalse(masked.contains("sk_live"))
        XCTAssertFalse(masked.contains("3456"))
    }

    func testCredentialsInsideURLsAreMaskedEvenUnderInnocentNames() {
        XCTAssertEqual(
            SecretMasker.display(name: "DATABASE_URL", value: "postgres://app:hunter2@db.internal:5432/shop"),
            "postgres://app:\(SecretMasker.mask)@db.internal:5432/shop"
        )
        XCTAssertEqual(SecretMasker.maskURLCredentials(in: "redis://:s3cret@localhost:6379"), "redis://:\(SecretMasker.mask)@localhost:6379")
        XCTAssertEqual(SecretMasker.maskURLCredentials(in: "http://localhost:3000/a@b"), "http://localhost:3000/a@b", "a port is not a password")
        XCTAssertEqual(SecretMasker.maskURLCredentials(in: "https://example.com/path"), "https://example.com/path")
    }

    func testArgumentsAreMasked() {
        XCTAssertEqual(
            SecretMasker.maskArguments(["server", "--token=abc123", "--port=3000", "--password", "hunter2", "--verbose"]),
            ["server", "--token=\(SecretMasker.mask)", "--port=3000", "--password", SecretMasker.mask, "--verbose"]
        )
        XCTAssertEqual(SecretMasker.maskArguments(["env", "API_KEY=xyz", "node", "app.js"]), ["env", "API_KEY=\(SecretMasker.mask)", "node", "app.js"])
        XCTAssertEqual(SecretMasker.maskArguments(["psql", "postgres://u:p@h/db"]), ["psql", "postgres://u:\(SecretMasker.mask)@h/db"])
        XCTAssertEqual(SecretMasker.maskArguments(["tool", "--api-key", "--other"]), ["tool", "--api-key", "--other"], "a flag is not a value")
    }
}

final class MetricsHistoryTests: XCTestCase {
    private func stray(_ id: String, cpu: Double, memory: UInt64) -> Stray {
        Stray(
            id: id,
            kind: .process(ProcessGroup(root: makeDetails(makeEntry(1)))),
            category: .dev,
            title: id,
            cpuPercent: cpu,
            memoryBytes: memory
        )
    }

    private func snapshot(_ strays: [Stray], at seconds: TimeInterval) -> StraysSnapshot {
        StraysSnapshot(strays: strays, capturedAt: Date(timeIntervalSince1970: seconds))
    }

    func testRecordsOneSamplePerSnapshot() {
        var history = MetricsHistory()
        history.record(snapshot([stray("a", cpu: 5, memory: 100)], at: 1))
        history.record(snapshot([stray("a", cpu: 9, memory: 120)], at: 2))
        XCTAssertEqual(history.samples(for: "a").map(\.cpuPercent), [5, 9])
        XCTAssertEqual(history.samples(for: "a").map(\.memoryBytes), [100, 120])
        XCTAssertTrue(history.samples(for: "missing").isEmpty)
    }

    func testKeepsOnlyTheNewestSamples() {
        var history = MetricsHistory(capacity: 3)
        for second in 1...10 {
            history.record(snapshot([stray("a", cpu: Double(second), memory: 0)], at: TimeInterval(second)))
        }
        XCTAssertEqual(history.samples(for: "a").map(\.cpuPercent), [8, 9, 10])
    }

    func testForgetsStraysThatStopped() {
        var history = MetricsHistory()
        history.record(snapshot([stray("a", cpu: 1, memory: 0), stray("b", cpu: 1, memory: 0)], at: 1))
        history.record(snapshot([stray("b", cpu: 2, memory: 0)], at: 2))
        XCTAssertTrue(history.samples(for: "a").isEmpty)
        XCTAssertEqual(history.trackedCount, 1)
    }
}

final class StraySearchTests: XCTestCase {
    private let stray = Stray(
        id: "x",
        kind: .process(ProcessGroup(root: makeDetails(
            makeEntry(48_211, name: "node"),
            path: "/usr/local/bin/node",
            arguments: ["node", "/Users/me/shop/node_modules/.bin/next", "dev"],
            cwd: "/Users/me/shop"
        ))),
        category: .dev,
        title: "next dev",
        subtitle: "Node.js",
        ports: [PortSummary(port: 3000, transport: .tcp, addresses: ["*"], isLANVisible: true, pid: 48_211)],
        project: Project(rootPath: "/Users/me/shop", name: "Shop", marker: ".git")
    )

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(stray.matches(query: ""))
        XCTAssertTrue(stray.matches(query: "   "))
    }

    func testMatchesTitleProjectPortPIDAndRuntime() {
        for query in ["next", "NEXT DEV", "shop", "3000", ":3000", "48211", "node.js", "tcp", "lan", "node_modules"] {
            XCTAssertTrue(stray.matches(query: query), query)
        }
    }

    func testEveryWordMustMatch() {
        XCTAssertTrue(stray.matches(query: "shop 3000"))
        XCTAssertFalse(stray.matches(query: "shop 8080"))
        XCTAssertFalse(stray.matches(query: "django"))
    }
}

final class ProcessLauncherTests: XCTestCase {
    func testPlanPrefersAnExistingAbsoluteArgvZero() throws {
        // `/usr/bin/python3` re-execs another binary; argv[0] is what to run again.
        let details = makeDetails(makeEntry(1), path: "/somewhere/Python.app/Contents/MacOS/Python", arguments: ["/usr/bin/python3", "-m", "http.server"])
        let plan = try XCTUnwrap(ProcessLauncher.plan(for: details))
        XCTAssertEqual(plan.executable, "/usr/bin/python3")
        XCTAssertEqual(plan.arguments, ["/usr/bin/python3", "-m", "http.server"])
    }

    func testPlanUsesTheRecordedExecutableWhenArgvZeroIsItsName() throws {
        let details = makeDetails(makeEntry(1), path: "/usr/local/bin/node", arguments: ["node", "server.js"])
        let plan = try XCTUnwrap(ProcessLauncher.plan(for: details))
        XCTAssertEqual(plan.executable, "/usr/local/bin/node")
        XCTAssertEqual(plan.arguments, ["node", "server.js"])
    }

    func testPlanFallsBackToALoginShellForRewrittenCommands() throws {
        // npm rewrote its arguments: the executable is node, argv says npm.
        let details = makeDetails(makeEntry(1), path: "/usr/local/bin/node", arguments: ["npm", "run", "it's"], environment: ["SHELL": "/bin/zsh"])
        let plan = try XCTUnwrap(ProcessLauncher.plan(for: details))
        XCTAssertEqual(plan.executable, "/bin/zsh")
        XCTAssertEqual(plan.arguments, ["zsh", "-l", "-c", "exec 'npm' 'run' 'it'\\''s'"])
    }

    func testPlanNeedsSomethingToRun() {
        XCTAssertNil(ProcessLauncher.plan(for: makeDetails(makeEntry(1))))
    }

    /// Reads a process once it shows the marker in its environment.
    /// `/usr/bin/python3` is an Apple shim that re-execs the real interpreter,
    /// and macOS hides the environment of the shim itself.
    private func settledDetails(of pid: Int32) async -> ProcessDetails? {
        var result: ProcessDetails?
        _ = await eventually {
            guard let entry = LibProc.entry(for: pid) else { return false }
            result = await ProcessInspector().details(for: [entry])[pid]
            return result?.environment["STRAYS_RELAUNCH"] == "yes"
        }
        return result
    }

    func testRelaunchStartsTheSameCommandInTheSameDirectoryDetached() async throws {
        let directory = try TemporaryDirectory()
        let original = try ThrowawayProcess.sleeper(cwd: directory.url, environment: ["STRAYS_RELAUNCH": "yes"])
        defer { original.stop() }
        let settled = await settledDetails(of: original.pid)
        let details = try XCTUnwrap(settled)

        let pid = try ProcessLauncher.relaunch(details)
        addTeardownBlock { kill(pid, SIGKILL) }
        XCTAssertNotEqual(pid, original.pid)

        let copy = await settledDetails(of: pid)
        let relaunched = try XCTUnwrap(copy)
        XCTAssertEqual(relaunched.arguments, details.arguments)
        XCTAssertEqual(relaunched.cwd, details.cwd)
        XCTAssertEqual(relaunched.environment["STRAYS_RELAUNCH"], "yes")
        XCTAssertEqual(relaunched.entry.pgid, pid, "it leads its own session and group")
        XCTAssertNotEqual(relaunched.entry.pgid, details.entry.pgid)
    }

    func testEnvironmentOfAppleSystemBinariesIsHidden() async throws {
        // Documents a macOS limit that agent attribution has to live with.
        let process = try ThrowawayProcess("/bin/sleep", ["60"], environment: ["STRAYS_RELAUNCH": "yes"])
        defer { process.stop() }
        let entry = try XCTUnwrap(LibProc.entry(for: process.pid))
        let inspected = await ProcessInspector().details(for: [entry])
        let details = try XCTUnwrap(inspected[process.pid])
        XCTAssertEqual(details.arguments, ["/bin/sleep", "60"])
        XCTAssertTrue(details.environment.isEmpty)
    }

    func testRelaunchWithNoCapturedEnvironmentStillGetsOne() async throws {
        let details = makeDetails(makeEntry(1), path: ThrowawayProcess.python, arguments: [ThrowawayProcess.python, "-c", "import time; time.sleep(60)"])
        let pid = try ProcessLauncher.relaunch(details)
        addTeardownBlock { kill(pid, SIGKILL) }
        var environment: [String: String] = [:]
        let hasEnvironment = await eventually {
            guard let entry = LibProc.entry(for: pid) else { return false }
            environment = await ProcessInspector().details(for: [entry])[pid]?.environment ?? [:]
            return environment["HOME"] != nil
        }
        XCTAssertTrue(hasEnvironment, "falls back to our own environment")
    }

    func testLaunchReportsAMissingExecutable() {
        XCTAssertThrowsError(try ProcessLauncher.launch(executable: "/nonexistent/tool", arguments: ["tool"], cwd: nil, environment: [:])) { error in
            guard case LaunchError.spawnFailed = error else { return XCTFail("\(error)") }
        }
    }
}

final class FuzzyMatcherTests: XCTestCase {
    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "stnx", in: "Stop next dev"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "NEXT", in: "stop next dev"))
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", in: "Stop next dev"))
        XCTAssertNil(FuzzyMatcher.score(query: "devs", in: "Stop next dev"), "every character must be found, in order")
    }

    func testEmptyQueryKeepsEverythingInOrder() {
        XCTAssertEqual(FuzzyMatcher.rank(["b", "a"], query: "  ") { $0 }, ["b", "a"])
    }

    func testTighterAndWordStartMatchesRankHigher() {
        let ranked = FuzzyMatcher.rank(
            ["Copy URL of next dev", "Stop next dev", "Open settings", "Stop tsc --watch"],
            query: "stop"
        ) { $0 }
        XCTAssertEqual(Array(ranked.prefix(2)).sorted(), ["Stop next dev", "Stop tsc --watch"])
        XCTAssertFalse(ranked.contains("Open settings"))
    }

    func testWhitespaceInTheQueryIsIgnored() {
        XCTAssertEqual(FuzzyMatcher.score(query: "next dev", in: "Stop next dev"), FuzzyMatcher.score(query: "nextdev", in: "Stop next dev"))
    }
}
