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
///
/// `run` always returns: a tool that hangs is terminated, then killed, and a
/// grandchild that keeps our pipes open cannot hold us up either.
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

        // Readers are attached before launch so no output is ever missed.
        let stdout = PipeReader(stdoutPipe.fileHandleForReading)
        let stderr = PipeReader(stderrPipe.fileHandleForReading)

        let box = ProcessBox(process)
        let exited = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exited.continuation.finish() }

        do {
            try process.run()
        } catch {
            stdout.cancel()
            stderr.cancel()
            throw SubprocessError.launchFailed(error.localizedDescription)
        }

        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            box.signal(SIGTERM)
            try await Task.sleep(for: .seconds(1))
            box.signal(SIGKILL)
            try await Task.sleep(for: .seconds(1))
            // Whatever Foundation believes, stop waiting.
            exited.continuation.finish()
        }
        for await _ in exited.stream {}
        watchdog.cancel()

        async let out = stdout.finish(within: 2)
        async let err = stderr.finish(within: 2)
        let (outData, errData) = await (out, err)

        if box.timedOut { throw SubprocessError.timedOut }
        return SubprocessResult(status: box.status, stdout: outData, stderr: errData)
    }
}

/// Collects a pipe's output without blocking a thread on it.
private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private let endOfFile = AsyncStream<Void>.makeStream()

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.endOfFile.continuation.finish()
            } else {
                self.lock.withLock { self.buffer.append(chunk) }
            }
        }
    }

    /// Waits for end of file, but no longer than `seconds`: a grandchild that
    /// inherited the pipe may keep it open long after the tool itself exits.
    func finish(within seconds: TimeInterval) async -> Data {
        let timer = Task {
            try await Task.sleep(for: .seconds(seconds))
            endOfFile.continuation.finish()
        }
        for await _ in endOfFile.stream {}
        timer.cancel()
        cancel()
        return collected()
    }

    private func collected() -> Data {
        lock.withLock { buffer }
    }

    func cancel() {
        handle.readabilityHandler = nil
        endOfFile.continuation.finish()
    }
}

/// `Process` is not Sendable. The watchdog only ever signals it, and the
/// status is read once the process is known to have exited.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var didTimeOut = false

    init(_ process: Process) { self.process = process }

    /// `terminationStatus` raises if the process is still running.
    var status: Int32 { process.isRunning ? -1 : process.terminationStatus }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }

    func signal(_ signal: Int32) {
        lock.lock()
        didTimeOut = true
        lock.unlock()
        guard process.isRunning else { return }
        kill(process.processIdentifier, signal)
    }
}
