import Foundation
import StraysCore

/// Made-up strays for `--demo`, SwiftUI previews, and screenshots, so that
/// nothing from a real machine ever ends up in a README image.
enum DemoData {
    static var snapshot: StraysSnapshot {
        StraysSnapshot(strays: strays, capturedAt: Date(), scanDuration: 0.014)
    }

    private static let home = "/Users/dev"
    private static let shop = Project(rootPath: "\(home)/code/shop", name: "shop", marker: "package.json")
    private static let api = Project(rootPath: "\(home)/code/shop-api", name: "shop-api", marker: "pyproject.toml")

    private static let node = DevClassification(runtimeID: "node", runtimeName: "Node.js", symbol: "hexagon", isInterpreter: true)
    private static let python = DevClassification(runtimeID: "python", runtimeName: "Python", symbol: "chevron.left.forwardslash.chevron.right", isInterpreter: true)

    static var strays: [Stray] {
        [
            dev(pid: 48_211, title: "next dev", runtime: node, project: shop, minutes: 134, cpu: 12.4, megabytes: 412,
                ports: [port(3000, pid: 48_213)]),
            dev(pid: 48_377, title: "tsc --watch", runtime: node, project: shop, minutes: 133, cpu: 0.2, megabytes: 188),
            dev(pid: 51_902, title: "uvicorn app.main:app --reload", runtime: python, project: api, minutes: 47, cpu: 1.6, megabytes: 96,
                ports: [port(8000, pid: 51_902, address: "0.0.0.0")]),
            dev(pid: 51_960, title: "celery -A tasks worker", runtime: python, project: api, minutes: 46, cpu: 0, megabytes: 142),
            dev(pid: 39_004, title: "python3 -m http.server 9000", runtime: python, project: nil, minutes: 1_520, cpu: 0, megabytes: 21,
                ports: [port(9000, pid: 39_004)]),
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
