import Foundation
import StraysCore

// A minimal front end to StraysCore: `strays` prints what is running.
// The full command set (stop, json output) arrives with a later milestone.

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? String(text.prefix(width - 1)) + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
}

func describe(_ ports: [PortSummary]) -> String {
    ports.map { port in
        let transport = port.transport == .udp ? "/udp" : ""
        return "\(port.port)\(transport)\(port.isLANVisible ? "!" : "")"
    }.joined(separator: ",")
}

let includeAll = CommandLine.arguments.contains("--all")
let monitor = Monitor(minimumAge: 0)
// CPU usage is a delta between two scans, so scan twice.
await monitor.refresh()
try? await Task.sleep(for: .milliseconds(400))
let snapshot = await monitor.refresh()

/// By default: what you left running. With --all: apps, system daemons,
/// and stopped containers and services too.
func isShown(_ stray: Stray) -> Bool {
    includeAll || (stray.isRunning && [.dev, .docker, .brew].contains(stray.category))
}

print(pad("CATEGORY", 9) + pad("PID", 7) + pad("CPU%", 7) + pad("MEM", 9) + pad("PORTS", 22) + pad("PROJECT", 22) + "NAME")
for stray in snapshot.strays where isShown(stray) {
    let pid = stray.processGroup.map { String($0.root.pid) } ?? "-"
    let memory = ByteCountFormatter.string(fromByteCount: Int64(stray.memoryBytes), countStyle: .memory)
    let members = stray.processGroup.map { $0.members.count } ?? 1
    let suffix = members > 1 ? "  (+\(members - 1))" : ""
    print(
        pad(stray.category.rawValue, 9) + pad(pid, 7) + pad(String(format: "%.1f", stray.cpuPercent), 7)
            + pad(memory, 9) + pad(describe(stray.ports), 22) + pad(stray.project?.name ?? "-", 22)
            + stray.title + suffix + (stray.isRunning ? "" : "  [stopped]")
    )
}
let shown = snapshot.strays.filter(isShown).count
print("\n\(shown) shown of \(snapshot.strays.count) · scan took \(Int(snapshot.scanDuration * 1000)) ms · '!' marks LAN-visible ports" + (includeAll ? "" : " · --all for everything"))
