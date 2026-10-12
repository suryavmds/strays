import Darwin
import Foundation
import XCTest
@testable import StraysCore

/// A process the tests start themselves and always clean up. Tests never
/// touch anything they did not spawn.
///
/// Liveness is tracked by PID and start time rather than through
/// `Process.isRunning` or `waitUntilExit()`: Foundation ties its exit
/// monitoring to the run loop of the launching thread, and an async test
/// resumes on whichever thread is free.
final class ThrowawayProcess {
    static let python = "/usr/bin/python3"

    private let process = Process()
    private let identity: ProcessIdentity?

    let pid: Int32

    /// True while the PID still belongs to the process we spawned.
    var isRunning: Bool {
        guard let identity else { return false }
        return LibProc.entry(for: pid)?.identity == identity
    }

    init(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String] = [:]
    ) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // A termination handler makes Foundation reap the child from a
        // dispatch source instead of a run loop.
        process.terminationHandler = { _ in }
        try process.run()
        pid = process.processIdentifier
        identity = LibProc.entry(for: pid)?.identity
    }

    /// `python3 -m http.server` bound to loopback on the given port.
    static func httpServer(port: UInt16, cwd: URL? = nil, environment: [String: String] = [:]) throws -> ThrowawayProcess {
        let server = try ThrowawayProcess(
            python,
            ["-m", "http.server", String(port), "--bind", "127.0.0.1"],
            cwd: cwd,
            environment: environment
        )
        guard waitUntilListening(on: port) else {
            server.stop()
            throw XCTSkip("python3 http.server did not start listening on \(port)")
        }
        return server
    }

    /// A process that does nothing for a minute and opens no port.
    static func sleeper(cwd: URL? = nil, environment: [String: String] = [:]) throws -> ThrowawayProcess {
        try ThrowawayProcess(python, ["-c", "import time; time.sleep(60)"], cwd: cwd, environment: environment)
    }

    /// SIGTERM, then SIGKILL if it is still there two seconds later. Only
    /// ever signals the exact process this object spawned.
    func stop() {
        for signal in [SIGTERM, SIGKILL] {
            guard isRunning else { return }
            kill(pid, signal)
            let deadline = Date().addingTimeInterval(2)
            while isRunning, Date() < deadline { usleep(20_000) }
        }
    }

    deinit { stop() }
}

/// Asks the kernel for a free loopback port.
func freeLoopbackPort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = loopbackAddress(port: 0)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    precondition(bound == 0, "could not bind a loopback socket")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
    }
    return UInt16(bigEndian: address.sin_port)
}

func loopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
}

/// Polls until something accepts connections on the loopback port.
func waitUntilListening(on port: UInt16, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = loopbackAddress(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        close(fd)
        if connected == 0 { return true }
        usleep(50_000)
    }
    return false
}

/// Polls an async condition until it holds or the timeout passes.
func eventually(timeout: TimeInterval = 10, _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return false
}

/// A temporary directory that stands in for a home folder or a project.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strays-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // The kernel reports /private/var/…; resolve so paths compare equal.
        url = base.resolvingSymlinksInPath()
    }

    var path: String { url.path }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let directory = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func write(_ contents: String, to relativePath: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Synthetic processes

func makeEntry(
    _ pid: Int32,
    parent ppid: Int32 = 1,
    name: String = "proc",
    uid: UInt32 = getuid(),
    pgid: Int32? = nil,
    start: UInt64 = 1_000
) -> ProcessEntry {
    ProcessEntry(
        identity: ProcessIdentity(pid: pid, startSeconds: start, startMicroseconds: 0),
        ppid: ppid,
        pgid: pgid ?? pid,
        uid: uid,
        name: name
    )
}

func makeDetails(
    _ entry: ProcessEntry,
    path: String? = nil,
    arguments: [String] = [],
    environment: [String: String] = [:],
    cwd: String? = nil,
    cpu: Double = 0,
    memory: UInt64 = 0,
    isInspectable: Bool = true
) -> ProcessDetails {
    ProcessDetails(
        entry: entry,
        executablePath: path,
        arguments: arguments,
        environment: environment,
        cwd: cwd,
        username: "tester",
        cpuPercent: cpu,
        residentBytes: memory,
        isInspectable: isInspectable
    )
}
