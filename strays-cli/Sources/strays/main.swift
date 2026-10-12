import Foundation
import StraysCore

// A small command-line front end to StraysCore.
//
//   strays                 what you left running
//   strays --all           also apps, system daemons, and stopped things
//   strays inspect <pid>   where one process came from, and the environment
//                          variables that could identify the agent behind it
//   strays agents          the agent profiles Strays knows

let usage = """
usage: strays [--all]
       strays inspect <pid> [--env]
       strays agents
       strays --version
"""

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? String(text.prefix(width - 1)) + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
}

func describe(_ ports: [PortSummary]) -> String {
    ports.map { port in
        let transport = port.transport == .udp ? "/udp" : ""
        return "\(port.port)\(transport)\(port.isLANVisible ? "!" : "")"
    }.joined(separator: ",")
}

func describe(_ origin: Origin, catalog: AgentCatalog) -> String {
    switch origin {
    case let .agent(id, orphaned):
        let name = catalog.agent(withID: id)?.displayName ?? id
        return orphaned ? "Orphaned from \(name)" : name
    case let .terminal(name): return name
    case let .ide(name): return name
    case .unknown: return "Unknown origin"
    }
}

func abbreviate(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

// MARK: - strays [--all]

func list(includeAll: Bool) async {
    let monitor = Monitor(minimumAge: 0)
    let catalog = AgentCatalog.load()
    // CPU usage is a delta between two scans, so scan twice.
    await monitor.refresh()
    try? await Task.sleep(for: .milliseconds(400))
    let snapshot = await monitor.refresh()

    /// By default: what you left running. With --all: everything.
    func isShown(_ stray: Stray) -> Bool {
        includeAll || (stray.isRunning && [.dev, .docker, .brew].contains(stray.category))
    }

    print(pad("KIND", 8) + pad("PID", 7) + pad("CPU%", 6) + pad("MEM", 9) + pad("PORTS", 16) + pad("PROJECT", 18) + pad("ORIGIN", 28) + "NAME")
    for stray in snapshot.strays where isShown(stray) {
        let pid = stray.processGroup.map { String($0.root.pid) } ?? "-"
        let members = stray.processGroup.map { $0.members.count } ?? 1
        var name = stray.title
        if members > 1 { name += "  (+\(members - 1))" }
        if !stray.isRunning { name += "  [stopped]" }
        if stray.isStale { name += "  [stale]" }
        let origin = stray.category == .dev ? describe(stray.origin, catalog: catalog) : "-"
        print(
            pad(stray.category.rawValue, 8) + pad(pid, 7) + pad(String(format: "%.1f", stray.cpuPercent), 6)
                + pad(StraysFormat.memory(stray.memoryBytes), 9) + pad(describe(stray.ports), 16)
                + pad(stray.project?.name ?? "-", 18) + pad(origin, 28) + name
        )
    }

    let shown = snapshot.strays.filter(isShown).count
    var footer = "\n\(shown) shown of \(snapshot.strays.count) · scan took \(Int(snapshot.scanDuration * 1000)) ms · '!' marks LAN-visible ports"
    if !snapshot.agentSessions.isEmpty {
        let names = Dictionary(grouping: snapshot.agentSessions, by: \.agentID)
            .map { "\(catalog.agent(withID: $0.key)?.displayName ?? $0.key) ×\($0.value.count)" }
            .sorted()
        footer += "\nagent sessions running: " + names.joined(separator: ", ")
    }
    if !includeAll { footer += "\n--all for everything" }
    print(footer)
}

// MARK: - strays inspect <pid>

func inspect(pid: Int32, showAllEnvironment: Bool) async {
    let monitor = Monitor(minimumAge: 0, sources: [])
    let catalog = AgentCatalog.load()
    guard let inspection = await monitor.inspect(pid: pid) else {
        print("No process with PID \(pid).")
        exit(1)
    }
    let process = inspection.details

    print("PID \(process.pid)  \(process.executableName)  (user \(process.username), started \(StraysFormat.uptime(since: process.identity.startDate)) ago)")
    if let path = process.executablePath { print("  executable  \(abbreviate(path))") }
    if let cwd = process.cwd { print("  directory   \(abbreviate(cwd))") }
    if !process.arguments.isEmpty {
        print("  command     \(SecretMasker.maskArguments(process.arguments).joined(separator: " "))")
    }

    print("\nAncestors, nearest first:")
    if inspection.ancestors.isEmpty { print("  (none)") }
    for ancestor in inspection.ancestors {
        let path = ancestor.executablePath.map(abbreviate) ?? ancestor.entry.name
        let role = ancestor.role.map { "   <- \($0)" } ?? ""
        print("  " + pad(String(ancestor.entry.pid), 8) + path + role)
    }

    print("\nVerdict: \(describe(inspection.origin, catalog: catalog))")
    if let session = inspection.session {
        let state = inspection.origin.isOrphaned ? "exited" : "running"
        print("  session PID \(session.pid) (\(state))" + (session.cwd.map { ", started in \(abbreviate($0))" } ?? ""))
    }

    if process.environment.isEmpty {
        print("\nEnvironment: not readable.")
        print(process.isInspectable
            ? "  macOS can withhold the environment of Apple's own system binaries (/bin/zsh, /usr/bin/ruby, …).\n  Inspect a node, python, or other third-party process instead."
            : "  This process belongs to another user.")
        return
    }

    print("\nEnvironment variables that look agent-related (\(inspection.candidateMarkers.count) of \(process.environment.count)):")
    if inspection.candidateMarkers.isEmpty {
        print("  none. Nothing here could serve as a marker.")
    }
    for (name, value) in inspection.candidateMarkers.sorted(by: { $0.key < $1.key }) {
        // Values can be long or private; show enough to judge a marker by.
        let shown = SecretMasker.display(name: name, value: value)
        print("  \(name)=\(shown.count > 48 ? String(shown.prefix(47)) + "…" : shown)")
    }
    if showAllEnvironment {
        print("\nAll variable names:")
        print("  " + process.environment.keys.sorted().joined(separator: " "))
    } else {
        print("\n--env lists every variable name.")
    }
}

// MARK: - strays agents

func agents() {
    let catalog = AgentCatalog.load()
    for agent in catalog.agents {
        print("\(agent.displayName)  (\(agent.id))")
        let matcher = agent.ancestorMatchers
        if let names = matcher.executableNames, !names.isEmpty { print("  executables   \(names.joined(separator: ", "))") }
        if let fragments = matcher.pathFragments, !fragments.isEmpty { print("  path contains \(fragments.joined(separator: ", "))") }
        if let patterns = matcher.argumentPatterns, !patterns.isEmpty { print("  command line  \(patterns.joined(separator: "  "))") }
        if agent.envMarkers.isEmpty {
            print("  env markers   none verified: orphans of this agent cannot be recognised")
        } else {
            let markers = agent.envMarkers.map { marker in
                marker.name + (marker.value.map { "=\($0)" } ?? marker.valuePrefix.map { "=\($0)…" } ?? "")
            }
            print("  env markers   \(markers.joined(separator: ", "))  (verified)")
        }
        if let variable = agent.sessionPIDVariable { print("  session PID   $\(variable)") }
        print("")
    }
    let override = AgentCatalog.defaultOverrideURL
    let exists = FileManager.default.fileExists(atPath: override.path)
    print("Override file: \(abbreviate(override.path))" + (exists ? "" : "  (not present)"))
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil:
    await list(includeAll: false)
case "--all":
    await list(includeAll: true)
case "inspect":
    guard arguments.count >= 2, let pid = Int32(arguments[1]) else {
        print(usage)
        exit(2)
    }
    await inspect(pid: pid, showAllEnvironment: arguments.contains("--env"))
case "agents":
    agents()
case "--version", "-v":
    print("strays \(StraysCore.version)")
case "--help", "-h", "help":
    print(usage)
default:
    print(usage)
    exit(2)
}
