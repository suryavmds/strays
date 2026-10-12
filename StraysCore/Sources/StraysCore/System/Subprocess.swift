import Foundation

public struct SubprocessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var succeeded: Bool { status == 0 }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum SubprocessError: Error, Equatable {
    case launchFailed(String)
    case timedOut
}

/// Runs a short-lived helper tool (lsof, netstat, brew) and captures its output.
public enum Subprocess {
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 15
    ) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment { process.environment = environment }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        let exit = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exit.continuation.finish() }

        do {
            try process.run()
        } catch {
            throw SubprocessError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently so a chatty tool can never fill a
        // pipe buffer and deadlock against us.
        async let stdout = drain(stdoutPipe.fileHandleForReading)
        async let stderr = drain(stderrPipe.fileHandleForReading)

        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            box.terminate()
        }
        for await _ in exit.stream {}
        watchdog.cancel()
        let timedOut = box.wasTerminated

        let (out, err) = await (stdout, stderr)
        if timedOut { throw SubprocessError.timedOut }
        return SubprocessResult(status: box.status, stdout: out, stderr: err)
    }

    private static func drain(_ handle: FileHandle) async -> Data {
        await Task.detached(priority: .utility) {
            (try? handle.readToEnd()) ?? Data()
        }.value
    }
}

/// `Process` is not Sendable. We only touch it from the launching task, the
/// watchdog, and after exit, and guard the one piece of shared state.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var terminated = false

    init(_ process: Process) { self.process = process }

    var status: Int32 { process.terminationStatus }

    var wasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    func terminate() {
        lock.lock()
        terminated = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }
}
