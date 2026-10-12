import XCTest
@testable import StraysCore

final class StackStoreTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var store: StackStore!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
        store = StackStore(directory: directory.url.appendingPathComponent("Strays"))
    }

    func testNothingSavedYetIsEmptyNotAnError() {
        XCTAssertTrue(store.loadStacks().isEmpty)
        XCTAssertTrue(store.loadHideRules().isEmpty)
        XCTAssertTrue(store.loadLaunched().isEmpty)
    }

    func testStacksRoundTripAndCreateTheFolder() throws {
        let stacks = [
            Stack(name: "Shop local", items: [
                .command("npm run dev", in: "/Users/me/shop"),
                .composeProject("shop", directory: "/Users/me/shop"),
                .brewService("redis"),
                .container("scratch"),
            ]),
            Stack(name: "Empty"),
        ]
        try store.save(stacks)
        XCTAssertEqual(store.loadStacks(), stacks)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.stacksURL.path))
    }

    func testTheFileIsReadableByAHuman() throws {
        try store.save([Stack(name: "Shop", items: [.command("npm run dev", in: "/Users/me/shop")])])
        let text = try String(contentsOf: store.stacksURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#""kind" : "command""#), text)
        XCTAssertTrue(text.contains(#""value" : "npm run dev""#), text)
        XCTAssertTrue(text.contains(#""directory" : "/Users/me/shop""#), "slashes are not escaped: \(text)")
        XCTAssertTrue(text.contains("\n"), "pretty-printed")
    }

    func testAHandEditedFileWithATypoDoesNotBreakLoading() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try "{ not json".write(to: store.stacksURL, atomically: true, encoding: .utf8)
        try #"[{"kind": "teleport", "value": "x"}]"#.write(to: store.hideRulesURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(store.loadStacks().isEmpty)
        XCTAssertTrue(store.loadHideRules().isEmpty)
    }

    func testHideRulesAndLaunchedProcessesRoundTrip() throws {
        let rules: [HideRule] = [.port(5000), .name("ControlCenter"), HideRule(kind: .project, value: "/Users/me/shop")]
        try store.save(rules)
        XCTAssertEqual(store.loadHideRules(), rules)

        let item = UUID()
        let identity = ProcessIdentity(pid: 4242, startSeconds: 100, startMicroseconds: 7)
        store.save(launched: [item: identity])
        XCTAssertEqual(store.loadLaunched(), [item: identity])
    }

    func testDefaultLocationIsApplicationSupport() {
        XCTAssertTrue(StackStore().stacksURL.path.hasSuffix("/Library/Application Support/Strays/stacks.json"))
        XCTAssertTrue(StackStore().hideRulesURL.path.hasSuffix("/Library/Application Support/Strays/hidden.json"))
    }
}

/// Builders shared by the stack and hide-rule tests.
private enum Sample {
    static let shop = Project(rootPath: "/Users/me/shop", name: "shop", marker: ".git")

    static func process(_ pid: Int32, executable: String, arguments: [String], cwd: String, title: String? = nil, ports: [UInt16] = [], project: Project? = nil, category: Stray.Category = .dev) -> Stray {
        let root = makeDetails(makeEntry(pid, name: (executable as NSString).lastPathComponent), path: executable, arguments: arguments, cwd: cwd)
        return Stray(
            id: "process:\(pid)",
            kind: .process(ProcessGroup(root: root, runtime: category == .dev ? DevClassification(runtimeID: "node", runtimeName: "Node.js") : nil)),
            category: category,
            title: title ?? arguments.joined(separator: " "),
            ports: ports.map { PortSummary(port: $0, transport: .tcp, addresses: ["127.0.0.1"], isLANVisible: false, pid: pid) },
            project: project
        )
    }

    static func container(_ name: String, running: Bool, compose: String? = nil, directory: String? = nil, ports: [UInt16] = []) -> Stray {
        let container = DockerContainer(
            id: "id-\(name)", name: name, image: "postgres:17", state: running ? .running : .exited,
            ports: ports.map { .init(hostIP: "0.0.0.0", hostPort: $0, containerPort: 80, transport: .tcp) },
            composeProject: compose, composeWorkingDirectory: directory
        )
        return Stray(id: "docker:id-\(name)", kind: .container(container), category: .docker, title: name, ports: running ? container.portSummaries : [], isRunning: running)
    }

    static func service(_ name: String, running: Bool) -> Stray {
        Stray(id: "brew:\(name)", kind: .brewService(BrewService(name: name, status: running ? .started : .stopped), process: nil), category: .brew, title: name, isRunning: running)
    }
}

final class HideRuleTests: XCTestCase {
    private let server = Sample.process(10, executable: "/usr/local/bin/node", arguments: ["node", "server.js"], cwd: "/Users/me/shop", ports: [3000, 9229], project: Sample.shop)

    func testHidesByPort() {
        XCTAssertTrue(HideRule.port(3000).matches(server))
        XCTAssertTrue(HideRule.port(9229).matches(server))
        XCTAssertFalse(HideRule.port(8080).matches(server))
        XCTAssertFalse(HideRule(kind: .port, value: "not-a-port").matches(server))
        XCTAssertTrue(HideRule.port(5432).matches(Sample.container("db", running: true, ports: [5432])))
    }

    func testHidesByName() {
        XCTAssertTrue(HideRule.name("node").matches(server), "a process is named by its executable")
        XCTAssertFalse(HideRule.name("server.js").matches(server))
        XCTAssertTrue(HideRule.name("db").matches(Sample.container("db", running: true)))
        XCTAssertTrue(HideRule.name("redis").matches(Sample.service("redis", running: true)))
        XCTAssertFalse(HideRule.name("redis").matches(Sample.service("postgresql@17", running: true)))
    }

    func testHidesByProject() {
        XCTAssertTrue(HideRule.project(Sample.shop).matches(server))
        XCTAssertFalse(HideRule(kind: .project, value: "/Users/me/other").matches(server))
        XCTAssertFalse(HideRule.project(Sample.shop).matches(Sample.service("redis", running: true)))
    }

    func testAnyMatchingRuleHides() {
        let rules: [HideRule] = [.port(1), .name("node")]
        XCTAssertTrue(rules.hides(server))
        XCTAssertFalse([HideRule.port(1)].hides(server))
        XCTAssertFalse([HideRule]().hides(server))
    }

    func testSummaries() {
        XCTAssertEqual(HideRule.port(5000).summary, "Port 5000")
        XCTAssertEqual(HideRule.name("ControlCenter").summary, "Named “ControlCenter”")
        XCTAssertEqual(HideRule.project(Sample.shop).summary, "Project shop")
    }
}

final class StackItemTests: XCTestCase {
    func testAComposeContainerBecomesItsProject() {
        let item = StackItem(recreating: Sample.container("shop-db-1", running: true, compose: "shop", directory: "/Users/me/shop"))
        XCTAssertEqual(item?.kind, .composeProject)
        XCTAssertEqual(item?.value, "shop")
        XCTAssertEqual(item?.directory, "/Users/me/shop")
    }

    func testAStandaloneContainerAndAServiceAreNamedDirectly() {
        XCTAssertEqual(StackItem(recreating: Sample.container("scratch", running: false))?.kind, .container)
        XCTAssertEqual(StackItem(recreating: Sample.container("scratch", running: false))?.value, "scratch")
        XCTAssertEqual(StackItem(recreating: Sample.service("redis", running: true))?.kind, .brewService)
    }

    func testADevProcessBecomesItsCommandInItsFolder() {
        let stray = Sample.process(1, executable: "/usr/local/bin/node", arguments: ["npm", "run", "dev"], cwd: "/Users/me/shop")
        let item = StackItem(recreating: stray)
        XCTAssertEqual(item?.kind, .command)
        XCTAssertEqual(item?.value, "npm run dev")
        XCTAssertEqual(item?.directory, "/Users/me/shop")
    }

    func testArgumentsThatNeedItAreQuotedForTheShell() {
        let stray = Sample.process(1, executable: "/usr/bin/python3", arguments: ["python3", "-c", "import time; time.sleep(60)", "it's"], cwd: "/tmp")
        XCTAssertEqual(StackItem(recreating: stray)?.value, #"python3 -c 'import time; time.sleep(60)' 'it'\''s'"#)
    }

    func testSecretsAreNotWrittenIntoAStack() {
        let stray = Sample.process(1, executable: "/usr/local/bin/node", arguments: ["node", "server.js", "--token=abc123"], cwd: "/Users/me/shop")
        let value = StackItem(recreating: stray)?.value ?? ""
        XCTAssertFalse(value.contains("abc123"))
        XCTAssertTrue(value.hasPrefix("node server.js"))
    }

    func testAppsCannotBeTurnedIntoStackItems() {
        let app = Sample.process(1, executable: "/Applications/Notion.app/Contents/MacOS/Notion", arguments: ["Notion"], cwd: "/", category: .app)
        XCTAssertNil(StackItem(recreating: app))
    }
}

final class StackStatusTests: XCTestCase {
    private func snapshot(_ strays: [Stray]) -> StraysSnapshot { StraysSnapshot(strays: strays) }

    func testComposeProjectStatus() {
        let item = StackItem.composeProject("shop")
        let up = Sample.container("a", running: true, compose: "shop")
        let down = Sample.container("b", running: false, compose: "shop")
        let other = Sample.container("c", running: true, compose: "other")

        XCTAssertEqual(StackStatusResolver.status(of: item, in: snapshot([up, Sample.container("b", running: true, compose: "shop")])), .running)
        XCTAssertEqual(StackStatusResolver.status(of: item, in: snapshot([up, down])), .partial(running: 1, total: 2))
        XCTAssertEqual(StackStatusResolver.status(of: item, in: snapshot([down])), .stopped)
        XCTAssertEqual(StackStatusResolver.status(of: item, in: snapshot([other])), .missing)
        XCTAssertTrue(StackItemStatus.partial(running: 1, total: 2).isRunning)
        XCTAssertFalse(StackItemStatus.missing.isRunning)
    }

    func testContainerAndServiceStatus() {
        let strays = [Sample.container("scratch", running: false), Sample.service("redis", running: true)]
        XCTAssertEqual(StackStatusResolver.status(of: .container("scratch"), in: snapshot(strays)), .stopped)
        XCTAssertEqual(StackStatusResolver.status(of: .container("nope"), in: snapshot(strays)), .missing)
        XCTAssertEqual(StackStatusResolver.status(of: .brewService("redis"), in: snapshot(strays)), .running)
        XCTAssertEqual(StackStatusResolver.status(of: .brewService("nginx"), in: snapshot(strays)), .missing)
    }

    func testCommandIsRunningWhenStraysStartedItAndItIsAlive() {
        let item = StackItem.command("npm run dev", in: "/Users/me/shop")
        XCTAssertEqual(StackStatusResolver.status(of: item, in: snapshot([]), launchedIsAlive: true), .running)
        XCTAssertEqual(StackStatusResolver.status(of: item, in: snapshot([]), launchedIsAlive: false), .stopped)
    }

    func testCommandStartedElsewhereIsRecognisedByFolderAndCommandLine() {
        let item = StackItem.command("npm  run dev", in: "/Users/me/shop/")
        let byTitle = Sample.process(1, executable: "/usr/local/bin/node", arguments: ["node", "/usr/local/bin/npm", "run", "dev"], cwd: "/Users/me/shop", title: "npm run dev")
        XCTAssertEqual(StackStatusResolver.status(of: item, in: snapshot([byTitle])), .running, "whitespace and a trailing slash do not matter")

        let bySuffix = Sample.process(2, executable: "/usr/local/bin/node", arguments: ["node", "/usr/local/bin/npm", "run", "dev"], cwd: "/Users/me/shop", title: "something else")
        XCTAssertNotNil(StackStatusResolver.matchingProcess(for: item, in: snapshot([bySuffix])))

        let elsewhere = Sample.process(3, executable: "/usr/local/bin/node", arguments: ["npm", "run", "dev"], cwd: "/Users/me/other", title: "npm run dev")
        XCTAssertEqual(StackStatusResolver.status(of: item, in: snapshot([elsewhere])), .stopped, "the same command in another folder is another thing")

        let different = Sample.process(4, executable: "/usr/local/bin/node", arguments: ["npm", "run", "build"], cwd: "/Users/me/shop", title: "npm run build")
        XCTAssertEqual(StackStatusResolver.status(of: item, in: snapshot([different])), .stopped)
    }
}

/// Stack operations through the monitor, against the fake Docker and brew.
final class StackOperationsTests: XCTestCase {
    private var fake: FakeDocker!
    private var home: TemporaryDirectory!
    private var brew: FakeBrew!
    private var monitor: Monitor!

    override func setUp() async throws {
        fake = try FakeDocker()
        home = try TemporaryDirectory()
        brew = FakeBrew()
        await brew.respond(to: "info", stdout: #"[{"name":"redis","running":false,"status":"none"}]"#)
        await brew.respond(to: "start")
        await brew.respond(to: "stop")

        let path = fake.socketPath
        let brew = brew!
        monitor = Monitor(
            homeDirectory: home.path,
            minimumAge: 0,
            sources: [.docker, .brew],
            dockerCollector: DockerCollector(locate: { path }),
            brewCollector: BrewCollector(brewPath: "/fake/brew") { _, arguments in await brew.run(arguments) },
            agents: AgentCatalog(agents: [])
        )
        await monitor.refresh()
    }

    override func tearDown() {
        fake.shutDown()
    }

    func testComposeProjectStopsAndStartsItsContainers() async throws {
        let item = StackItem.composeProject("shop")
        var status = await monitor.status(of: item)
        XCTAssertEqual(status, .running)

        try await monitor.stop(item)
        status = await monitor.status(of: item)
        XCTAssertEqual(status, .stopped)

        try await monitor.start(item)
        status = await monitor.status(of: item)
        XCTAssertEqual(status, .running)

        try await monitor.start(item)
        let starts = try await fake.requests().filter { $0.hasPrefix("POST") && $0.hasSuffix("/start") }
        XCTAssertEqual(starts.count, 1, "starting what is already up does nothing")
    }

    func testContainerIsFoundByName() async throws {
        let item = StackItem.container("scratch")
        var status = await monitor.status(of: item)
        XCTAssertEqual(status, .stopped)
        try await monitor.start(item)
        status = await monitor.status(of: item)
        XCTAssertEqual(status, .running)
        try await monitor.stop(item)
        status = await monitor.status(of: item)
        XCTAssertEqual(status, .stopped)
    }

    func testBrewServiceGoesThroughBrew() async throws {
        let item = StackItem.brewService("redis")
        let status = await monitor.status(of: item)
        XCTAssertEqual(status, .stopped)
        try await monitor.start(item)
        let calls = await brew.calls
        XCTAssertTrue(calls.contains(["services", "start", "redis"]))
    }

    func testThingsThatDoNotExistAreReportedNotIgnored() async {
        for item in [StackItem.container("ghost"), .brewService("ghost")] {
            let status = await monitor.status(of: item)
            XCTAssertEqual(status, .missing)
            do {
                try await monitor.start(item)
                XCTFail("expected notFound")
            } catch {
                XCTAssertEqual(error as? StackError, .notFound("ghost"))
            }
        }
    }

    func testCommandNeedsAFolderThatExists() async {
        do {
            try await monitor.start(.command("echo hi", in: home.path + "/missing"))
            XCTFail("expected missingDirectory")
        } catch {
            XCTAssertEqual(error as? StackError, .missingDirectory(home.path + "/missing"))
        }
    }

    func testStatusesOfAWholeStack() async {
        let stack = Stack(name: "Shop", items: [.composeProject("shop"), .container("scratch"), .brewService("redis"), .container("ghost")])
        let statuses = await monitor.statuses(of: stack)
        XCTAssertEqual(stack.items.map { statuses[$0.id] }, [.running, .stopped, .stopped, .missing])
    }
}

/// A command item, started and stopped for real. The command is a
/// throwaway sleeper in a temporary folder.
final class StackCommandLiveTests: XCTestCase {
    private var home: TemporaryDirectory!
    private var store: StackStore!
    private var previousShell: String?
    private var launchedPID: Int32 = 0

    override func setUpWithError() throws {
        home = try TemporaryDirectory()
        try home.makeDirectory("work")
        store = StackStore(directory: home.url.appendingPathComponent("support"))
        // Run the command through plain sh, not the developer's own shell
        // and its startup files.
        previousShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", "/bin/sh", 1)
    }

    override func tearDown() {
        if let previousShell { setenv("SHELL", previousShell, 1) } else { unsetenv("SHELL") }
        if launchedPID > 0 { kill(launchedPID, SIGKILL) }
    }

    private func monitor() -> Monitor {
        Monitor(homeDirectory: home.path, minimumAge: 0, sources: [], agents: AgentCatalog(agents: []), stackStore: store)
    }

    func testCommandItemStartsSurvivesARelaunchOfStraysAndStops() async throws {
        let item = StackItem.command("\(ThrowawayProcess.python) -c 'import time; time.sleep(60)'", in: home.path + "/work")
        let first = monitor()
        var status = await first.status(of: item)
        XCTAssertEqual(status, .stopped)

        try await first.start(item)
        let identity = try XCTUnwrap(store.loadLaunched()[item.id], "the launched process is recorded on disk")
        launchedPID = identity.pid
        status = await first.status(of: item)
        XCTAssertEqual(status, .running)

        try await first.start(item)
        XCTAssertEqual(store.loadLaunched()[item.id], identity, "starting again does not launch a second copy")

        // A fresh monitor, as after quitting and reopening Strays.
        let second = monitor()
        status = await second.status(of: item)
        XCTAssertEqual(status, .running)

        try await second.stop(item)
        status = await second.status(of: item)
        XCTAssertEqual(status, .stopped)
        XCTAssertNil(LibProc.entry(for: identity.pid).flatMap { $0.identity == identity ? $0 : nil }, "the process is gone")
        XCTAssertNil(store.loadLaunched()[item.id])
    }

    func testAProcessThatExitsOnItsOwnIsSeenAsStopped() async throws {
        let item = StackItem.command("true", in: home.path + "/work")
        let monitor = monitor()
        try await monitor.start(item)
        let stopped = await eventually { await monitor.status(of: item) == .stopped }
        XCTAssertTrue(stopped)
    }
}
