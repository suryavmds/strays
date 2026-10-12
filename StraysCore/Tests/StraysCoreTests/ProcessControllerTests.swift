import Darwin
import XCTest
@testable import StraysCore

/// Records what would have been signalled, without signalling anything.
private final class RecordingSignaller: Signalling, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(signal: Int32, pid: Int32)] = []
    var errnoFor: [Int32: Int32] = [:]

    var sent: [(signal: Int32, pid: Int32)] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func send(_ signal: Int32, to pid: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if let error = errnoFor[pid] { return error }
        log.append((signal, pid))
        return 0
    }
}

final class StopPolicyTests: XCTestCase {
    private let me: UInt32 = 501

    private func target(_ pid: Int32, name: String, uid: UInt32? = nil, path: String? = nil) -> SignalTarget {
        SignalTarget(identity: ProcessIdentity(pid: pid, startSeconds: 1, startMicroseconds: 0), name: name, uid: uid ?? me, executablePath: path)
    }

    private func policy(_ target: SignalTarget) -> StopPolicy {
        StopPolicy.evaluate(target, currentUID: me, ownPID: 4242)
    }

    private func isForbidden(_ policy: StopPolicy) -> Bool {
        if case .forbidden = policy { return true }
        return false
    }

    func testOrdinaryOwnProcessIsAllowed() {
        XCTAssertEqual(policy(target(900, name: "node", path: "/usr/local/bin/node")), .allowed)
    }

    func testKernelLaunchdAndStraysItselfAreForbidden() {
        XCTAssertTrue(isForbidden(policy(target(0, name: "kernel_task", uid: 0))))
        XCTAssertTrue(isForbidden(policy(target(1, name: "launchd", uid: 0))))
        XCTAssertTrue(isForbidden(policy(target(4242, name: "Strays"))))
    }

    func testSessionCriticalProcessesAreForbiddenEvenWhenOurs() {
        for name in ["WindowServer", "loginwindow", "Dock", "Finder", "SystemUIServer", "cfprefsd"] {
            XCTAssertTrue(isForbidden(policy(target(300, name: name))), name)
        }
    }

    func testProtectedNamesMatchTheirTruncatedKernelForm() {
        // The process table stores at most 16 characters.
        XCTAssertTrue(isForbidden(policy(target(301, name: "NotificationCent"))))
    }

    func testForbiddenWinsOverEverythingElse() {
        XCTAssertTrue(isForbidden(policy(target(1, name: "launchd", uid: 0, path: "/sbin/launchd"))))
    }

    func testOtherUsersProcessesOfferASudoCommandInsteadOfEscalating() {
        XCTAssertEqual(policy(target(88, name: "httpd", uid: 0)), .needsPrivileges(sudoCommand: "sudo kill -TERM 88"))
        XCTAssertEqual(policy(target(89, name: "postgres", uid: 502)), .needsPrivileges(sudoCommand: "sudo kill -TERM 89"))
        XCTAssertEqual(StopPolicy.sudoKillCommand(pid: 88, force: true), "sudo kill -KILL 88")
    }

    func testOwnSystemDaemonsNeedConfirmation() {
        guard case .needsConfirmation = policy(target(77, name: "rapportd", path: "/usr/libexec/rapportd")) else {
            return XCTFail("expected confirmation")
        }
        guard case .needsConfirmation = policy(target(78, name: "AirPlayXPCHelper", path: "/System/Library/CoreServices/AirPlayXPCHelper")) else {
            return XCTFail("expected confirmation")
        }
    }
}

final class ProcessControllerSafetyTests: XCTestCase {
    private func target(_ entry: ProcessEntry) -> SignalTarget {
        SignalTarget(identity: entry.identity, name: entry.name, uid: entry.uid)
    }

    private func controller(
        _ signaller: RecordingSignaller,
        entries: [ProcessEntry],
        ownPID: Int32 = 4242
    ) -> ProcessController {
        let table = ProcessTable(entries: entries)
        return ProcessController(
            signaller: signaller,
            gracePeriod: 0.2,
            pollInterval: 0.02,
            ownPID: ownPID,
            lookup: { table[$0] },
            table: { table }
        )
    }

