import XCTest
@testable import StraysCore

final class HTTPResponseParserTests: XCTestCase {
    private func parse(_ text: String) throws -> HTTPResponse {
        try HTTPResponseParser.parse(Data(text.utf8))
    }

    func testParsesStatusHeadersAndBody() throws {
        let response = try parse("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n[]")
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertEqual(response.bodyText, "[]")
    }

    func testHeaderNamesAreCaseInsensitive() throws {
        let response = try parse("HTTP/1.1 204 No Content\r\nAPI-VERSION: 1.56\r\n\r\n")
        XCTAssertEqual(response.headers["api-version"], "1.56")
        XCTAssertTrue(response.body.isEmpty)
    }

    func testContentLengthTrimsTrailingBytes() throws {
        XCTAssertEqual(try parse("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabcEXTRA").bodyText, "abc")
    }

    func testDecodesChunkedBodies() throws {
        let response = try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n7;ext=1\r\n, world\r\n0\r\n\r\n")
        XCTAssertEqual(response.bodyText, "hello, world")
    }

    func testChunkedBodyCutOffMidStreamKeepsWhatArrived() {
        XCTAssertEqual(HTTPResponseParser.decodeChunked(Data("5\r\nhello\r\nA\r\nwor".utf8)).map { String(decoding: $0, as: UTF8.self) }, "hellowor")
    }

    func testBodyMayContainTheHeaderTerminator() throws {
        XCTAssertEqual(try parse("HTTP/1.1 200 OK\r\n\r\nline\r\n\r\nmore").bodyText, "line\r\n\r\nmore")
    }

    func testErrorStatusesAreNotSuccess() throws {
        let response = try parse("HTTP/1.1 409 Conflict\r\nContent-Length: 0\r\n\r\n")
        XCTAssertEqual(response.status, 409)
        XCTAssertFalse(response.isSuccess)
    }

    func testRejectsGarbage() {
        for text in ["", "not http", "HTTP/1.1 abc OK\r\n\r\n", "HTTP/1.1 200 OK\r\nno terminator"] {
            XCTAssertThrowsError(try parse(text), text)
        }
        XCTAssertNil(HTTPResponseParser.decodeChunked(Data("zz\r\nhello".utf8)))
    }
}

final class DockerPayloadTests: XCTestCase {
    func testDecodesAContainerSummary() throws {
        let json = """
        [{"Id":"abc123def4567890","Names":["/shop-dev-postgres-1"],"Image":"postgres:17-alpine","Command":"docker-entrypoint.sh postgres",
          "Created":1791175902,"State":"running","Status":"Up 2 hours (healthy)",
          "Ports":[{"IP":"0.0.0.0","PrivatePort":5432,"PublicPort":54329,"Type":"tcp"},{"IP":"::","PrivatePort":5432,"PublicPort":54329,"Type":"tcp"},{"PrivatePort":8125,"Type":"udp"}],
          "Labels":{"com.docker.compose.project":"shop-dev","com.docker.compose.service":"postgres","com.docker.compose.project.working_dir":"/Users/me/shop"}}]
        """
        let container = try XCTUnwrap(JSONDecoder().decode([ContainerSummaryPayload].self, from: Data(json.utf8)).first?.container)

        XCTAssertEqual(container.name, "shop-dev-postgres-1")
        XCTAssertEqual(container.shortID, "abc123def456")
        XCTAssertEqual(container.state, .running)
        XCTAssertTrue(container.isRunning)
        XCTAssertEqual(container.composeProject, "shop-dev")
        XCTAssertEqual(container.composeService, "postgres")
        XCTAssertEqual(container.composeWorkingDirectory, "/Users/me/shop")
        XCTAssertEqual(container.createdAt, Date(timeIntervalSince1970: 1_791_175_902))
        XCTAssertEqual(container.ports.map(\.hostPort), [54329, 54329], "unpublished ports are dropped")
        XCTAssertEqual(Set(container.ports.map(\.hostIP)), ["0.0.0.0", "::"])

        let summary = try XCTUnwrap(container.portSummaries.first)
        XCTAssertEqual(container.portSummaries.count, 1, "both address families are one port")
        XCTAssertEqual(summary.port, 54329)
        XCTAssertTrue(summary.isLANVisible, "Docker publishes on every interface by default")
    }

