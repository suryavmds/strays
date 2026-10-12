import Darwin
import Foundation

/// One process we may be asked to signal, pinned to its start time.
public struct SignalTarget: Sendable, Hashable {
    public let identity: ProcessIdentity
    /// Executable name, for the protected list and for messages.
    public let name: String
    public let uid: UInt32
    public let executablePath: String?

    public init(identity: ProcessIdentity, name: String, uid: UInt32, executablePath: String? = nil) {
        self.identity = identity
        self.name = name
        self.uid = uid
        self.executablePath = executablePath
    }

    public init(_ details: ProcessDetails) {
        self.init(
            identity: details.identity,
            name: details.executableName,
            uid: details.entry.uid,
            executablePath: details.executablePath
        )
    }

    public var pid: Int32 { identity.pid }
}

/// What Strays is willing to do about stopping a process.
public enum StopPolicy: Sendable, Equatable {
    /// Ours, and ordinary. Stop without asking.
    case allowed
    /// Ours, but part of macOS. Ask first.
    case needsConfirmation(reason: String)
    /// Root's or another user's. Strays never escalates; it offers the
    /// command to run by hand.
    case needsPrivileges(sudoCommand: String)
    /// Never, whoever asks.
    case forbidden(reason: String)
}

/// Processes Strays refuses to signal under any circumstances.
public enum ProtectedProcesses {
    /// Killing these logs the user out, freezes the display, or breaks the
    /// session in ways that are hard to recover from.
    public static let names: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logind",
        "SystemUIServer", "Dock", "Finder", "ControlCenter", "NotificationCenter",
        "coreaudiod", "securityd", "opendirectoryd", "configd", "cfprefsd",
        "coreservicesd", "launchservicesd", "runningboardd", "UserEventAgent",
        "logd", "notifyd", "diskarbitrationd", "powerd", "tccd", "syspolicyd",
        "trustd", "mds", "mds_stores", "bluetoothd", "airportd", "mDNSResponder",
        "distnoted", "lsd", "sharingd", "universalaccessd", "WindowManager",
    ]

    /// The kernel's short process name holds at most 16 characters, so a
    /// name read from the process table may be a truncated form.
    private static let truncatedNames = Set(names.map { String($0.prefix(16)) })

    private static let systemPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    public static func isProtected(pid: Int32, name: String, ownPID: Int32 = getpid()) -> String? {
        if pid <= 1 { return "PID \(pid) is the kernel or launchd." }
        if pid == ownPID { return "This is Strays itself." }
        if names.contains(name) || truncatedNames.contains(name) {
            return "\(name) is part of macOS and keeps your session running."
        }
        return nil
    }

    /// True for anything Apple ships in a system location.
    public static func isSystemPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return systemPathPrefixes.contains { path.hasPrefix($0) }
    }
}

extension StopPolicy {
    public static func evaluate(
        _ target: SignalTarget,
        currentUID: UInt32 = getuid(),
        ownPID: Int32 = getpid()
    ) -> StopPolicy {
        if let reason = ProtectedProcesses.isProtected(pid: target.pid, name: target.name, ownPID: ownPID) {
            return .forbidden(reason: reason)
        }
        if target.uid != currentUID {
            return .needsPrivileges(sudoCommand: sudoKillCommand(pid: target.pid))
        }
        if ProtectedProcesses.isSystemPath(target.executablePath) {
            return .needsConfirmation(reason: "\(target.name) is a macOS system process.")
        }
        return .allowed
    }

    public static func sudoKillCommand(pid: Int32, force: Bool = false) -> String {
        "sudo kill -\(force ? "KILL" : "TERM") \(pid)"
    }
}
