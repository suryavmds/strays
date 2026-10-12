import XCTest
@testable import StraysCore

final class BrewServicesParserTests: XCTestCase {
    // Captured from `brew services info --all --json`.
    private let info = """
    [
      {"name":"postgresql@17","service_name":"homebrew.mxcl.postgresql@17","running":true,"loaded":true,"schedulable":false,"pid":755,
       "exit_code":null,"user":"me","status":"started","file":"/Users/me/Library/LaunchAgents/homebrew.mxcl.postgresql@17.plist",
       "command":"/opt/homebrew/opt/postgresql@17/bin/postgres -D /opt/homebrew/var/postgresql@17"},
      {"name":"redis","service_name":"homebrew.mxcl.redis","running":false,"loaded":false,"schedulable":false,"pid":null,
       "exit_code":null,"user":null,"status":"none","file":"/opt/homebrew/opt/redis/homebrew.mxcl.redis.plist","command":"/opt/homebrew/opt/redis/bin/redis-server"},
      {"name":"nginx","service_name":"homebrew.mxcl.nginx","running":false,"loaded":true,"pid":0,"exit_code":78,"user":"me","status":"error"}
    ]
    """

    // Captured from `brew services list --json`.
    private let list = """
    [{"name":"redis","status":"started","user":"me","file":"/Users/me/Library/LaunchAgents/homebrew.mxcl.redis.plist","exit_code":null},
     {"name":"dnsmasq","status":"scheduled","user":"root","file":"/Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist","exit_code":0},
     {"name":"weird","status":"something-new","user":null,"file":null,"exit_code":null}]
    """

    func testParsesTheInfoForm() throws {
        let services = try BrewServicesParser.parse(Data(info.utf8))
        XCTAssertEqual(services.map(\.name), ["nginx", "postgresql@17", "redis"], "sorted by name")

        let postgres = services[1]
        XCTAssertEqual(postgres.status, .started)
        XCTAssertTrue(postgres.isRunning)
        XCTAssertEqual(postgres.pid, 755)
        XCTAssertEqual(postgres.serviceName, "homebrew.mxcl.postgresql@17")
        XCTAssertEqual(postgres.statusLabel, "Started")

        let redis = services[2]
        XCTAssertEqual(redis.status, .stopped)
        XCTAssertFalse(redis.isRunning)
        XCTAssertNil(redis.pid)

        let nginx = services[0]
        XCTAssertEqual(nginx.status, .error)
        XCTAssertNil(nginx.pid, "a PID of zero is no PID")
        XCTAssertEqual(nginx.statusLabel, "Error (exit 78)")
    }

    func testParsesTheOlderListForm() throws {
        let services = try BrewServicesParser.parse(Data(list.utf8))
        XCTAssertEqual(services.map(\.status), [.scheduled, .started, .other("something-new")])
        XCTAssertNil(services[1].pid, "the list form has no PID")
        XCTAssertEqual(services[2].statusLabel, "Something-New")
    }

    func testEmptyListAndGarbage() throws {
        XCTAssertTrue(try BrewServicesParser.parse(Data("[]".utf8)).isEmpty)
        XCTAssertThrowsError(try BrewServicesParser.parse(Data("Error: Unknown command".utf8)))
    }
}

/// Records `brew` invocations instead of running anything.
private actor FakeBrew {
    private(set) var calls: [[String]] = []
    private var responses: [String: SubprocessResult] = [:]

    func respond(to subcommand: String, status: Int32 = 0, stdout: String = "", stderr: String = "") {
        responses[subcommand] = SubprocessResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }

    func run(_ arguments: [String]) -> SubprocessResult {
        calls.append(arguments)
        let key = arguments.dropFirst().first ?? ""
        return responses[key] ?? SubprocessResult(status: 1, stdout: Data(), stderr: Data("no canned response".utf8))
    }
}

final class BrewCollectorTests: XCTestCase {
    private let infoJSON = #"[{"name":"redis","running":true,"pid":750,"status":"started"}]"#
    private let listJSON = #"[{"name":"redis","status":"started"}]"#

    private func collector(_ brew: FakeBrew, path: String? = "/opt/homebrew/bin/brew") -> BrewCollector {
        BrewCollector(brewPath: path) { _, arguments in await brew.run(arguments) }
    }

