import Darwin
import Foundation

public enum DockerError: Error, Equatable {
    /// No Docker socket answers.
    case unavailable
    case api(status: Int, message: String)
}

/// Finds the Docker socket: Docker Desktop, OrbStack, Colima, and friends
/// all speak the same API on different paths.
public enum DockerSocketLocator {
    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [String] {
        var paths: [String] = []
        // Only unix sockets; a tcp:// host is a remote daemon, not this Mac.
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            paths.append(String(host.dropFirst("unix://".count)))
        }
        paths += [
            "\(home)/.docker/run/docker.sock",
            "/var/run/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.colima/default/docker.sock",
            "\(home)/.rd/docker.sock",
        ]
        var seen: Set<String> = []
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The first candidate that exists and is a socket.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String? {
        candidates(environment: environment, home: home).first(where: isSocket)
    }

    static func isSocket(_ path: String) -> Bool {
        var info = stat()
        // stat, not lstat: /var/run/docker.sock is usually a symlink.
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }
}

/// The parts of the Docker Engine API that Strays uses.
public struct DockerClient: Sendable {
    public let socketPath: String
    private let http: UnixHTTPClient

    public init(socketPath: String) {
        self.socketPath = socketPath
        http = UnixHTTPClient(socketPath: socketPath)
    }

    // MARK: - Reading

    public func containers(all: Bool = true) async throws -> [DockerContainer] {
        let response = try await request("GET", "/containers/json?all=\(all)")
        return try JSONDecoder().decode([ContainerSummaryPayload].self, from: response.body).map(\.container)
    }

    public func startedAt(of id: String) async throws -> Date? {
        let response = try await request("GET", "/containers/\(id)/json")
        return try JSONDecoder().decode(ContainerInspectPayload.self, from: response.body).startedAt
    }

    func stats(of id: String) async throws -> ContainerStatsPayload {
        let response = try await request("GET", "/containers/\(id)/stats?stream=false&one-shot=true")
        return try JSONDecoder().decode(ContainerStatsPayload.self, from: response.body)
    }

    /// The last lines of the container's combined stdout and stderr.
    public func logs(of id: String, tail: Int = 200) async throws -> String {
        let response = try await request("GET", "/containers/\(id)/logs?stdout=true&stderr=true&tail=\(tail)", timeout: 15)
        let isMultiplexed = response.headers["content-type"]?.contains("multiplexed") ?? true
        return DockerLogDecoder.decode(response.body, isMultiplexed: isMultiplexed)
    }

    // MARK: - Actions

    public func start(_ id: String) async throws {
        try await request("POST", "/containers/\(id)/start", accepting: [304])
    }

    /// Asks the container to stop, and kills it after `grace` seconds.
    public func stop(_ id: String, grace: Int = 10) async throws {
        try await request("POST", "/containers/\(id)/stop?t=\(grace)", timeout: TimeInterval(grace + 20), accepting: [304])
    }

    public func restart(_ id: String, grace: Int = 10) async throws {
        try await request("POST", "/containers/\(id)/restart?t=\(grace)", timeout: TimeInterval(grace + 30))
    }

    /// Removes a container. `force` also removes one that is still running.
    public func remove(_ id: String, force: Bool = false) async throws {
        try await request("DELETE", "/containers/\(id)?force=\(force)", timeout: 30)
    }

    // MARK: - Transport

    @discardableResult
    private func request(
        _ method: String,
        _ path: String,
        timeout: TimeInterval = 10,
        accepting extraStatuses: Set<Int> = []
    ) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await http.send(method: method, path: path, timeout: timeout)
        } catch HTTPClientError.connectionFailed, HTTPClientError.connectionLost {
            throw DockerError.unavailable
        }
        guard response.isSuccess || extraStatuses.contains(response.status) else {
            throw DockerError.api(status: response.status, message: Self.message(in: response))
        }
        return response
    }

    /// Engine errors arrive as `{"message": "…"}`.
    private static func message(in response: HTTPResponse) -> String {
        struct Payload: Decodable { let message: String }
        return (try? JSONDecoder().decode(Payload.self, from: response.body).message)
            ?? response.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
