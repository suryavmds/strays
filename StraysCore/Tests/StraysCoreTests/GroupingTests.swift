import XCTest
@testable import StraysCore

final class ProcessTableTests: XCTestCase {
    private let table = ProcessTable(entries: [
        makeEntry(1, parent: 0, name: "launchd"),
        makeEntry(10, parent: 1, name: "Terminal"),
        makeEntry(11, parent: 10, name: "zsh"),
        makeEntry(12, parent: 11, name: "npm"),
        makeEntry(13, parent: 12, name: "sh"),
        makeEntry(14, parent: 13, name: "node"),
        makeEntry(15, parent: 12, name: "esbuild"),
        makeEntry(99, parent: 4242, name: "orphan-of-missing-parent"),
    ])

    func testAncestorsAreNearestFirst() {
        XCTAssertEqual(table.ancestors(of: 14).map(\.pid), [13, 12, 11, 10, 1])
        XCTAssertTrue(table.ancestors(of: 1).isEmpty)
        XCTAssertTrue(table.ancestors(of: 99).isEmpty, "a parent that is not in the table ends the chain")
        XCTAssertTrue(table.ancestors(of: 5555).isEmpty)
    }

    func testDescendantsAreBreadthFirst() {
        XCTAssertEqual(table.descendants(of: 12).map(\.pid), [13, 15, 14])
        XCTAssertEqual(table.children(of: 12).map(\.pid), [13, 15])
        XCTAssertTrue(table.descendants(of: 14).isEmpty)
    }

    func testCyclesTerminate() {
        let looped = ProcessTable(entries: [
            makeEntry(2, parent: 3),
            makeEntry(3, parent: 2),
            makeEntry(4, parent: 4),
        ])
        XCTAssertEqual(looped.ancestors(of: 2).map(\.pid), [3])
        XCTAssertEqual(looped.descendants(of: 2).map(\.pid), [3])
        XCTAssertTrue(looped.ancestors(of: 4).isEmpty)
        XCTAssertTrue(looped.descendants(of: 4).isEmpty)
    }

    func testLiveTableKnowsThisProcessAndRootOwnedOnes() async throws {
        let live = try await ProcessTableCollector().collect()
        let me = try XCTUnwrap(live[getpid()])
        XCTAssertEqual(me.ppid, getppid())
        XCTAssertEqual(me.uid, getuid())
        XCTAssertEqual(live[1]?.uid, 0, "launchd is root's; we must still see it")
        XCTAssertEqual(live.ancestors(of: getpid()).last?.pid, 1)
        XCTAssertLessThan(abs(me.identity.startDate.timeIntervalSinceNow), 3_600)
    }
}

final class ProcessGrouperTests: XCTestCase {
    // launchd → Terminal → login → zsh → npm → sh → node
    //                                        └→ esbuild
    //                                 └→ python (a second job in the same shell)
    private let table = ProcessTable(entries: [
        makeEntry(1, parent: 0, name: "launchd"),
        makeEntry(10, parent: 1, name: "Terminal"),
        makeEntry(11, parent: 10, name: "login", uid: 0),
        makeEntry(12, parent: 11, name: "zsh"),
        makeEntry(20, parent: 12, name: "npm"),
        makeEntry(21, parent: 20, name: "sh"),
        makeEntry(22, parent: 21, name: "node"),
        makeEntry(23, parent: 20, name: "esbuild"),
        makeEntry(30, parent: 12, name: "python"),
    ])

    func testDevTreeCollapsesToItsTopmostDevProcess() {
        let roots = ProcessGrouper.roots(of: [20, 22, 23], absorbing: [20, 22, 23], in: table)
        XCTAssertEqual(roots, [20: 20, 22: 20, 23: 20])
    }

    func testSiblingJobsInOneShellStaySeparate() {
        let roots = ProcessGrouper.roots(of: [20, 22, 30], absorbing: [20, 22, 30], in: table)
        XCTAssertEqual(roots[22], 20)
        XCTAssertEqual(roots[30], 30)
    }

    func testIntermediateProcessesAreTransparent() {
        // Only npm and node are dev processes; the `sh` between them is not.
        XCTAssertEqual(ProcessGrouper.roots(of: [20, 22], absorbing: [20, 22], in: table)[22], 20)
    }

