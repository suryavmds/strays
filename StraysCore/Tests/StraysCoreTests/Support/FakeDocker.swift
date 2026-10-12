import Foundation
import XCTest
@testable import StraysCore

/// A stand-in for the Docker Engine API, served on a unix socket by a
/// throwaway Python process. It keeps two containers and lets them be
/// started, stopped, restarted, and removed, so the client and collector can
/// be tested without a Docker daemon and without touching real containers.
final class FakeDocker {
    static let runningID = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
    static let stoppedID = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"

    let socketPath: String
    private let directory: String
    private let server: ThrowawayProcess

    var client: DockerClient { DockerClient(socketPath: socketPath) }

    init() throws {
        // Unix socket paths are limited to 104 bytes, and the usual
        // temporary directory is already longer than that.
        directory = "/tmp/strays-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        socketPath = directory + "/docker.sock"
        let script = directory + "/server.py"
        try Self.script.write(toFile: script, atomically: true, encoding: .utf8)

        server = try ThrowawayProcess(ThrowawayProcess.python, [script, socketPath])
        let deadline = Date().addingTimeInterval(10)
        while !DockerSocketLocator.isSocket(socketPath), Date() < deadline { usleep(20_000) }
        guard DockerSocketLocator.isSocket(socketPath) else {
            server.stop()
            throw XCTSkip("the fake Docker server did not start")
        }
    }

    /// Requests the server has received, as "METHOD path".
    func requests() async throws -> [String] {
        let response = try await UnixHTTPClient(socketPath: socketPath).send(path: "/_requests")
        return try JSONDecoder().decode([String].self, from: response.body)
    }

    func shutDown() {
        server.stop()
        try? FileManager.default.removeItem(atPath: directory)
    }

    deinit { shutDown() }

    private static let script = #"""
    import http.server, json, os, socketserver, struct, sys

    RUNNING = "aaaa1111" * 8
    STOPPED = "bbbb2222" * 8
    containers = {
        RUNNING: {
            "Id": RUNNING, "Names": ["/shop-db-1"], "Image": "postgres:17-alpine",
            "Command": "docker-entrypoint.sh postgres", "Created": 1791000000,
            "State": "running", "Status": "Up 2 hours (healthy)",
            "Ports": [
                {"IP": "0.0.0.0", "PrivatePort": 5432, "PublicPort": 54329, "Type": "tcp"},
                {"IP": "::", "PrivatePort": 5432, "PublicPort": 54329, "Type": "tcp"},
                {"PrivatePort": 9999, "Type": "tcp"},
            ],
            "Labels": {
                "com.docker.compose.project": "shop",
                "com.docker.compose.service": "db",
                "com.docker.compose.project.working_dir": "/Users/dev/code/shop",
            },
        },
        STOPPED: {
            "Id": STOPPED, "Names": ["/scratch"], "Image": "ghcr.io/acme/tool:1.2@sha256:abcdef",
            "Command": "sleep 600", "Created": 1790000000,
            "State": "exited", "Status": "Exited (0) 3 days ago",
            "Ports": [{"IP": "127.0.0.1", "PrivatePort": 80, "PublicPort": 8088, "Type": "tcp"}],
            "Labels": {},
        },
    }
    requests = []
    stats_calls = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def reply(self, status, payload=None, content_type="application/json"):
            body = b"" if payload is None else (payload if isinstance(payload, bytes) else json.dumps(payload).encode())
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True

        def chunked(self, status, chunks, content_type):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            for chunk in chunks:
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            self.close_connection = True

        def route(self, method):
            path, _, query = self.path.partition("?")
            if path == "/_requests":
                return self.reply(200, requests)
            requests.append(method + " " + self.path)
            parts = [p for p in path.split("/") if p]

            if method == "GET" and path == "/containers/json":
                return self.reply(200, list(containers.values()))
            if len(parts) < 2 or parts[0] != "containers":
                return self.reply(404, {"message": "page not found"})
            container = containers.get(parts[1])
            if container is None:
                return self.reply(404, {"message": "No such container: " + parts[1]})
            action = parts[2] if len(parts) > 2 else ""

            if method == "GET" and action == "json":
                started = "2026-10-12T01:49:53.803283838Z" if container["State"] == "running" else "0001-01-01T00:00:00Z"
                return self.reply(200, {"State": {"StartedAt": started, "Status": container["State"]}})
            if method == "GET" and action == "stats":
                n = stats_calls.get(parts[1], 0) + 1
                stats_calls[parts[1]] = n
                # Each reading: 0.5s of container CPU per 10s of system CPU, 4 cores => 20%.
                return self.reply(200, {
                    "cpu_stats": {"cpu_usage": {"total_usage": n * 500_000_000}, "system_cpu_usage": n * 10_000_000_000, "online_cpus": 4},
                    "precpu_stats": {"cpu_usage": {"total_usage": 0}},
                    "memory_stats": {"usage": 90_000_000, "stats": {"inactive_file": 10_000_000}},
                })
            if method == "GET" and action == "logs":
                frames = b"".join(struct.pack(">BxxxI", stream, len(line)) + line for stream, line in [(1, b"ready to accept connections\n"), (2, b"warning: disk is slow\n")])
                return self.chunked(200, [frames[:11], frames[11:]], "application/vnd.docker.multiplexed-stream")
            if method == "POST" and action == "start":
                if container["State"] == "running":
                    return self.reply(304)
                container["State"], container["Status"] = "running", "Up 1 second"
                return self.reply(204)
            if method == "POST" and action == "stop":
                if container["State"] != "running":
                    return self.reply(304)
                container["State"], container["Status"] = "exited", "Exited (0) 1 second ago"
                return self.reply(204)
            if method == "POST" and action == "restart":
                container["State"], container["Status"] = "running", "Up 1 second"
                return self.reply(204)
            if method == "DELETE" and action == "":
                if container["State"] == "running" and "force=true" not in query:
                    return self.reply(409, {"message": "cannot remove container \"" + container["Names"][0] + "\": container is running"})
                del containers[parts[1]]
                return self.reply(204)
            return self.reply(404, {"message": "page not found"})

        def do_GET(self): self.route("GET")
        def do_POST(self): self.route("POST")
        def do_DELETE(self): self.route("DELETE")

    class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        daemon_threads = True
        request_queue_size = 128

    path = sys.argv[1]
    if os.path.exists(path):
        os.unlink(path)
    Server(path, Handler).serve_forever()
    """#
}
