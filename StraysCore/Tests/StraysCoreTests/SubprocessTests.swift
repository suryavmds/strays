import XCTest
@testable import StraysCore

final class SubprocessTests: XCTestCase {
    func testCapturesOutputAndStatus() async throws {
        let result = try await Subprocess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.stdoutText, "out\n")
        XCTAssertEqual(result.stderrText, "err\n")
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        // Far more than a pipe buffer holds.
        let result = try await Subprocess.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero"])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.count, 3_000_000)
    }

    func testHonoursWorkingDirectoryAndEnvironment() async throws {
        let directory = try TemporaryDirectory()
        let result = try await Subprocess.run("/bin/sh", ["-c", "pwd -P; echo $STRAYS_VALUE"], cwd: directory.path, environment: ["STRAYS_VALUE": "42"])
        let lines = result.stdoutText.split(separator: "\n").map(String.init)
        // `pwd -P` reports /private/var/…, which Foundation shortens to /var/….
        XCTAssertEqual(lines.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, directory.path)
        XCTAssertEqual(lines.last, "42")
    }

    func testMissingExecutableIsALaunchFailure() async {
        do {
            _ = try await Subprocess.run("/nonexistent/tool")
            XCTFail("expected a launch failure")
        } catch let error as SubprocessError {
            guard case .launchFailed = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testHangingToolTimesOut() async {
        let started = Date()
        do {
            _ = try await Subprocess.run("/bin/sleep", ["30"], timeout: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SubprocessError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testToolThatIgnoresSIGTERMIsKilled() async {
        let started = Date()
        do {
            _ = try await Subprocess.run("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 1; done"], timeout: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SubprocessError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    /// The tool exits at once but leaves a grandchild holding our pipe open.
    func testGrandchildHoldingThePipeDoesNotBlockUs() async throws {
        let started = Date()
        let result = try await Subprocess.run("/bin/sh", ["-c", "echo done; (sleep 20 &) ; exit 0"])
        XCTAssertEqual(result.stdoutText, "done\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        // The stray `sleep 20` belongs to this test; make sure it goes away.
        _ = try? await Subprocess.run("/usr/bin/pkill", ["-P", "1", "-f", "^sleep 20$"])
    }
}
