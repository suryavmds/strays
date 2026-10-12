import Foundation

/// Combines process strays with Docker containers and Homebrew services
/// into the one list the UI shows. Pure: no I/O.
public struct StrayMerger: Sendable {
    private let projectResolver: ProjectResolver

    public init(projectResolver: ProjectResolver) {
        self.projectResolver = projectResolver
    }

    public func merge(processes: [Stray], docker: DockerSnapshot, brew: BrewSnapshot) -> [Stray] {
        var processes = processes
        var result: [Stray] = []

        // A running Homebrew service takes over its process: one item, not two.
        for service in brew.services {
            let index = service.pid.flatMap { pid in
                processes.firstIndex { $0.processGroup?.members.contains { $0.pid == pid } ?? false }
            }
            let process = index.map { processes.remove(at: $0) }
            result.append(stray(for: service, process: process))
        }

        // Ports published by containers are held, on the host, by Docker's
        // own helper. Showing them there too would list every port twice.
        let published = Set(docker.containers.lazy.filter(\.isRunning).flatMap { container in
            container.ports.map { PortKey(port: $0.hostPort, transport: $0.transport) }
        })
        if !published.isEmpty {
            processes = processes.compactMap { stray in
                guard stray.category == .app || stray.category == .system else { return stray }
                let remaining = stray.ports.filter { !published.contains(PortKey(port: $0.port, transport: $0.transport)) }
                guard remaining.count != stray.ports.count else { return stray }
                // Docker's helper with nothing left of its own is not worth a row.
                guard remaining.contains(where: { $0.transport == .tcp }) else { return nil }
                var copy = stray
                copy.ports = remaining
                return copy
            }
        }

        result += processes
        result += docker.containers.map(stray(for:))
        return result.sorted(by: Self.runningThenNewest)
    }

    // MARK: - Containers

    private func stray(for container: DockerContainer) -> Stray {
        Stray(
            id: "docker:\(container.id)",
            kind: .container(container),
            category: .docker,
            title: container.name,
            subtitle: Self.shortImageName(container.image),
            ports: container.isRunning ? container.portSummaries : [],
            project: project(for: container),
            startedAt: container.isRunning ? container.startedAt : nil,
            cpuPercent: container.cpuPercent ?? 0,
            memoryBytes: container.memoryBytes ?? 0,
            isRunning: container.isRunning
        )
    }

    /// A compose container belongs to the project in the folder it was
    /// started from, so it sits next to that project's dev processes.
    private func project(for container: DockerContainer) -> Project? {
        if let directory = container.composeWorkingDirectory, !directory.isEmpty {
            if let project = projectResolver.project(forDirectory: directory) { return project }
            let name = container.composeProject ?? (directory as NSString).lastPathComponent
            return Project(rootPath: directory, name: name, marker: "compose")
        }
        if let compose = container.composeProject {
            return Project(rootPath: "compose:\(compose)", name: compose, marker: "compose")
        }
        return nil
    }

    /// `registry.example.com/team/api:1.2@sha256:…` → `team/api:1.2`.
    static func shortImageName(_ image: String) -> String {
        var name = image
        if let digest = name.range(of: "@sha256:") { name = String(name[..<digest.lowerBound]) }
        if name.hasPrefix("sha256:") { return String(name.dropFirst("sha256:".count).prefix(12)) }
        let parts = name.split(separator: "/")
        // A first component with a dot or a port is a registry host.
        if parts.count > 1, let first = parts.first, first.contains(".") || first.contains(":") {
            name = parts.dropFirst().joined(separator: "/")
        }
        return name
    }

    // MARK: - Homebrew

    private func stray(for service: BrewService, process: Stray?) -> Stray {
        Stray(
            id: "brew:\(service.name)",
            kind: .brewService(service, process: process?.processGroup),
            category: .brew,
            title: service.name,
            subtitle: "Homebrew · \(service.statusLabel)",
            ports: process?.ports ?? [],
            startedAt: process?.startedAt,
            cpuPercent: process?.cpuPercent ?? 0,
            memoryBytes: process?.memoryBytes ?? 0,
            isRunning: service.isRunning
        )
    }

    // MARK: - Ordering

    private struct PortKey: Hashable {
        let port: UInt16
        let transport: ListeningPort.Transport
    }

    /// Running things first, newest first; stopped ones after, by name.
    static func runningThenNewest(_ lhs: Stray, _ rhs: Stray) -> Bool {
        if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
        if !lhs.isRunning { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
        return StrayBuilder.newestFirst(lhs, rhs)
    }
}