    func testOnlyAbsorbingProcessesBecomeRoots() {
        // Terminal listens on a port, but it is an app: it must not swallow
        // the dev server running inside it.
        let roots = ProcessGrouper.roots(of: [10, 22], absorbing: [22], in: table)
        XCTAssertEqual(roots, [10: 10, 22: 22])
    }

    func testClimbStopsAtABoundary() {
        // Treat npm as an agent boundary: node must not be folded into it.
        let roots = ProcessGrouper.roots(of: [22], absorbing: [20, 22], boundaries: [20], in: table)
        XCTAssertEqual(roots[22], 22)
    }
}

final class StrayBuilderTests: XCTestCase {
    private var home: TemporaryDirectory!
    private var builder: StrayBuilder!
    private let me: UInt32 = 501

    override func setUpWithError() throws {
        home = try TemporaryDirectory()
        try home.write(#"{"name": "shop"}"#, to: "code/shop/package.json")
        builder = StrayBuilder(projectResolver: ProjectResolver(homeDirectory: home.path), currentUID: me, excludedPIDs: [999])
    }

    private var project: String { home.path + "/code/shop" }
    private let node = DevClassification(runtimeID: "node", runtimeName: "Node.js", isInterpreter: true)

    private func scan(
        _ details: [ProcessDetails],
        ports: [ListeningPort] = [],
        dev: [Int32] = [],
        boundaries: Set<Int32> = []
    ) -> ProcessScan {
        ProcessScan(
            table: ProcessTable(entries: details.map(\.entry)),
            ports: ports,
            details: Dictionary(uniqueKeysWithValues: details.map { ($0.pid, $0) }),
            devProcesses: Dictionary(uniqueKeysWithValues: dev.map { ($0, node) }),
            boundaries: boundaries
        )
    }

    func testDevTreeBecomesOneStrayWithSummedUsage() throws {
        let npm = makeDetails(makeEntry(20, name: "node", uid: me, start: 5_000), path: "/usr/local/bin/node", arguments: ["node", "/usr/local/bin/npm", "run", "dev"], cwd: project, cpu: 1, memory: 100)
        let shell = makeDetails(makeEntry(21, parent: 20, name: "sh", uid: me), path: "/bin/sh", cwd: project, cpu: 0, memory: 10)
        let server = makeDetails(makeEntry(22, parent: 21, name: "node", uid: me), path: "/usr/local/bin/node", arguments: ["node", "/x/node_modules/.bin/next", "dev"], cwd: project, cpu: 30, memory: 400)

        let strays = builder.build(from: scan(
            [npm, shell, server],
            ports: [ListeningPort(pid: 22, port: 3000, transport: .tcp, address: "127.0.0.1"), ListeningPort(pid: 22, port: 3000, transport: .tcp, address: "::1")],
            dev: [20, 22]
        ))

        XCTAssertEqual(strays.count, 1)
        let stray = try XCTUnwrap(strays.first)
        XCTAssertEqual(stray.title, "npm run dev")
        XCTAssertEqual(stray.subtitle, "Node.js")
        XCTAssertEqual(stray.category, .dev)
        XCTAssertEqual(stray.project?.name, "shop")
        XCTAssertEqual(stray.ports.map(\.port), [3000])
        XCTAssertFalse(stray.isLANVisible)
        XCTAssertEqual(stray.cpuPercent, 31)
        XCTAssertEqual(stray.memoryBytes, 510)
        XCTAssertEqual(stray.processGroup?.members.map(\.pid), [20, 21, 22])
        XCTAssertEqual(stray.startedAt, Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(stray.id, "process:20.5000.0")
    }

    func testAppWithAPortIsShownAloneAndNamedByItsBundle() throws {
        let helperPath = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let helper = makeDetails(makeEntry(40, name: "Code Helper (Plu", uid: me), path: helperPath, arguments: ["Code Helper (Plugin)", "--stdio"], cwd: "/")
        let child = makeDetails(makeEntry(41, parent: 40, name: "git", uid: me), path: "/usr/bin/git", memory: 50)

        let stray = try XCTUnwrap(builder.build(from: scan([helper, child], ports: [ListeningPort(pid: 40, port: 57482, transport: .tcp, address: "127.0.0.1")])).first)
        XCTAssertEqual(stray.category, .app)
        XCTAssertEqual(stray.title, "Visual Studio Code")
        XCTAssertEqual(stray.subtitle, "Code Helper (Plugin)")
        XCTAssertNil(stray.project)
        XCTAssertEqual(stray.processGroup?.members.map(\.pid), [40], "an app's children are not part of the item")
    }

    func testOtherUsersListenersAreSystemItems() throws {
        let daemon = makeDetails(makeEntry(50, name: "httpd", uid: 0), path: "/usr/sbin/httpd", isInspectable: false)
        let stray = try XCTUnwrap(builder.build(from: scan([daemon], ports: [ListeningPort(pid: 50, port: 80, transport: .tcp, address: "*")])).first)
        XCTAssertEqual(stray.category, .system)
        XCTAssertEqual(stray.title, "httpd")
        XCTAssertTrue(stray.isLANVisible)
    }

    func testUDPAloneDoesNotMakeAProcessInteresting() {
        let chatty = makeDetails(makeEntry(60, name: "mDNSResponder", uid: me), path: "/usr/sbin/mDNSResponder")
        let strays = builder.build(from: scan([chatty], ports: [ListeningPort(pid: 60, port: 5353, transport: .udp, address: "*")]))
        XCTAssertTrue(strays.isEmpty)
    }

    func testUDPPortsAreListedOnItemsThatAlreadyQualify() throws {
        let server = makeDetails(makeEntry(61, name: "node", uid: me), path: "/usr/local/bin/node", arguments: ["node", "server.js"], cwd: project)
        let stray = try XCTUnwrap(builder.build(from: scan(
            [server],
            ports: [ListeningPort(pid: 61, port: 4000, transport: .tcp, address: "*"), ListeningPort(pid: 61, port: 4001, transport: .udp, address: "*")],
            dev: [61]
        )).first)
        XCTAssertEqual(stray.ports.map(\.id), ["tcp:4000", "udp:4001"])
        XCTAssertEqual(stray.primaryPort?.port, 4000)
    }

    func testDevProcessWithoutAPortIsListed() throws {
        let worker = makeDetails(makeEntry(70, name: "python3", uid: me), path: "/usr/bin/python3", arguments: ["python3", "worker.py"], cwd: project)
        let stray = try XCTUnwrap(builder.build(from: scan([worker], dev: [70])).first)
        XCTAssertEqual(stray.title, "python3 worker.py")
        XCTAssertTrue(stray.ports.isEmpty)
        XCTAssertNil(stray.primaryPort)
    }

    func testExcludedProcessesNeverAppear() {
        let myself = makeDetails(makeEntry(999, name: "Strays", uid: me), path: "/Applications/Strays.app/Contents/MacOS/Strays")
        let strays = builder.build(from: scan([myself], ports: [ListeningPort(pid: 999, port: 1234, transport: .tcp, address: "127.0.0.1")]))
        XCTAssertTrue(strays.isEmpty)
    }

    func testProjectFallsBackToADescendantsWorkingDirectory() throws {
        let launcher = makeDetails(makeEntry(80, name: "node", uid: me), path: "/usr/local/bin/node", arguments: ["node", "run.js"], cwd: home.path)
        let server = makeDetails(makeEntry(81, parent: 80, name: "node", uid: me), path: "/usr/local/bin/node", cwd: project)
        let stray = try XCTUnwrap(builder.build(from: scan([launcher, server], dev: [80, 81])).first)
        XCTAssertEqual(stray.project?.name, "shop")
    }

    func testNewestStraysComeFirst() {
        let old = makeDetails(makeEntry(90, name: "node", uid: me, start: 100), path: "/usr/local/bin/node", cwd: project)
        let new = makeDetails(makeEntry(91, name: "node", uid: me, start: 900), path: "/usr/local/bin/node", cwd: project)
        let strays = builder.build(from: scan([old, new], dev: [90, 91]))
        XCTAssertEqual(strays.compactMap { $0.processGroup?.root.pid }, [91, 90])
    }

    func testBoundaryKeepsAnAgentsChildrenOutOfTheAgent() {
        // 100 is an agent (a boundary), running node, which would otherwise
        // look like a dev process and absorb the server it started.
        let agent = makeDetails(makeEntry(100, name: "node", uid: me), path: "/usr/local/bin/node", cwd: project)
        let server = makeDetails(makeEntry(101, parent: 100, name: "node", uid: me), path: "/usr/local/bin/node", arguments: ["node", "server.js"], cwd: project)
        let strays = builder.build(from: scan([agent, server], dev: [101], boundaries: [100]))
        XCTAssertEqual(strays.compactMap { $0.processGroup?.root.pid }, [101])
    }
}
