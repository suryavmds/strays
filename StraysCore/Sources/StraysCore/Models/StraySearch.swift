import Foundation

extension Stray {
    /// Everything a search should be able to find this stray by.
    public var searchText: String {
        var parts = [title, category.rawValue]
        if let subtitle { parts.append(subtitle) }
        if let project {
            parts.append(project.name)
            parts.append(project.rootPath)
        }
        for port in ports {
            parts.append(":\(port.port)")
            parts.append(port.transport.rawValue)
        }
        if isLANVisible { parts.append("lan") }
        if let container {
            parts += [container.image, container.shortID, container.status, "docker", "container"]
            if let compose = container.composeProject { parts.append(compose) }
            if let service = container.composeService { parts.append(service) }
        }
        if let brewService {
            parts += ["brew", "homebrew", "service", brewService.statusLabel]
            if let command = brewService.command { parts.append(command) }
        }
        if let group = processGroup {
            parts.append(String(group.root.pid))
            parts.append(group.root.arguments.joined(separator: " "))
            if let cwd = group.root.cwd { parts.append(cwd) }
            if let path = group.root.executablePath { parts.append(path) }
        }
        return parts.joined(separator: "\n").lowercased()
    }

    /// Every whitespace-separated word of the query must appear somewhere.
    /// An empty query matches everything.
    public func matches(query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = searchText
        return words.allSatisfy { haystack.contains($0) }
    }
}