    func testLoopbackPublishedPortIsNotLANVisible() throws {
        let json = #"[{"Id":"x","Names":["/local"],"State":"running","Ports":[{"IP":"127.0.0.1","PrivatePort":80,"PublicPort":8080,"Type":"tcp"}]}]"#
        let container = try XCTUnwrap(JSONDecoder().decode([ContainerSummaryPayload].self, from: Data(json.utf8)).first?.container)
        XCTAssertEqual(container.portSummaries.first?.isLANVisible, false)
    }

    func testToleratesMissingFieldsAndUnknownStates() throws {
        let json = #"[{"Id":"0123456789abcdef"},{"Id":"y","State":"removing","Names":[]}]"#
        let containers = try JSONDecoder().decode([ContainerSummaryPayload].self, from: Data(json.utf8)).map(\.container)
        XCTAssertEqual(containers[0].name, "0123456789ab")
        XCTAssertEqual(containers[0].state, .other(""))
        XCTAssertFalse(containers[0].isRunning)
        XCTAssertEqual(containers[1].state, .other("removing"))
    }

    func testStartTimeParsesNanosecondsAndTreatsYearOneAsNever() throws {
        func startedAt(_ value: String) throws -> Date? {
            try JSONDecoder().decode(ContainerInspectPayload.self, from: Data(#"{"State":{"StartedAt":"\#(value)"}}"#.utf8)).startedAt
        }
        XCTAssertEqual(try startedAt("2026-10-12T01:49:53.803283838Z"), ISO8601DateFormatter().date(from: "2026-10-12T01:49:53Z"))
        XCTAssertEqual(try startedAt("2026-10-12T01:49:53Z"), ISO8601DateFormatter().date(from: "2026-10-12T01:49:53Z"))
        XCTAssertNil(try startedAt("0001-01-01T00:00:00Z"))
    }

    private func stats(container: UInt64, system: UInt64, cpus: Int = 4, usage: UInt64 = 0, cache: [String: UInt64] = [:]) throws -> ContainerStatsPayload {
        let object: [String: Any] = [
            "cpu_stats": ["cpu_usage": ["total_usage": container], "system_cpu_usage": system, "online_cpus": cpus],
            "memory_stats": ["usage": usage, "stats": cache],
        ]
        return try JSONDecoder().decode(ContainerStatsPayload.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testCPUPercentComesFromTwoReadings() throws {
        let first = try stats(container: 1_000_000_000, system: 100_000_000_000)
        let second = try stats(container: 1_500_000_000, system: 110_000_000_000)
        // Half a second of container time over ten seconds of four cores.
        XCTAssertEqual(ContainerStatsPayload.cpuPercent(from: first, to: second), 20, accuracy: 0.001)
    }

    func testCPUPercentIsZeroWhenCountersDoNotAdvanceOrGoBackwards() throws {
        let reading = try stats(container: 5, system: 100)
        XCTAssertEqual(ContainerStatsPayload.cpuPercent(from: reading, to: reading), 0)
        XCTAssertEqual(ContainerStatsPayload.cpuPercent(from: try stats(container: 9, system: 200), to: reading), 0, "a restarted container resets its counters")
    }

    func testMemoryExcludesReclaimableCache() throws {
        XCTAssertEqual(try stats(container: 0, system: 0, usage: 90, cache: ["inactive_file": 10]).memoryBytes, 80)
        XCTAssertEqual(try stats(container: 0, system: 0, usage: 90, cache: ["total_inactive_file": 30]).memoryBytes, 60, "cgroup v1 name")
        XCTAssertEqual(try stats(container: 0, system: 0, usage: 90).memoryBytes, 90)
    }
}

final class DockerLogDecoderTests: XCTestCase {
    private func frame(_ stream: UInt8, _ text: String) -> Data {
        let payload = Data(text.utf8)
        var data = Data([stream, 0, 0, 0])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    func testDemultiplexesStdoutAndStderrInOrder() {
        let data = frame(1, "ready\n") + frame(2, "warning\n") + frame(1, "done\n")
        XCTAssertEqual(DockerLogDecoder.decode(data, isMultiplexed: true), "ready\nwarning\ndone\n")
    }

    func testRawTTYStreamsPassThrough() {
        let raw = Data("plain text from a tty\n".utf8)
        XCTAssertEqual(DockerLogDecoder.decode(raw, isMultiplexed: false), "plain text from a tty\n")
        XCTAssertEqual(DockerLogDecoder.decode(raw, isMultiplexed: true), "plain text from a tty\n", "falls back when the frames do not parse")
    }

    func testEmptyAndTruncatedInput() {
        XCTAssertEqual(DockerLogDecoder.decode(Data(), isMultiplexed: true), "")
        let truncated = frame(1, "complete\n") + frame(1, "cut off here").dropLast(4)
        XCTAssertEqual(DockerLogDecoder.decode(truncated, isMultiplexed: true), "complete\ncut off ")
    }
}

final class DockerSocketLocatorTests: XCTestCase {
    func testCandidatesFollowTheDocumentedOrder() {
        XCTAssertEqual(
            DockerSocketLocator.candidates(environment: ["DOCKER_HOST": "unix:///custom/docker.sock"], home: "/Users/me"),
            [
                "/custom/docker.sock",
                "/Users/me/.docker/run/docker.sock",
                "/var/run/docker.sock",
                "/Users/me/.orbstack/run/docker.sock",
                "/Users/me/.colima/default/docker.sock",
                "/Users/me/.rd/docker.sock",
            ]
        )
    }

    func testRemoteAndEmptyDockerHostsAreIgnored() {
        for host in ["tcp://10.0.0.5:2375", "ssh://box", "", "unix://"] {
            XCTAssertEqual(DockerSocketLocator.candidates(environment: ["DOCKER_HOST": host], home: "/h").first, "/h/.docker/run/docker.sock", host)
        }
    }

    func testDuplicateCandidatesAreListedOnce() {
        let candidates = DockerSocketLocator.candidates(environment: ["DOCKER_HOST": "unix:///var/run/docker.sock"], home: "/h")
        XCTAssertEqual(candidates.filter { $0 == "/var/run/docker.sock" }.count, 1)
        XCTAssertEqual(candidates.first, "/var/run/docker.sock")
    }

    func testLocatePicksTheFirstRealSocket() throws {
        let fake = try FakeDocker()
        defer { fake.shutDown() }
        let home = (fake.socketPath as NSString).deletingLastPathComponent

        XCTAssertNil(DockerSocketLocator.locate(environment: [:], home: home), "nothing at the standard paths")
        XCTAssertEqual(DockerSocketLocator.locate(environment: ["DOCKER_HOST": "unix://\(fake.socketPath)"], home: home), fake.socketPath)
        XCTAssertFalse(DockerSocketLocator.isSocket(home + "/server.py"), "a regular file is not a socket")
        XCTAssertFalse(DockerSocketLocator.isSocket(home + "/missing.sock"))
    }
}

/// The client and collector against the fake Engine API.
final class DockerClientTests: XCTestCase {
    private var fake: FakeDocker!

    override func setUpWithError() throws {
        fake = try FakeDocker()
    }

    override func tearDown() {
        fake.shutDown()
    }

    private func states() async throws -> [String: DockerContainer.State] {
        Dictionary(uniqueKeysWithValues: try await fake.client.containers().map { ($0.id, $0.state) })
    }

    func testListsRunningAndStoppedContainers() async throws {
        let containers = try await fake.client.containers()
        XCTAssertEqual(containers.map(\.name).sorted(), ["scratch", "shop-db-1"])
        let database = try XCTUnwrap(containers.first { $0.id == FakeDocker.runningID })
        XCTAssertEqual(database.image, "postgres:17-alpine")
        XCTAssertEqual(database.composeProject, "shop")
        XCTAssertEqual(database.portSummaries.map(\.port), [54329])
    }

    func testReadsTheStartTime() async throws {
        let running = try await fake.client.startedAt(of: FakeDocker.runningID)
        XCTAssertEqual(running, ISO8601DateFormatter().date(from: "2026-10-12T01:49:53Z"))
        let stopped = try await fake.client.startedAt(of: FakeDocker.stoppedID)
        XCTAssertNil(stopped)
    }

    func testReadsChunkedMultiplexedLogs() async throws {
        let logs = try await fake.client.logs(of: FakeDocker.runningID, tail: 50)
        XCTAssertEqual(logs, "ready to accept connections\nwarning: disk is slow\n")
        let requests = try await fake.requests()
        XCTAssertTrue(requests.contains { $0.contains("/logs") && $0.contains("tail=50") && $0.contains("stdout=true") && $0.contains("stderr=true") })
    }

    func testStopStartAndRestart() async throws {
        try await fake.client.stop(FakeDocker.runningID)
        var current = try await states()
        XCTAssertEqual(current[FakeDocker.runningID], .exited)

        try await fake.client.stop(FakeDocker.runningID)
        current = try await states()
        XCTAssertEqual(current[FakeDocker.runningID], .exited, "stopping twice is not an error (304)")

        try await fake.client.start(FakeDocker.runningID)
        try await fake.client.start(FakeDocker.runningID)
        current = try await states()
        XCTAssertEqual(current[FakeDocker.runningID], .running)

        try await fake.client.restart(FakeDocker.stoppedID)
        current = try await states()
        XCTAssertEqual(current[FakeDocker.stoppedID], .running)
    }

    func testRemoveRefusesARunningContainerUnlessForced() async throws {
        do {
            try await fake.client.remove(FakeDocker.runningID)
            XCTFail("expected a conflict")
        } catch let DockerError.api(status, message) {
            XCTAssertEqual(status, 409)
            XCTAssertTrue(message.contains("container is running"), message)
        }
        var current = try await states()
        XCTAssertNotNil(current[FakeDocker.runningID])

        try await fake.client.remove(FakeDocker.runningID, force: true)
        try await fake.client.remove(FakeDocker.stoppedID)
        current = try await states()
        XCTAssertTrue(current.isEmpty)
    }

    /// The server closes the socket after every response. That close must
    /// never be mistaken for a failed request, however the events interleave.
    func testEveryRequestGetsItsResponseUnderLoad() async throws {
        let http = UnixHTTPClient(socketPath: fake.socketPath)
        var failures: [String] = []
        for _ in 0..<150 {
            do {
                let response = try await http.send(path: "/containers/json")
                if response.status != 200 { failures.append("status \(response.status)") }
            } catch {
                failures.append("\(error)")
            }
        }
        let parallel = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    do {
                        _ = try await http.send(path: "/containers/json")
                        return nil
                    } catch {
                        return "\(error)"
                    }
                }
            }
            var errors: [String] = []
            for await error in group {
                if let error { errors.append(error) }
            }
            return errors
        }
        XCTAssertEqual(failures + parallel, [])
    }

    func testServerThatNeverAnswersTimesOut() async throws {
        // A listening socket nobody accepts on: the connection is made, and
        // then nothing comes back.
        let path = "/tmp/strays-\(UUID().uuidString.prefix(8)).sock"
        let silent = try ThrowawayProcess(ThrowawayProcess.python, ["-c", "import socket, sys, time; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8); time.sleep(60)", path])
        defer {
            silent.stop()
            try? FileManager.default.removeItem(atPath: path)
        }
        let appeared = await eventually { DockerSocketLocator.isSocket(path) }
        XCTAssertTrue(appeared)

        let started = Date()
        do {
            _ = try await UnixHTTPClient(socketPath: path).send(path: "/containers/json", timeout: 0.4)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testUnknownContainerSurfacesTheEngineMessage() async {
        do {
            try await fake.client.start("nope")
            XCTFail("expected a 404")
        } catch {
            XCTAssertEqual(error as? DockerError, .api(status: 404, message: "No such container: nope"))
        }
    }

    func testNothingListeningIsUnavailableNotACrash() async {
        let client = DockerClient(socketPath: "/tmp/strays-no-such-daemon.sock")
        do {
            _ = try await client.containers()
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? DockerError, .unavailable)
        }
    }

    // MARK: - Collector

    func testCollectorFillsStartTimesAndReportsAvailability() async throws {
        let path = fake.socketPath
        let collector = DockerCollector(locate: { path })
        let snapshot = try await collector.collect()

        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.socketPath, path)
        let database = try XCTUnwrap(snapshot.containers.first { $0.id == FakeDocker.runningID })
        XCTAssertNotNil(database.startedAt)
        XCTAssertNil(database.cpuPercent, "no stats unless the row is visible")
        XCTAssertNil(try XCTUnwrap(snapshot.containers.first { $0.id == FakeDocker.stoppedID }).startedAt)
    }

    func testCollectorOnlyInspectsAContainerAgainWhenItsStatusChanges() async throws {
        let path = fake.socketPath
        let collector = DockerCollector(locate: { path })
        _ = try await collector.collect()
        _ = try await collector.collect()
        _ = try await collector.collect()
        let inspections = try await fake.requests().filter { $0.hasSuffix("/json") && $0.contains(FakeDocker.runningID) }
        XCTAssertEqual(inspections.count, 1)
    }

    func testCollectorFetchesStatsOnlyForVisibleRunningContainers() async throws {
        let path = fake.socketPath
        let collector = DockerCollector(locate: { path })
        await collector.setStatsTargets([FakeDocker.runningID, FakeDocker.stoppedID])

        let first = try await collector.collect()
        let firstReading = try XCTUnwrap(first.containers.first { $0.id == FakeDocker.runningID })
        XCTAssertEqual(firstReading.memoryBytes, 80_000_000)
        XCTAssertNil(firstReading.cpuPercent, "one reading is not a rate")

        let second = try await collector.collect()
        let secondReading = try XCTUnwrap(second.containers.first { $0.id == FakeDocker.runningID })
        XCTAssertEqual(try XCTUnwrap(secondReading.cpuPercent), 20, accuracy: 0.01)

        let statsRequests = try await fake.requests().filter { $0.contains("/stats") }
        XCTAssertEqual(statsRequests.count, 2)
        XCTAssertTrue(statsRequests.allSatisfy { $0.contains(FakeDocker.runningID) && $0.contains("one-shot=true") }, "never for a stopped container")

        await collector.setStatsTargets([])
        _ = try await collector.collect()
        let afterHiding = try await fake.requests().filter { $0.contains("/stats") }
        XCTAssertEqual(afterHiding.count, 2, "hidden rows cost nothing")
    }

    func testCollectorReportsUnavailableWhenDockerIsNotRunning() async throws {
        let none = try await DockerCollector(locate: { nil }).collect()
        XCTAssertEqual(none, .unavailable)

        let stale = try await DockerCollector(locate: { "/tmp/strays-no-such-daemon.sock" }).collect()
        XCTAssertEqual(stale, .unavailable)
    }

    func testCollectorRecoversAfterTheDaemonGoesAway() async throws {
        let path = fake.socketPath
        let collector = DockerCollector(locate: { DockerSocketLocator.isSocket(path) ? path : nil })
        let up = try await collector.collect()
        XCTAssertTrue(up.isAvailable)

        fake.shutDown()
        let down = try await collector.collect()
        XCTAssertFalse(down.isAvailable)
    }
}

/// Read-only checks against a real Docker daemon, when one is running.
final class DockerLiveTests: XCTestCase {
    func testRealDaemonAnswersOrIsCleanlyUnavailable() async throws {
        let snapshot = try await DockerCollector().collect()
        guard snapshot.isAvailable else {
            throw XCTSkip("no Docker daemon on this machine")
        }
        for container in snapshot.containers {
            XCTAssertFalse(container.id.isEmpty)
            XCTAssertFalse(container.name.hasPrefix("/"))
            if container.state == .running {
                XCTAssertNotNil(container.startedAt, container.name)
            }
        }
    }
}
