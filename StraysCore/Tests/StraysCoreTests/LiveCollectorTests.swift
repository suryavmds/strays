import Darwin
import XCTest
@testable import StraysCore

/// These tests run against the real machine. Everything they look for is a
/// throwaway process the test started, and every one is stopped afterwards.
final class PortCollectorLiveTests: XCTestCase {
    func testFindsAThrowawayHTTPServer() async throws {
        let port = freeLoopbackPort()
        let server = try ThrowawayProcess.httpServer(port: port)
        defer { server.stop() }

        let collector = PortCollector(includeOtherUsers: false)
        let ports = try await collector.collect()
        let found = try XCTUnwrap(ports.first { $0.port == port }, "port \(port) was not found")

        XCTAssertEqual(found.pid, server.pid)
        XCTAssertEqual(found.transport, .tcp)
        XCTAssertEqual(found.address, "127.0.0.1")
        XCTAssertFalse(found.isLANVisible)
        let source = await collector.lastSource
        XCTAssertEqual(source, .libproc)
    }

    func testPortDisappearsWhenTheServerStops() async throws {
        let port = freeLoopbackPort()
        let server = try ThrowawayProcess.httpServer(port: port)
        let collector = PortCollector(includeOtherUsers: false)

        let before = try await collector.collect()
        XCTAssertTrue(before.contains { $0.port == port })

        server.stop()
        let gone = try await eventually {
            try await !collector.collect().contains { $0.port == port }
        }
        XCTAssertTrue(gone)
    }

    func testLsofFallbackFindsTheSameServer() async throws {
        let port = freeLoopbackPort()
        let server = try ThrowawayProcess.httpServer(port: port)
        defer { server.stop() }

        let ports = try await PortCollector.scanWithLsof()
        let found = try XCTUnwrap(ports.first { $0.port == port })
        XCTAssertEqual(found.pid, server.pid)
        XCTAssertEqual(found.address, "127.0.0.1")
    }

    /// Sockets opened by the test process itself: IPv6 loopback TCP, and UDP.
    func testDecodesIPv6AndUDPSockets() async throws {
        let tcp6 = socket(AF_INET6, SOCK_STREAM, 0)
        let udp = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(tcp6); close(udp) }

