import Foundation
import StraysCore

/// Made-up strays for `--demo`, SwiftUI previews, and screenshots, so that
/// nothing from a real machine ever ends up in a README image.
enum DemoData {
    static var snapshot: StraysSnapshot {
        StraysSnapshot(strays: strays, capturedAt: Date(), scanDuration: 0.014, isDockerAvailable: true, isBrewAvailable: true, agentSessions: agentSessions)
    }

    /// Plausible-looking history so sparklines have something to draw.
    static func history(for snapshot: StraysSnapshot) -> MetricsHistory {
        var history = MetricsHistory()
        let now = Date()
        for step in 0..<60 {
            var frame = snapshot
            frame.capturedAt = now.addingTimeInterval(Double(step - 60) * 2)
            frame.strays = snapshot.strays.enumerated().map { index, stray in
                var copy = stray
                let wave = sin(Double(step) / 5 + Double(index)) * 0.5 + 0.5
                let spike = (step + index * 7) % 23 == 0 ? 2.2 : 1
                copy.cpuPercent = stray.cpuPercent * (0.35 + wave) * spike
                copy.memoryBytes = UInt64(Double(stray.memoryBytes) * (0.9 + Double(step) / 600))
                return copy
            }
            history.record(frame)
        }
        return history
    }

    private static let home = "/Users/dev"
    private static let shop = Project(rootPath: "\(home)/code/shop", name: "shop", marker: "package.json")
    private static let api = Project(rootPath: "\(home)/code/shop-api", name: "shop-api", marker: "pyproject.toml")

    private static let node = DevClassification(runtimeID: "node", runtimeName: "Node.js", symbol: "hexagon", isInterpreter: true)
    private static let python = DevClassification(runtimeID: "python", runtimeName: "Python", symbol: "chevron.left.forwardslash.chevron.right", isInterpreter: true)

    static var strays: [Stray] {
        baseStrays.map { stray in
            var stray = stray
            switch stray.title {
            case "next dev":
                stray.origin = .agent(id: "claude-code", orphaned: false)
                stray.agentSession = session("claude-code", pid: 47_990, project: shop)
            case "tsc --watch":
                stray.origin = .agent(id: "claude-code", orphaned: true)
                stray.agentSession = session("claude-code", pid: 31_207, project: shop)
            case "uvicorn app.main:app --reload":
                stray.origin = .agent(id: "codex", orphaned: false)
                stray.agentSession = session("codex", pid: 51_800, project: api)
            case "celery -A tasks worker":
                stray.origin = .terminal(name: "Ghostty")
            case "python3 -m http.server 9000":
                stray.isStale = true
            default:
                break
            }
            return stray
        }
    }

    static var agentSessions: [AgentSession] {
        [session("claude-code", pid: 47_990, project: shop), session("codex", pid: 51_800, project: api)]
    }

    private static func session(_ agent: String, pid: Int32, project: Project) -> AgentSession {
        AgentSession(
            agentID: agent,
            identity: ProcessIdentity(pid: pid, startSeconds: UInt64(Date().addingTimeInterval(-9_000).timeIntervalSince1970), startMicroseconds: 0),
            cwd: project.rootPath
        )
    }