    func testNeverSignalsAReusedPID() async {
        let signaller = RecordingSignaller()
        let recorded = makeEntry(700, name: "node", start: 1_000)
        let reused = makeEntry(700, name: "Safari", start: 9_999)

        let result = await controller(signaller, entries: [reused]).stop([target(recorded)])

        XCTAssertTrue(signaller.sent.isEmpty, "a PID with a different start time must never be signalled")
        XCTAssertEqual(result.skipped.map(\.reason), [.noLongerTheSameProcess])
        XCTAssertTrue(result.nothingHappened)
    }

    func testNeverSignalsAProcessThatIsGone() async {
        let signaller = RecordingSignaller()
        let result = await controller(signaller, entries: []).stop([target(makeEntry(701, name: "node"))])
        XCTAssertTrue(signaller.sent.isEmpty)
        XCTAssertEqual(result.skipped.map(\.reason), [.noLongerTheSameProcess])
    }

    func testNeverSignalsProtectedProcessesEvenInsideATree() async {
        let signaller = RecordingSignaller()
        let entries = [
            makeEntry(1, parent: 0, name: "launchd", uid: 0),
            makeEntry(4242, name: "Strays"),
            makeEntry(500, name: "WindowServer"),
            makeEntry(600, name: "node"),
        ]
        let result = await controller(signaller, entries: entries).stop(entries.map(target))

        XCTAssertEqual(signaller.sent.map(\.pid), [600])
        XCTAssertEqual(result.skipped.count, 3)
        XCTAssertTrue(result.skipped.allSatisfy {
            if case .protected = $0.reason { return true }
            return false
        })
    }

    func testForceKillObeysTheSameRules() async {
        let signaller = RecordingSignaller()
        let entries = [makeEntry(1, parent: 0, name: "launchd", uid: 0), makeEntry(600, name: "node")]
        _ = await controller(signaller, entries: entries).forceKill(entries.map(target))
        XCTAssertEqual(signaller.sent.map(\.pid), [600])
        XCTAssertEqual(signaller.sent.map(\.signal), [SIGKILL])
    }

    func testStopSendsSIGTERMAndReportsSurvivors() async {
        let signaller = RecordingSignaller()
        let stubborn = makeEntry(600, name: "node")
        // The fake table never changes, so the process "survives".
        let result = await controller(signaller, entries: [stubborn]).stop([target(stubborn)])

        XCTAssertEqual(signaller.sent.map(\.signal), [SIGTERM])
        XCTAssertEqual(result.survivors, [target(stubborn)])
        XCTAssertFalse(result.allExited)
    }

    func testPermissionDeniedIsReportedNotThrown() async {
        let signaller = RecordingSignaller()
        signaller.errnoFor[800] = EPERM
        let foreign = makeEntry(800, name: "httpd", uid: 0)
        let result = await controller(signaller, entries: [foreign]).stop([target(foreign)])
        XCTAssertEqual(result.skipped.map(\.reason), [.permissionDenied])
        XCTAssertTrue(result.survivors.isEmpty)
    }

    func testExitBetweenCheckAndSignalCountsAsExited() async {
        let signaller = RecordingSignaller()
        signaller.errnoFor[801] = ESRCH
        let racing = makeEntry(801, name: "node")
        let result = await controller(signaller, entries: [racing]).stop([target(racing)])
        XCTAssertEqual(result.exited, [target(racing)])
        XCTAssertTrue(result.allExited)
    }

    func testTreeIncludesDescendantsAndTheProcessGroup() {
        let entries = [
            makeEntry(20, name: "npm", pgid: 20),
            makeEntry(21, parent: 20, name: "sh", pgid: 20),
            makeEntry(22, parent: 21, name: "node", pgid: 20),
            // Reparented to launchd, but still in npm's process group.
            makeEntry(23, parent: 1, name: "esbuild", pgid: 20),
            makeEntry(30, name: "unrelated", pgid: 30),
        ]
        let tree = controller(RecordingSignaller(), entries: entries).tree(of: target(entries[0]))
        XCTAssertEqual(tree.map(\.pid), [20, 21, 22, 23])
    }

    func testTreeDoesNotPullInTheGroupWhenTheRootIsNotItsLeader() {
        // A background job started by a non-interactive shell shares the
        // shell's group; stopping it must not take the shell's siblings too.
        let entries = [
            makeEntry(10, name: "zsh", pgid: 10),
            makeEntry(20, parent: 10, name: "node", pgid: 10),
            makeEntry(21, parent: 20, name: "worker", pgid: 10),
            makeEntry(30, parent: 10, name: "sibling", pgid: 10),
        ]
        let tree = controller(RecordingSignaller(), entries: entries).tree(of: target(entries[1]))
        XCTAssertEqual(tree.map(\.pid), [20, 21])
    }