    func testMissingHomebrewIsUnavailableNotAnError() async throws {
        let brew = FakeBrew()
        let snapshot = try await collector(brew, path: nil).collect()
        XCTAssertEqual(snapshot, .unavailable)
        let calls = await brew.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testListsServicesWithPIDs() async throws {
        let brew = FakeBrew()
        await brew.respond(to: "info", stdout: infoJSON)
        let snapshot = try await collector(brew).collect()
        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.services.map(\.pid), [750])
        let calls = await brew.calls
        XCTAssertEqual(calls, [["services", "info", "--all", "--json"]])
    }

    func testResultsAreCachedForAsLongAsTheCallerAccepts() async throws {
        let brew = FakeBrew()
        await brew.respond(to: "info", stdout: infoJSON)
        let collector = collector(brew)

        _ = try await collector.collect(maxAge: 30)
        _ = try await collector.collect(maxAge: 30)
        _ = try await collector.collect(maxAge: 300)
        var calls = await brew.calls
        XCTAssertEqual(calls.count, 1, "brew is slow; do not run it again while the list is fresh")

        _ = try await collector.collect(maxAge: 0)
        calls = await brew.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testFallsBackToTheListFormOnOlderHomebrew() async throws {
        let brew = FakeBrew()
        await brew.respond(to: "info", status: 1, stderr: "Error: Unknown command: info")
        await brew.respond(to: "list", stdout: listJSON)
        let collector = collector(brew)

        let snapshot = try await collector.collect(maxAge: 0)
        XCTAssertEqual(snapshot.services.map(\.name), ["redis"])
        _ = try await collector.collect(maxAge: 0)
        let calls = await brew.calls
        XCTAssertEqual(calls.map { $0[1] }, ["info", "list", "list"], "info is not tried again")
    }

    func testActionsRunTheRightCommandAndInvalidateTheCache() async throws {
        let brew = FakeBrew()
        await brew.respond(to: "info", stdout: infoJSON)
        await brew.respond(to: "stop", stdout: "==> Successfully stopped `redis`")
        await brew.respond(to: "start")
        await brew.respond(to: "restart")
        let collector = collector(brew)

        _ = try await collector.collect()
        try await collector.perform(.stop, on: "redis")
        _ = try await collector.collect()
        try await collector.perform(.start, on: "redis")
        try await collector.perform(.restart, on: "postgresql@17")

        let calls = await brew.calls
        XCTAssertEqual(calls, [
            ["services", "info", "--all", "--json"],
            ["services", "stop", "redis"],
            ["services", "info", "--all", "--json"],
            ["services", "start", "redis"],
            ["services", "restart", "postgresql@17"],
        ])
    }

    func testFailedActionSurfacesBrewsMessage() async {
        let brew = FakeBrew()
        await brew.respond(to: "start", status: 1, stderr: "Error: Formula `nope` is not installed.\n")
        do {
            try await collector(brew).perform(.start, on: "nope")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BrewError, .failed("Error: Formula `nope` is not installed."))
        }
    }

    func testRealHomebrewListIsReadableWhenInstalled() async throws {
        // Read-only: lists services, never starts or stops one.
        try XCTSkipIf(BrewLocator.locate() == nil, "Homebrew is not installed")
        let snapshot = try await BrewCollector().collect(maxAge: 0)
        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertTrue(snapshot.services.allSatisfy { !$0.name.isEmpty })
    }
}

final class StrayMergerTests: XCTestCase {
    private var home: TemporaryDirectory!
    private var merger: StrayMerger!

