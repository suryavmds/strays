import Darwin
import Foundation

public enum LaunchError: Error, Equatable {
    case nothingToRun
    case spawnFailed(errno: Int32)
}

/// Starts a command detached from Strays: its own session, no terminal,
/// output discarded. Used by the experimental Restart action.
public enum ProcessLauncher {
    /// What to execute in order to run `details`' command again.
    ///
    /// The kernel's idea of the executable is not always what was typed:
    /// `/usr/bin/python3` re-execs the real interpreter, and npm rewrites its
    /// own argument list. So, in order of preference:
    /// 1. `argv[0]` when it is an absolute path that still exists;
    /// 2. the recorded executable, when `argv[0]` is just its name;
    /// 3. a login shell that looks the command up on the user's PATH.
    public static func plan(for details: ProcessDetails) -> (executable: String, arguments: [String])? {
        guard let first = details.arguments.first, !first.isEmpty else {
            return details.executablePath.map { ($0, [$0]) }
        }
        if first.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: first) {
            return (first, details.arguments)
        }
        if let path = details.executablePath, (path as NSString).lastPathComponent == (first as NSString).lastPathComponent {
            return (path, details.arguments)
        }
        let shell = details.environment["SHELL"] ?? "/bin/zsh"
        let command = "exec " + details.arguments.map(shellQuoted).joined(separator: " ")
        return (shell, [(shell as NSString).lastPathComponent, "-l", "-c", command])
    }

    /// Runs the process's command again, in its original working directory
    /// and with its original environment. Returns the new PID.
    @discardableResult
    public static func relaunch(_ details: ProcessDetails) throws -> Int32 {
        guard let plan = plan(for: details) else { throw LaunchError.nothingToRun }
        // macOS may not reveal the environment of Apple's own system
        // binaries. Starting a command with no PATH or HOME would be worse
        // than starting it with ours.
        let environment = details.environment.isEmpty ? ProcessInfo.processInfo.environment : details.environment
        return try launch(
            executable: plan.executable,
            arguments: plan.arguments,
            cwd: details.cwd,
            environment: environment
        )
    }

    @discardableResult
    public static func launch(
        executable: String,
        arguments: [String],
        cwd: String?,
        environment: [String: String]
    ) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            posix_spawn_file_actions_addchdir_np(&actions, cwd)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // Ignored signals and the signal mask are inherited across spawn.
        // Without a reset, a process started while we happened to ignore
        // SIGTERM would ignore it too, and could then only be force killed.
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        // A new session, so the process outlives Strays and owns its own
        // process group. Close everything we did not explicitly hand over.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else { throw LaunchError.spawnFailed(errno: status) }
        reapWhenItExits(pid)
        return pid
    }

    /// We are the parent of what we launch, so we must collect its exit
    /// status, or it would linger as a zombie for as long as Strays runs.
    private static func reapWhenItExits(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            source.cancel()
        }
        source.resume()
        // It may already have exited, before the source was watching.
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { source.cancel() }
    }

    static func shellQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