        var v6 = sockaddr_in6()
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6.sin6_family = sa_family_t(AF_INET6)
        v6.sin6_addr = in6addr_loopback
        let boundV6 = withUnsafePointer(to: &v6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(tcp6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        try XCTSkipIf(boundV6 != 0, "IPv6 loopback is unavailable")
        XCTAssertEqual(listen(tcp6, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        withUnsafeMutablePointer(to: &v6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(tcp6, $0, &length) }
        }
        let tcpPort = UInt16(bigEndian: v6.sin6_port)

        var v4 = loopbackAddress(port: 0)
        let boundV4 = withUnsafePointer(to: &v4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(udp, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(boundV4, 0)
        length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &v4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(udp, $0, &length) }
        }
        let udpPort = UInt16(bigEndian: v4.sin_port)

        let mine = try await PortCollector(includeOtherUsers: false).collect().filter { $0.pid == getpid() }
        XCTAssertTrue(mine.contains(ListeningPort(pid: getpid(), port: tcpPort, transport: .tcp, address: "::1")), "\(mine)")
        XCTAssertTrue(mine.contains(ListeningPort(pid: getpid(), port: udpPort, transport: .udp, address: "127.0.0.1")), "\(mine)")
    }

    /// A connected (not listening) TCP socket must not be reported.
    func testConnectedSocketsAreNotListeners() async throws {
        let port = freeLoopbackPort()
        let server = try ThrowawayProcess.httpServer(port: port)
        defer { server.stop() }

        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var address = loopbackAddress(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)

        let mine = try await PortCollector(includeOtherUsers: false).collect().filter { $0.pid == getpid() && $0.transport == .tcp }
        XCTAssertTrue(mine.isEmpty, "\(mine)")
    }
}

final class ProcessInspectorLiveTests: XCTestCase {
    private func entry(for process: ThrowawayProcess) throws -> ProcessEntry {
        try XCTUnwrap(LibProc.entry(for: process.pid))
    }

    func testReadsArgumentsEnvironmentAndWorkingDirectory() async throws {
        let directory = try TemporaryDirectory()
        let port = freeLoopbackPort()
        let server = try ThrowawayProcess.httpServer(port: port, cwd: directory.url, environment: ["STRAYS_TEST_MARKER": "hello-\(port)"])
        defer { server.stop() }

        let entry = try entry(for: server)
        XCTAssertEqual(entry.ppid, getpid())
        XCTAssertEqual(entry.uid, getuid())
        XCTAssertLessThan(abs(entry.identity.startDate.timeIntervalSinceNow), 60)

        let all = await ProcessInspector().details(for: [entry])
        let details = try XCTUnwrap(all[server.pid])

        XCTAssertTrue(details.isInspectable)
        XCTAssertEqual(Array(details.arguments.suffix(5)), ["-m", "http.server", String(port), "--bind", "127.0.0.1"])
        XCTAssertEqual(details.environment["STRAYS_TEST_MARKER"], "hello-\(port)")
        XCTAssertEqual(details.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, directory.path)
        XCTAssertEqual(details.username, NSUserName())
        XCTAssertTrue(details.executableName.lowercased().hasPrefix("python"), details.executableName)
        XCTAssertGreaterThan(details.residentBytes, 1 << 20)
    }

    func testMeasuresCPUAcrossTwoReadings() async throws {
        let busy = try ThrowawayProcess(ThrowawayProcess.python, ["-c", "while True: pass"])
        let idle = try ThrowawayProcess.sleeper()
        defer { busy.stop(); idle.stop() }

        let inspector = ProcessInspector()
        let entries = [try entry(for: busy), try entry(for: idle)]
        let first = await inspector.details(for: entries)
        XCTAssertEqual(first[busy.pid]?.cpuPercent, 0, "the first reading has nothing to compare against")

        try await Task.sleep(for: .milliseconds(700))
        let second = await inspector.details(for: entries)
        XCTAssertGreaterThan(try XCTUnwrap(second[busy.pid]).cpuPercent, 40)
        XCTAssertLessThan(try XCTUnwrap(second[idle.pid]).cpuPercent, 10)
    }

    func testRootOwnedProcessIsReportedWithoutDetails() async throws {
        let launchd = try XCTUnwrap(LibProc.entry(for: 1))
        let all = await ProcessInspector().details(for: [launchd])
        let details = try XCTUnwrap(all[1])
        XCTAssertFalse(details.isInspectable)
        XCTAssertEqual(details.username, "root")
        XCTAssertEqual(details.executablePath, "/sbin/launchd")
        XCTAssertTrue(details.arguments.isEmpty)
        XCTAssertTrue(details.environment.isEmpty)
        XCTAssertEqual(details.cpuPercent, 0)
    }

    func testDeadProcessDoesNotCrashTheInspector() async throws {
        let short = try ThrowawayProcess.sleeper()
        let entry = try entry(for: short)
        short.stop()

        let details = await ProcessInspector().details(for: [entry])[entry.pid]
        XCTAssertEqual(details?.isInspectable, false)
        XCTAssertNil(LibProc.entry(for: entry.pid))
    }

    func testIdentityDistinguishesAReusedPID() throws {
        let process = try ThrowawayProcess.sleeper()
        defer { process.stop() }
        let identity = try entry(for: process).identity
        let impostor = ProcessIdentity(pid: identity.pid, startSeconds: identity.startSeconds - 60, startMicroseconds: 0)
        XCTAssertNotEqual(identity, impostor)
        XCTAssertEqual(LibProc.entry(for: process.pid)?.identity, identity, "the start time is stable across reads")
    }
}

final class MonitorLiveTests: XCTestCase {
    private var home: TemporaryDirectory!

    override func setUpWithError() throws {
        home = try TemporaryDirectory()
        try home.write(#"{"name": "strays-fixture"}"#, to: "code/fixture/package.json")
    }

    private var projectURL: URL { home.url.appendingPathComponent("code/fixture") }

    private func monitor() -> Monitor {
        // No agent profiles: these tests must behave the same whether or
        // not the test run itself was started by an AI agent.
        Monitor(homeDirectory: home.path, minimumAge: 0, sources: [], agents: AgentCatalog(agents: []))
    }

    func testServerInAProjectIsADevStrayWithItsPort() async throws {
        let port = freeLoopbackPort()
        let server = try ThrowawayProcess.httpServer(port: port, cwd: projectURL)
        defer { server.stop() }

        let snapshot = await monitor().refresh()
        let stray = try XCTUnwrap(snapshot.strays.first { $0.processGroup?.root.pid == server.pid })

        XCTAssertEqual(stray.category, .dev)
        XCTAssertEqual(stray.subtitle, "Python")
        XCTAssertEqual(stray.project?.name, "strays-fixture")
        XCTAssertEqual(stray.ports.map(\.port), [port])
        XCTAssertTrue(stray.title.contains("http.server"), stray.title)
        XCTAssertFalse(stray.isLANVisible)
    }

    func testWorkerWithoutAPortIsStillFound() async throws {
        let worker = try ThrowawayProcess.sleeper(cwd: projectURL)
        defer { worker.stop() }

        let snapshot = await monitor().refresh()
        let stray = try XCTUnwrap(snapshot.strays.first { $0.processGroup?.root.pid == worker.pid })
        XCTAssertEqual(stray.category, .dev)
        XCTAssertTrue(stray.ports.isEmpty)
        XCTAssertEqual(stray.project?.name, "strays-fixture")
    }

    func testWorkerOutsideHomeIsNotADevStray() async throws {
        let elsewhere = try TemporaryDirectory()
        let worker = try ThrowawayProcess.sleeper(cwd: elsewhere.url)
        defer { worker.stop() }

        let snapshot = await monitor().refresh()
        XCTAssertNil(snapshot.strays.first { $0.processGroup?.root.pid == worker.pid })
    }

    func testMonitorNeverListsItself() async {
        let snapshot = await monitor().refresh()
        XCTAssertFalse(snapshot.strays.contains { $0.processGroup?.members.contains { $0.pid == getpid() } ?? false })
    }

    func testSubscribersReceiveSnapshotsWhileActive() async throws {
        let worker = try ThrowawayProcess.sleeper(cwd: projectURL)
        defer { worker.stop() }

        let monitor = monitor()
        let stream = await monitor.snapshots()
        await monitor.setCadence(.active)
        defer { Task { await monitor.stop() } }

        var received: StraysSnapshot?
        for await snapshot in stream {
            received = snapshot
            break
        }
        let snapshot = try XCTUnwrap(received)
        XCTAssertTrue(snapshot.strays.contains { $0.processGroup?.root.pid == worker.pid })
        XCTAssertLessThan(snapshot.scanDuration, 2)
    }

    func testStoppedStrayDropsOutOfTheNextSnapshot() async throws {
        let worker = try ThrowawayProcess.sleeper(cwd: projectURL)
        let monitor = monitor()
        let pid = worker.pid

        let before = await monitor.refresh()
        XCTAssertTrue(before.strays.contains { $0.processGroup?.root.pid == pid })

        worker.stop()
        let after = await monitor.refresh()
        XCTAssertFalse(after.strays.contains { $0.processGroup?.root.pid == pid })
    }
}