    private static var baseStrays: [Stray] {
        [
            dev(pid: 48_211, title: "next dev", runtime: node, project: shop, minutes: 134, cpu: 12.4, megabytes: 412,
                ports: [port(3000, pid: 48_213)]),
            dev(pid: 48_377, title: "tsc --watch", runtime: node, project: shop, minutes: 133, cpu: 0.2, megabytes: 188),
            dev(pid: 51_902, title: "uvicorn app.main:app --reload", runtime: python, project: api, minutes: 47, cpu: 1.6, megabytes: 96,
                ports: [port(8000, pid: 51_902, address: "0.0.0.0")]),
            dev(pid: 51_960, title: "celery -A tasks worker", runtime: python, project: api, minutes: 46, cpu: 0, megabytes: 142),
            dev(pid: 39_004, title: "python3 -m http.server 9000", runtime: python, project: nil, minutes: 1_520, cpu: 0, megabytes: 21,
                ports: [port(9000, pid: 39_004)]),
            container("7f3a9c21d4e85b60", name: "shop-postgres-1", image: "postgres:17-alpine", ports: [(54_329, 5_432)], compose: "shop", project: shop, minutes: 128, cpu: 0.8, megabytes: 61),
            container("b21e77aa90c3f514", name: "shop-redis-1", image: "redis:8-alpine", ports: [(63_799, 6_379)], compose: "shop", project: shop, minutes: 128, cpu: 0.3, megabytes: 12),
            container("0c9d4e1f2a3b4c5d", name: "s3mock", image: "adobe/s3mock:latest", ports: [(9_090, 9_090)], compose: nil, project: nil, minutes: 0, cpu: 0, megabytes: 0, running: false),
            service("postgresql@17", pid: 755, port: 5_432, minutes: 3_700, megabytes: 48),
            service("redis", pid: nil, port: nil, minutes: 0, megabytes: 0, running: false),
            other(pid: 20_009, title: "Visual Studio Code", subtitle: "Code Helper (Plugin)", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", minutes: 300, megabytes: 64,
                  ports: [port(57_482, pid: 20_009)]),
            other(pid: 1_045, title: "ollama serve", subtitle: nil, path: "/opt/homebrew/bin/ollama", minutes: 4_300, megabytes: 38,
                  ports: [port(11_434, pid: 1_045)]),
            other(pid: 625, title: "ControlCenter", subtitle: nil, path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", minutes: 9_000, megabytes: 33,
                  ports: [port(5000, pid: 625, address: "*"), port(7000, pid: 625, address: "*")]),
            other(pid: 412, title: "httpd", subtitle: nil, path: "/usr/sbin/httpd", minutes: 9_000, megabytes: 0, uid: 0,
                  ports: [port(80, pid: 412, address: "*")]),
        ]
    }

    static let logs = """
    PostgreSQL Database directory appears to contain a database; Skipping initialization
    2026-10-12 04:38:11.201 UTC [1] LOG:  starting PostgreSQL 17.2 on aarch64-unknown-linux-musl
    2026-10-12 04:38:11.201 UTC [1] LOG:  listening on IPv4 address "0.0.0.0", port 5432
    2026-10-12 04:38:11.204 UTC [1] LOG:  listening on Unix socket "/var/run/postgresql/.s.PGSQL.5432"
    2026-10-12 04:38:11.231 UTC [1] LOG:  database system is ready to accept connections
    2026-10-12 04:43:11.292 UTC [27] LOG:  checkpoint starting: time
    2026-10-12 04:43:12.118 UTC [27] LOG:  checkpoint complete: wrote 11 buffers (0.1%)
    """

    private static func container(_ id: String, name: String, image: String, ports: [(UInt16, UInt16)], compose: String?, project: Project?, minutes: Double, cpu: Double, megabytes: Double, running: Bool = true) -> Stray {
        let started = running ? Date().addingTimeInterval(-minutes * 60) : nil
        let container = DockerContainer(
            id: id + String(repeating: "0", count: 48),
            name: name,
            image: image,
            command: "docker-entrypoint.sh",
            state: running ? .running : .exited,
            status: running ? "Up \(StraysFormat.duration(minutes * 60)) (healthy)" : "Exited (255) 3 hours ago",
            createdAt: Date().addingTimeInterval(-86_400 * 9),
            startedAt: started,
            ports: ports.map { .init(hostIP: "0.0.0.0", hostPort: $0.0, containerPort: $0.1, transport: .tcp) },
            composeProject: compose,
            composeService: compose.map { _ in name.split(separator: "-").dropFirst().first.map(String.init) ?? name },
            composeWorkingDirectory: project?.rootPath,
            cpuPercent: running ? cpu : nil,
            memoryBytes: running ? UInt64(megabytes * 1_048_576) : nil
        )
        return Stray(
            id: "docker:\(container.id)",
            kind: .container(container),
            category: .docker,
            title: name,
            subtitle: image,
            ports: running ? container.portSummaries : [],
            project: project,
            startedAt: started,
            cpuPercent: cpu,
            memoryBytes: UInt64(megabytes * 1_048_576),
            isRunning: running
        )
    }

