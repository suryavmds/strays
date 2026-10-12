import Foundation

/// The project a process belongs to, inferred from its working directory.
public struct Project: Hashable, Sendable, Codable, Identifiable {
    public let rootPath: String
    public let name: String
    /// The file or folder that marked this directory as a project root.
    public let marker: String

    public init(rootPath: String, name: String, marker: String) {
        self.rootPath = rootPath
        self.name = name
        self.marker = marker
    }

    public var id: String { rootPath }
}

/// Walks up from a directory to the nearest project marker.
public final class ProjectResolver: @unchecked Sendable {
    public static let defaultMarkers = [
        ".git",
        "package.json",
        "pyproject.toml",
        "Cargo.toml",
        "go.mod",
        "Gemfile",
        "composer.json",
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
    ]

    private struct CacheEntry {
        let project: Project?
        let expires: Date
    }

    private let homeDirectory: String
    private let markers: [String]
    private let cacheLifetime: TimeInterval
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    public init(
        homeDirectory: String = NSHomeDirectory(),
        markers: [String] = ProjectResolver.defaultMarkers,
        cacheLifetime: TimeInterval = 60
    ) {
        self.homeDirectory = Self.standardize(homeDirectory)
        self.markers = markers
        self.cacheLifetime = cacheLifetime
    }

    public func project(forDirectory directory: String) -> Project? {
        let start = Self.standardize(directory)
        let now = Date()

        lock.lock()
        if let cached = cache[start], cached.expires > now {
            lock.unlock()
            return cached.project
        }
        lock.unlock()

        let project = resolve(from: start)

        lock.lock()
        if cache.count > 2_000 { cache.removeAll(keepingCapacity: true) }
        cache[start] = CacheEntry(project: project, expires: now.addingTimeInterval(cacheLifetime))
        lock.unlock()
        return project
    }

    public func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func resolve(from start: String) -> Project? {
        let fileManager = FileManager.default
        var directory = start
        // The home folder and the filesystem root are never projects, even
        // when they hold a `.git` (a dotfiles repository, say).
        for _ in 0..<64 {
            if directory == "/" || directory == homeDirectory || directory.isEmpty { return nil }
            for marker in markers where fileManager.fileExists(atPath: directory + "/" + marker) {
                return Project(
                    rootPath: directory,
                    name: packageName(in: directory) ?? (directory as NSString).lastPathComponent,
                    marker: marker
                )
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The `name` field of the directory's `package.json`, if it has one.
    private func packageName(in directory: String) -> String? {
        let url = URL(fileURLWithPath: directory + "/package.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size < 1 << 20,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String
        else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func standardize(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }
}
