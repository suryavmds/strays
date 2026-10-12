import Foundation

/// A service managed by `brew services` (Redis, Postgres, …).
public struct BrewService: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case started
        case stopped
        case error
        case scheduled
        case other(String)

        init(_ raw: String?) {
            switch raw?.lowercased() {
            case "started": self = .started
            case "none", "stopped", nil: self = .stopped
            case "error": self = .error
            case "scheduled": self = .scheduled
            case let value?: self = .other(value)
            }
        }
    }

    public var name: String
    /// The launchd label, such as `homebrew.mxcl.redis`.
    public var serviceName: String?
    public var status: Status
    public var pid: Int32?
    public var user: String?
    /// The launchd plist the service was started from.
    public var file: String?
    public var command: String?
    public var exitCode: Int?

    public init(
        name: String,
        serviceName: String? = nil,
        status: Status,
        pid: Int32? = nil,
        user: String? = nil,
        file: String? = nil,
        command: String? = nil,
        exitCode: Int? = nil
    ) {
        self.name = name
        self.serviceName = serviceName
        self.status = status
        self.pid = pid
        self.user = user
        self.file = file
        self.command = command
        self.exitCode = exitCode
    }

    public var id: String { name }
    public var isRunning: Bool { status == .started }

    public var statusLabel: String {
        switch status {
        case .started: "Started"
        case .stopped: "Stopped"
        case .error: exitCode.map { "Error (exit \($0))" } ?? "Error"
        case .scheduled: "Scheduled"
        case let .other(value): value.capitalized
        }
    }
}

public struct BrewSnapshot: Sendable, Equatable {
    /// False when Homebrew is not installed.
    public var isAvailable: Bool
    public var services: [BrewService]

    public init(isAvailable: Bool, services: [BrewService] = []) {
        self.isAvailable = isAvailable
        self.services = services
    }

    public static let unavailable = BrewSnapshot(isAvailable: false)
}

public enum BrewAction: String, Sendable {
    case start
    case stop
    case restart
}

public enum BrewError: Error, Equatable {
    case notInstalled
    case failed(String)
}

public enum BrewLocator {
    /// Apple Silicon and Intel install Homebrew in different places.
    public static let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public static func locate() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Parses `brew services info --all --json` and `brew services list --json`.
/// The first includes each service's PID; the second is the older, leaner form.
enum BrewServicesParser {
    private struct Payload: Decodable {
        let name: String
        let serviceName: String?
        let status: String?
        let running: Bool?
        let pid: Int32?
        let user: String?
        let file: String?
        let command: String?
        let exitCode: Int?

        enum CodingKeys: String, CodingKey {
            case name, status, running, pid, user, file, command
            case serviceName = "service_name"
            case exitCode = "exit_code"
        }
    }

    static func parse(_ data: Data) throws -> [BrewService] {
        try JSONDecoder().decode([Payload].self, from: data).map { payload in
            var status = BrewService.Status(payload.status)
            // `info` reports `running` separately; trust it over the label.
            if payload.running == true { status = .started }
            return BrewService(
                name: payload.name,
                serviceName: payload.serviceName,
                status: status,
                pid: payload.pid.flatMap { $0 > 0 ? $0 : nil },
                user: payload.user,
                file: payload.file,
                command: payload.command,
                exitCode: payload.exitCode
            )
        }
        .sorted { $0.name < $1.name }
    }
}

/// Lists and controls Homebrew services.
///
/// `brew` is a Ruby program and costs a quarter of a second of CPU per call,
/// so results are cached and only refreshed when they are older than the
/// caller is willing to accept.
public actor BrewCollector: Collector {
    public typealias Runner = @Sendable (_ brew: String, _ arguments: [String]) async throws -> SubprocessResult

    public nonisolated let name = "brew"

    private let brewPath: String?
    private let run: Runner
    private var cached: BrewSnapshot?
    private var cachedAt: Date = .distantPast
    /// Older Homebrew has no `services info --json`.
    private var supportsInfo = true

    public init(brewPath: String? = BrewLocator.locate(), runner: Runner? = nil) {
        self.brewPath = brewPath
        run = runner ?? { brew, arguments in
            try await Subprocess.run(brew, arguments, environment: BrewCollector.environment, timeout: 60)
        }
    }

    /// Keeps brew quick and quiet: no auto-update, no hints, no analytics.
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment.merging([
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
        ]) { _, new in new }
    }

    public func collect() async throws -> BrewSnapshot {
        try await collect(maxAge: 30)
    }

    /// Returns the cached list when it is younger than `maxAge` seconds.
    public func collect(maxAge: TimeInterval) async throws -> BrewSnapshot {
        guard let brewPath else { return .unavailable }
        if let cached, Date().timeIntervalSince(cachedAt) < maxAge { return cached }

        let services = try await fetch(brewPath)
        let snapshot = BrewSnapshot(isAvailable: true, services: services)
        cached = snapshot
        cachedAt = Date()
        return snapshot
    }

    public func invalidate() {
        cachedAt = .distantPast
    }

    public func perform(_ action: BrewAction, on service: String) async throws {
        guard let brewPath else { throw BrewError.notInstalled }
        let result = try await run(brewPath, ["services", action.rawValue, service])
        invalidate()
        guard result.succeeded else {
            let message = (result.stderrText + result.stdoutText).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BrewError.failed(message.isEmpty ? "brew services \(action.rawValue) \(service) failed" : message)
        }
    }

    private func fetch(_ brewPath: String) async throws -> [BrewService] {
        if supportsInfo {
            let result = try await run(brewPath, ["services", "info", "--all", "--json"])
            if result.succeeded, let services = try? BrewServicesParser.parse(result.stdout) {
                return services
            }
            supportsInfo = false
        }
        let result = try await run(brewPath, ["services", "list", "--json"])
        guard result.succeeded else { throw BrewError.failed(result.stderrText) }
        return try BrewServicesParser.parse(result.stdout)
    }
}