    func testTreeOfAReusedPIDIsEmpty() {
        let recorded = makeEntry(20, name: "npm", start: 1_000)
        let reused = makeEntry(20, name: "Safari", start: 9_999)
        let tree = controller(RecordingSignaller(), entries: [reused, makeEntry(21, parent: 20)]).tree(of: target(recorded))
        XCTAssertTrue(tree.isEmpty)
    }
}

/// Real signals, sent only to processes these tests spawned.
final class ProcessControllerLiveTests: XCTestCase {
    private func target(_ process: ThrowawayProcess) throws -> SignalTarget {
        let entry = try XCTUnwrap(LibProc.entry(for: process.pid))
        return SignalTarget(identity: entry.identity, name: entry.name, uid: entry.uid)
    }

    func testStopTerminatesACooperativeProcess() async throws {
        let process = try ThrowawayProcess.sleeper()
        defer { process.stop() }
        let controller = ProcessController(gracePeriod: 5)
        let target = try target(process)

        let result = await controller.stop([target])

        XCTAssertEqual(result.exited, [target])
        XCTAssertTrue(result.allExited)
        XCTAssertFalse(controller.isRunning(target))
    }

    func testStubbornProcessSurvivesStopAndDiesOnForceKill() async throws {
        let ready = try TemporaryDirectory()
        let flag = ready.url.appendingPathComponent("ready")
        // Ignores SIGTERM, and says so by touching a file once the handler is installed.
        let script = "import signal, time, pathlib; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(r'\(flag.path)').touch(); time.sleep(60)"
        let process = try ThrowawayProcess(ThrowawayProcess.python, ["-c", script])
        defer { process.stop() }
        let installed = await eventually { FileManager.default.fileExists(atPath: flag.path) }
        XCTAssertTrue(installed)

        let controller = ProcessController(gracePeriod: 0.6)
        let target = try target(process)

        let stopped = await controller.stop([target])
        XCTAssertEqual(stopped.survivors, [target])
        XCTAssertTrue(controller.isRunning(target))

        let killed = await controller.forceKill(stopped.survivors)
        XCTAssertEqual(killed.exited, [target])
        XCTAssertFalse(controller.isRunning(target))
    }

    func testStoppingATreeTakesTheChildrenToo() async throws {
        // A shell that starts two children and waits, like `npm run dev`.
        let parent = try ThrowawayProcess("/bin/sh", ["-c", "\(ThrowawayProcess.python) -c 'import time; time.sleep(60)' & \(ThrowawayProcess.python) -c 'import time; time.sleep(60)' & wait"])
        defer { parent.stop() }
        let controller = ProcessController(gracePeriod: 5)
        let root = try target(parent)

        let grew = await eventually { controller.tree(of: root).count == 3 }
        XCTAssertTrue(grew, "expected the shell and its two children")
        let tree = controller.tree(of: root)

        let result = await controller.stop(tree)
        XCTAssertEqual(Set(result.exited), Set(tree))
        XCTAssertTrue(tree.allSatisfy { !controller.isRunning($0) })
    }

    func testAStaleIdentityLeavesTheRealProcessAlone() async throws {
        let process = try ThrowawayProcess.sleeper()
        defer { process.stop() }
        let real = try target(process)
        let stale = SignalTarget(
            identity: ProcessIdentity(pid: real.pid, startSeconds: real.identity.startSeconds - 100, startMicroseconds: 0),
            name: real.name,
            uid: real.uid
        )

        let controller = ProcessController(gracePeriod: 0.3)
        let result = await controller.forceKill([stale])

        XCTAssertEqual(result.skipped.map(\.reason), [.noLongerTheSameProcess])
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(controller.isRunning(real))
    }

    func testLocalURLForAPort() {
        let plain = PortSummary(port: 3000, transport: .tcp, addresses: ["127.0.0.1"], isLANVisible: false, pid: 1)
        let secure = PortSummary(port: 8443, transport: .tcp, addresses: ["*"], isLANVisible: true, pid: 1)
        XCTAssertEqual(plain.localURL?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(secure.localURL?.absoluteString, "https://localhost:8443")
    }
}