    override func setUpWithError() throws {
        home = try TemporaryDirectory()
        try home.write(#"{"name": "shop"}"#, to: "code/shop/package.json")
        merger = StrayMerger(projectResolver: ProjectResolver(homeDirectory: home.path))
    }

    private func process(_ pid: Int32, title: String, category: Stray.Category = .app, ports: [UInt16] = [], children: [Int32] = [], start: UInt64 = 1_000, memory: UInt64 = 0) -> Stray {
        let root = makeDetails(makeEntry(pid, name: title, start: start), memory: memory)
        let descendants = children.map { makeDetails(makeEntry($0, parent: pid)) }
        return Stray(
            id: "process:\(pid)",
            kind: .process(ProcessGroup(root: root, descendants: descendants)),
            category: category,
            title: title,
            ports: ports.map { PortSummary(port: $0, transport: .tcp, addresses: ["*"], isLANVisible: true, pid: pid) },
            startedAt: Date(timeIntervalSince1970: TimeInterval(start)),
            cpuPercent: 2,
            memoryBytes: memory
        )
    }

    private func container(_ id: String, name: String, running: Bool = true, hostPorts: [UInt16] = [], compose: String? = nil, workingDirectory: String? = nil, image: String = "postgres:17") -> DockerContainer {
        DockerContainer(
            id: id, name: name, image: image, state: running ? .running : .exited,
            startedAt: running ? Date(timeIntervalSince1970: 500) : nil,
            ports: hostPorts.map { .init(hostIP: "0.0.0.0", hostPort: $0, containerPort: 80, transport: .tcp) },
            composeProject: compose, composeWorkingDirectory: workingDirectory,
            cpuPercent: running ? 3 : nil, memoryBytes: running ? 50 : nil
        )
    }

    // MARK: - Homebrew

    func testRunningBrewServiceTakesOverItsProcess() throws {
        let postgres = process(755, title: "postgres -D data", ports: [5432], children: [756, 757], memory: 900)
        let merged = merger.merge(
            processes: [postgres, process(900, title: "Notion", ports: [49385])],
            docker: .unavailable,
            brew: BrewSnapshot(isAvailable: true, services: [BrewService(name: "postgresql@17", status: .started, pid: 755)])
        )

        XCTAssertEqual(merged.map(\.id).sorted(), ["brew:postgresql@17", "process:900"], "the process is not listed a second time")
        let service = try XCTUnwrap(merged.first { $0.id == "brew:postgresql@17" })
        XCTAssertEqual(service.category, .brew)
        XCTAssertEqual(service.title, "postgresql@17")
        XCTAssertEqual(service.subtitle, "Homebrew · Started")
        XCTAssertEqual(service.ports.map(\.port), [5432])
        XCTAssertEqual(service.memoryBytes, 900)
        XCTAssertEqual(service.processGroup?.members.map(\.pid), [755, 756, 757])
        XCTAssertTrue(service.isRunning)
        XCTAssertNil(service.signalRoot, "a service is stopped through brew, never by signal")
    }

    func testBrewServiceIsMatchedThroughAnyMemberOfTheTree() {
        let wrapper = process(100, title: "wrapper", children: [101])
        let merged = merger.merge(processes: [wrapper], docker: .unavailable, brew: BrewSnapshot(isAvailable: true, services: [BrewService(name: "svc", status: .started, pid: 101)]))
        XCTAssertEqual(merged.map(\.id), ["brew:svc"])
    }

    func testStoppedBrewServiceIsListedWithoutAProcess() throws {
        let merged = merger.merge(processes: [], docker: .unavailable, brew: BrewSnapshot(isAvailable: true, services: [BrewService(name: "redis", status: .stopped)]))
        let service = try XCTUnwrap(merged.first)
        XCTAssertFalse(service.isRunning)
        XCTAssertNil(service.processGroup)
        XCTAssertTrue(service.ports.isEmpty)
        XCTAssertEqual(service.subtitle, "Homebrew · Stopped")
    }

    func testStartedServiceWhoseProcessWeCannotFindStillShows() throws {
        let merged = merger.merge(processes: [], docker: .unavailable, brew: BrewSnapshot(isAvailable: true, services: [BrewService(name: "redis", status: .started, pid: 4242)]))
        XCTAssertEqual(merged.first?.isRunning, true)
        XCTAssertNil(merged.first?.processGroup)
    }

    // MARK: - Docker

    func testContainerBecomesAStrayWithItsPublishedPorts() throws {
        let merged = merger.merge(
            processes: [],
            docker: DockerSnapshot(isAvailable: true, containers: [container("abc", name: "shop-db-1", hostPorts: [54329], image: "ghcr.io/acme/postgres:17@sha256:deadbeef")]),
            brew: .unavailable
        )
        let stray = try XCTUnwrap(merged.first)
        XCTAssertEqual(stray.id, "docker:abc")
        XCTAssertEqual(stray.category, .docker)
        XCTAssertEqual(stray.title, "shop-db-1")
        XCTAssertEqual(stray.subtitle, "acme/postgres:17")
        XCTAssertEqual(stray.ports.map(\.port), [54329])
        XCTAssertTrue(stray.isLANVisible)
        XCTAssertEqual(stray.cpuPercent, 3)
        XCTAssertEqual(stray.memoryBytes, 50)
        XCTAssertEqual(stray.startedAt, Date(timeIntervalSince1970: 500))
        XCTAssertNil(stray.processGroup)
        XCTAssertNil(stray.signalRoot)
    }

    func testStoppedContainerHasNoPortsAndSortsAfterRunningThings() {
        let merged = merger.merge(
            processes: [process(1_000, title: "Notion", ports: [1])],
            docker: DockerSnapshot(isAvailable: true, containers: [
                container("z", name: "zeta", running: false, hostPorts: [9090]),
                container("a", name: "alpha", running: false),
                container("r", name: "running"),
            ]),
            brew: .unavailable
        )
        XCTAssertEqual(merged.map(\.title), ["Notion", "running", "alpha", "zeta"])
        XCTAssertTrue(merged[3].ports.isEmpty, "a stopped container is not listening")
        XCTAssertFalse(merged[2].isRunning)
    }

    func testDockerHelperThatOnlyHoldsPublishedPortsDisappears() {
        let helper = process(19_201, title: "Docker", ports: [8080, 54329])
        let merged = merger.merge(
            processes: [helper],
            docker: DockerSnapshot(isAvailable: true, containers: [container("a", name: "api", hostPorts: [8080]), container("b", name: "db", hostPorts: [54329])]),
            brew: .unavailable
        )
        XCTAssertEqual(merged.map(\.title).sorted(), ["api", "db"])
    }

    func testDockerHelperKeepsPortsThatAreItsOwn() throws {
        let helper = process(19_201, title: "Docker", ports: [8080, 2375])
        let merged = merger.merge(
            processes: [helper],
            docker: DockerSnapshot(isAvailable: true, containers: [container("a", name: "api", hostPorts: [8080])]),
            brew: .unavailable
        )
        XCTAssertEqual(try XCTUnwrap(merged.first { $0.title == "Docker" }).ports.map(\.port), [2375])
    }

    func testPortsOfStoppedContainersAreNotTakenFromProcesses() throws {
        // Something else has since claimed the port a stopped container used.
        let server = process(50, title: "nginx", ports: [8080])
        let merged = merger.merge(
            processes: [server],
            docker: DockerSnapshot(isAvailable: true, containers: [container("a", name: "old", running: false, hostPorts: [8080])]),
            brew: .unavailable
        )
        XCTAssertEqual(try XCTUnwrap(merged.first { $0.title == "nginx" }).ports.map(\.port), [8080])
    }

    func testDevProcessKeepsAPortThatAContainerAlsoPublishes() throws {
        let dev = process(60, title: "node proxy.js", category: .dev, ports: [8080])
        let merged = merger.merge(
            processes: [dev],
            docker: DockerSnapshot(isAvailable: true, containers: [container("a", name: "api", hostPorts: [8080])]),
            brew: .unavailable
        )
        XCTAssertEqual(try XCTUnwrap(merged.first { $0.category == .dev }).ports.map(\.port), [8080])
    }

    // MARK: - Projects

    func testComposeContainerJoinsTheProjectInItsWorkingDirectory() throws {
        let directory = home.path + "/code/shop"
        let merged = merger.merge(
            processes: [],
            docker: DockerSnapshot(isAvailable: true, containers: [container("a", name: "shop-db-1", compose: "shop_compose", workingDirectory: directory)]),
            brew: .unavailable
        )
        let project = try XCTUnwrap(merged.first?.project)
        XCTAssertEqual(project.name, "shop", "the same project its dev processes resolve to")
        XCTAssertEqual(project.rootPath, directory)
    }

    func testComposeProjectWithoutARecognisableFolderStillGroups() throws {
        let gone = merger.merge(
            processes: [],
            docker: DockerSnapshot(isAvailable: true, containers: [container("a", name: "x", compose: "legacy", workingDirectory: "/Volumes/Gone/legacy")]),
            brew: .unavailable
        )
        XCTAssertEqual(gone.first?.project?.name, "legacy")
        XCTAssertEqual(gone.first?.project?.rootPath, "/Volumes/Gone/legacy")

        let labelOnly = merger.merge(
            processes: [],
            docker: DockerSnapshot(isAvailable: true, containers: [container("b", name: "y", compose: "stack")]),
            brew: .unavailable
        )
        XCTAssertEqual(labelOnly.first?.project?.id, "compose:stack")
    }

    func testPlainContainerHasNoProject() {
        let merged = merger.merge(processes: [], docker: DockerSnapshot(isAvailable: true, containers: [container("a", name: "scratch")]), brew: .unavailable)
        XCTAssertNil(merged.first?.project)
    }

    func testShortImageNames() {
        XCTAssertEqual(StrayMerger.shortImageName("postgres:17-alpine"), "postgres:17-alpine")
        XCTAssertEqual(StrayMerger.shortImageName("acme/sync-service:latest"), "acme/sync-service:latest")
        XCTAssertEqual(StrayMerger.shortImageName("ghcr.io/acme/tool:1.2@sha256:abcdef"), "acme/tool:1.2")
        XCTAssertEqual(StrayMerger.shortImageName("localhost:5000/team/api"), "team/api")
        XCTAssertEqual(StrayMerger.shortImageName("sha256:0123456789abcdef0123"), "0123456789ab")
    }

    func testSearchFindsContainersAndServices() {
        let merged = merger.merge(
            processes: [],
            docker: DockerSnapshot(isAvailable: true, containers: [container("abcdef123456789", name: "shop-db-1", compose: "shop")]),
            brew: BrewSnapshot(isAvailable: true, services: [BrewService(name: "redis", status: .started, command: "/opt/homebrew/opt/redis/bin/redis-server")])
        )
        let database = merged.first { $0.category == .docker }!
        let redis = merged.first { $0.category == .brew }!
        for query in ["docker", "postgres:17", "abcdef123456", "shop"] { XCTAssertTrue(database.matches(query: query), query) }
        for query in ["brew", "homebrew", "redis-server", "started"] { XCTAssertTrue(redis.matches(query: query), query) }
    }
}

final class ServiceSubtreeTests: XCTestCase {
    func testServiceRootOwnsItsWholeSubtreeLikeADevProcess() throws {
        let home = try TemporaryDirectory()
        let builder = StrayBuilder(projectResolver: ProjectResolver(homeDirectory: home.path), currentUID: 501)
        let postmaster = makeDetails(makeEntry(755, name: "postgres", uid: 501), path: "/opt/homebrew/opt/postgresql@17/bin/postgres", memory: 5)
        let worker = makeDetails(makeEntry(756, parent: 755, name: "postgres", uid: 501), memory: 40)
        let writer = makeDetails(makeEntry(757, parent: 755, name: "postgres", uid: 501), memory: 30)

        let all = [postmaster, worker, writer]
        let scan = ProcessScan(
            table: ProcessTable(entries: all.map(\.entry)),
            ports: [ListeningPort(pid: 755, port: 5432, transport: .tcp, address: "127.0.0.1")],
            details: Dictionary(uniqueKeysWithValues: all.map { ($0.pid, $0) }),
            devProcesses: [:],
            subtreeOwners: [755]
        )
        let stray = try XCTUnwrap(builder.build(from: scan).first)
        XCTAssertEqual(stray.processGroup?.members.map(\.pid), [755, 756, 757])
        XCTAssertEqual(stray.memoryBytes, 75, "workers count towards the service")
        XCTAssertEqual(stray.category, .app, "it only becomes a brew item once merged")
    }