    private static func service(_ name: String, pid: Int32?, port: UInt16?, minutes: Double, megabytes: Double, running: Bool = true) -> Stray {
        let service = BrewService(
            name: name,
            serviceName: "homebrew.mxcl.\(name)",
            status: running ? .started : .stopped,
            pid: pid,
            user: running ? "dev" : nil,
            file: "\(home)/Library/LaunchAgents/homebrew.mxcl.\(name).plist",
            command: "/opt/homebrew/opt/\(name)/bin/\(name.split(separator: "@").first ?? "service")"
        )
        let process = pid.map { pid in
            ProcessGroup(root: details(
                pid: pid, name: "postgres", path: "/opt/homebrew/opt/\(name)/bin/postgres",
                arguments: ["/opt/homebrew/opt/\(name)/bin/postgres", "-D", "/opt/homebrew/var/\(name)"],
                cwd: "/opt/homebrew/var/\(name)", minutes: minutes, cpu: 0.1, megabytes: megabytes
            ))
        }
        return Stray(
            id: "brew:\(name)",
            kind: .brewService(service, process: process),
            category: .brew,
            title: name,
            subtitle: "Homebrew · \(service.statusLabel)",
            ports: port.map { [self.port($0, pid: pid ?? 0)] } ?? [],
            startedAt: running ? Date().addingTimeInterval(-minutes * 60) : nil,
            cpuPercent: running ? 0.1 : 0,
            memoryBytes: UInt64(megabytes * 1_048_576),
            isRunning: running
        )
    }

    private static func port(_ number: UInt16, pid: Int32, address: String = "127.0.0.1") -> PortSummary {
        PortSummary(port: number, transport: .tcp, addresses: [address], isLANVisible: !ListeningPort.isLoopback(address), pid: pid)
    }

    private static func details(pid: Int32, name: String, path: String, arguments: [String], cwd: String?, minutes: Double, cpu: Double, megabytes: Double, uid: UInt32 = 501) -> ProcessDetails {
        let start = Date().addingTimeInterval(-minutes * 60).timeIntervalSince1970
        return ProcessDetails(
            entry: ProcessEntry(
                identity: ProcessIdentity(pid: pid, startSeconds: UInt64(start), startMicroseconds: 0),
                ppid: 1, pgid: pid, uid: uid, name: name
            ),
            executablePath: path,
            arguments: arguments,
            environment: ["PATH": "/usr/local/bin:/usr/bin:/bin", "NODE_ENV": "development", "API_TOKEN": "sk-demo-not-a-real-secret"],
            cwd: cwd,
            username: uid == 0 ? "root" : "dev",
            cpuPercent: cpu,
            residentBytes: UInt64(megabytes * 1_048_576),
            isInspectable: uid != 0
        )
    }

    private static func dev(pid: Int32, title: String, runtime: DevClassification, project: Project?, minutes: Double, cpu: Double, megabytes: Double, ports: [PortSummary] = []) -> Stray {
        let words = title.split(separator: " ").map(String.init)
        let root = details(
            pid: pid, name: runtime.runtimeID, path: "/usr/local/bin/\(runtime.runtimeID)", arguments: words,
            cwd: project?.rootPath ?? home, minutes: minutes, cpu: cpu, megabytes: megabytes
        )
        return Stray(
            id: "process:\(root.identity.key)",
            kind: .process(ProcessGroup(root: root, runtime: runtime)),
            category: .dev,
            title: title,
            subtitle: runtime.runtimeName,
            ports: ports,
            project: project,
            startedAt: root.identity.startDate,
            cpuPercent: cpu,
            memoryBytes: root.residentBytes
        )
    }

    private static func other(pid: Int32, title: String, subtitle: String?, path: String, minutes: Double, megabytes: Double, uid: UInt32 = 501, ports: [PortSummary]) -> Stray {
        let name = (path as NSString).lastPathComponent
        let root = details(pid: pid, name: name, path: path, arguments: [name], cwd: "/", minutes: minutes, cpu: 0, megabytes: megabytes, uid: uid)
        return Stray(
            id: "process:\(root.identity.key)",
            kind: .process(ProcessGroup(root: root)),
            category: uid == 501 ? .app : .system,
            title: title,
            subtitle: subtitle,
            ports: ports,
            startedAt: root.identity.startDate,
            memoryBytes: root.residentBytes
        )
    }
}