    func testServiceRootWithoutAPortIsStillBuilt() throws {
        let home = try TemporaryDirectory()
        let builder = StrayBuilder(projectResolver: ProjectResolver(homeDirectory: home.path), currentUID: 501)
        let daemon = makeDetails(makeEntry(800, name: "dnsmasq", uid: 501))
        let scan = ProcessScan(
            table: ProcessTable(entries: [daemon.entry]),
            ports: [],
            details: [800: daemon],
            devProcesses: [:],
            subtreeOwners: [800]
        )
        XCTAssertEqual(builder.build(from: scan).compactMap { $0.processGroup?.root.pid }, [800])
    }
}

/// The monitor end to end, with the fake Docker daemon and a fake brew.
final class MonitorSourcesTests: XCTestCase {
    func testMergesContainersAndServicesIntoTheSnapshot() async throws {
        let fake = try FakeDocker()
        defer { fake.shutDown() }
        let home = try TemporaryDirectory()
        let path = fake.socketPath

        let brew = FakeBrew()
        await brew.respond(to: "info", stdout: #"[{"name":"redis","running":false,"status":"none"}]"#)
        await brew.respond(to: "start")

        let monitor = Monitor(
            homeDirectory: home.path,
            minimumAge: 0,
            sources: [.docker, .brew],
            dockerCollector: DockerCollector(locate: { path }),
            brewCollector: BrewCollector(brewPath: "/fake/brew") { _, arguments in await brew.run(arguments) }
        )

        let snapshot = await monitor.refresh()
        XCTAssertTrue(snapshot.isDockerAvailable)
        XCTAssertTrue(snapshot.isBrewAvailable)

        let database = try XCTUnwrap(snapshot.strays.first { $0.id == "docker:\(FakeDocker.runningID)" })
        XCTAssertTrue(database.isRunning)
        XCTAssertEqual(database.project?.name, "shop")
        XCTAssertEqual(database.ports.map(\.port), [54329])
        XCTAssertEqual(snapshot.strays.first { $0.id == "docker:\(FakeDocker.stoppedID)" }?.isRunning, false)
        XCTAssertEqual(snapshot.strays.first { $0.id == "brew:redis" }?.isRunning, false)

        // Actions go through the monitor and refresh the snapshot.
        try await monitor.perform(.stop, onContainer: FakeDocker.runningID)
        var latest = await monitor.latest
        XCTAssertEqual(latest.strays.first { $0.id == "docker:\(FakeDocker.runningID)" }?.isRunning, false)

        try await monitor.perform(.start, onContainer: FakeDocker.runningID)
        latest = await monitor.latest
        XCTAssertEqual(latest.strays.first { $0.id == "docker:\(FakeDocker.runningID)" }?.isRunning, true)

        try await monitor.stopComposeProject("shop")
        latest = await monitor.latest
        XCTAssertEqual(latest.strays.first { $0.id == "docker:\(FakeDocker.runningID)" }?.isRunning, false)

        let logs = try await monitor.containerLogs(id: FakeDocker.runningID)
        XCTAssertTrue(logs.contains("ready to accept connections"))

        try await monitor.perform(.start, onService: "redis")
        let calls = await brew.calls
        XCTAssertTrue(calls.contains(["services", "start", "redis"]))
    }

    func testVisibleContainersGetStats() async throws {
        let fake = try FakeDocker()
        defer { fake.shutDown() }
        let home = try TemporaryDirectory()
        let path = fake.socketPath
        let monitor = Monitor(homeDirectory: home.path, minimumAge: 0, sources: [.docker], dockerCollector: DockerCollector(locate: { path }))

        await monitor.setVisibleContainers([FakeDocker.runningID])
        _ = await monitor.refresh()
        let snapshot = await monitor.refresh()
        let database = try XCTUnwrap(snapshot.strays.first { $0.id == "docker:\(FakeDocker.runningID)" })
        XCTAssertEqual(database.cpuPercent, 20, accuracy: 0.01)
        XCTAssertEqual(database.memoryBytes, 80_000_000)
    }

    func testMissingDockerAndBrewAreCalmlyUnavailable() async throws {
        let home = try TemporaryDirectory()
        let monitor = Monitor(
            homeDirectory: home.path,
            minimumAge: 0,
            sources: [.docker, .brew],
            dockerCollector: DockerCollector(locate: { nil }),
            brewCollector: BrewCollector(brewPath: nil)
        )
        let snapshot = await monitor.refresh()
        XCTAssertFalse(snapshot.isDockerAvailable)
        XCTAssertFalse(snapshot.isBrewAvailable)
        XCTAssertFalse(snapshot.strays.contains { $0.category == .docker || $0.category == .brew })

        do {
            try await monitor.perform(.stop, onContainer: "x")
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? DockerError, .unavailable)
        }
    }
}
