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
///
/// Looking at the filesystem can block for as long as it likes: macOS
/// stops the read of a file in Documents, Desktop, or Downloads until the
/// user answers a privacy prompt, and a network volume can simply hang. So
/// in its `background` mode the resolver never touches the disk on the
/// caller's thread. It answers from its cache, starts the lookup on a queue
/// of its own, and has the answer for the next call. A scan can then never
/// be held up by a folder.
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

    /// Where `package.json` may be opened to learn a project's real name.
    public enum PackageNamePolicy: String, Sendable, CaseIterable {
        /// Never. Projects are named after their folder.
        case never
        /// Only where macOS lets any app read without asking. Projects in
        /// Documents, Desktop, Downloads, iCloud Drive, or on another
        /// volume keep their folder name.
        case unprotectedOnly
        /// Everywhere. macOS will ask the user for access to protected
        /// folders the first time.
        case everywhere
    }

    public enum Mode: Sendable {
        /// Look on the caller's thread and return the answer. For tests and
        /// one-shot tools.
        case inline
        /// Never block the caller: return what is cached, look in the background.
        case background
    }

    private struct CacheEntry {
        let project: Project?
        let expires: Date
    }

    private let homeDirectory: String
    private let markers: [String]
    private let cacheLifetime: TimeInterval
    private let mode: Mode
    /// Checking that a marker exists never needs permission; reading a
    /// file's contents in Documents, Desktop, or Downloads does.
    private var packageNamePolicy: PackageNamePolicy
    /// Finds project roots. Only checks that files exist, which is quick
    /// and never prompts.
    private let queue = DispatchQueue(label: "strays.project-resolver", qos: .utility)
    /// Reads package names. Serial, and separate, so that if a privacy
    /// prompt is up exactly one thread waits on it and nothing else does.
    private let nameQueue = DispatchQueue(label: "strays.project-names", qos: .utility)
    /// Called on the background queue before each lookup. Tests use it to
    /// stand in for a filesystem that does not answer.
    private let willResolve: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var changes = 0
    private var pending: Set<String> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        homeDirectory: String = NSHomeDirectory(),
        markers: [String] = ProjectResolver.defaultMarkers,
        cacheLifetime: TimeInterval = 60,
        mode: Mode = .inline,
        packageNames: PackageNamePolicy = .everywhere
    ) {
        self.homeDirectory = Self.standardize(homeDirectory)
        self.markers = markers
        self.cacheLifetime = cacheLifetime
        self.mode = mode
        packageNamePolicy = packageNames
        willResolve = nil
    }

    init(homeDirectory: String, mode: Mode, cacheLifetime: TimeInterval = 60, willResolve: @escaping @Sendable (String) -> Void) {
        self.homeDirectory = Self.standardize(homeDirectory)
        markers = Self.defaultMarkers
        self.cacheLifetime = cacheLifetime
        self.mode = mode
        packageNamePolicy = .everywhere
        self.willResolve = willResolve
    }

    /// Changes where package names are read, and forgets what was cached
    /// so the new policy shows up on the next lookup.
    public func setPackageNamePolicy(_ policy: PackageNamePolicy) {
        lock.lock()
        packageNamePolicy = policy
        cache.removeAll()
        changes += 1
        lock.unlock()
    }

    /// Folders macOS guards with a privacy prompt: reading a file's
    /// contents inside one makes the system ask the user first.
    public func isProtectedByPrivacyPrompt(_ path: String) -> Bool {
        let standardized = Self.standardize(path)
        let guarded = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { homeDirectory + "/" + $0 }
        if guarded.contains(where: { standardized == $0 || standardized.hasPrefix($0 + "/") }) { return true }
        // Removable and network volumes are guarded as well.
        return standardized.hasPrefix("/Volumes/")
    }

    /// The project containing `directory`.
    ///
    /// In `background` mode this returns nil for a directory it has not
    /// finished looking at yet, and the real answer on a later call.
    public func project(forDirectory directory: String) -> Project? {
        let start = Self.standardize(directory)
        let now = Date()

        lock.lock()
        let cached = cache[start]
        if let cached, cached.expires > now {
            lock.unlock()
            return cached.project
        }

        guard mode == .background else {
            lock.unlock()
            var project = locate(from: start)
            if let found = project, let name = packageName(in: found.rootPath) {
                project = Project(rootPath: found.rootPath, name: name, marker: found.marker)
            }
            store(project, for: start, at: now)
            return project
        }

        // Stale or unknown: refresh in the background, and meanwhile keep
        // answering with what we last knew rather than flickering to nil.
        if pending.insert(start).inserted {
            queue.async { [weak self] in
                guard let self else { return }
                self.willResolve?(start)
                let located = self.locate(from: start)
                // Keep a name we already read; the folder name otherwise.
                let project = located.map { found in
                    cached?.project?.rootPath == found.rootPath ? cached?.project ?? found : found
                }
                self.store(project, for: start, at: Date())
                self.finish(start)
                if let located { self.readName(of: located, for: start) }
            }
        }
        lock.unlock()
        return cached?.project
    }

    /// Replaces the folder name with the package name once it has been
    /// read. If macOS is asking the user for permission, this waits; the
    /// project is already usable under its folder name in the meantime.
    private func readName(of project: Project, for directory: String) {
        guard mayReadPackageName(in: project.rootPath) else { return }
        nameQueue.async { [weak self] in
            guard let self, let name = self.packageName(in: project.rootPath), name != project.name else { return }
            self.store(Project(rootPath: project.rootPath, name: name, marker: project.marker), for: directory, at: Date())
        }
    }

    /// Goes up every time an answer changes: a project found, or its name
    /// read. A caller that built something from earlier answers compares
    /// revisions to know whether it is worth building again.
    public var revision: Int {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }

    /// True while any directory is still being looked at.
    public var hasPendingLookups: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    /// Waits for the background lookups to finish, but no longer than
    /// `timeout`. Lets a scan include projects on its first pass when the
    /// disk answers promptly, without ever depending on it.
    public func settle(timeout: TimeInterval) async {
        guard hasPendingLookups else { return }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.releaseWaiters()
        }
        await withCheckedContinuation { continuation in
            lock.lock()
            if pending.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
        deadline.cancel()
    }

    public func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func store(_ project: Project?, for directory: String, at date: Date) {
        lock.lock()
        if cache.count > 2_000 { cache.removeAll(keepingCapacity: true) }
        if cache[directory]?.project != project { changes += 1 }
        cache[directory] = CacheEntry(project: project, expires: date.addingTimeInterval(cacheLifetime))
        lock.unlock()
    }

    private func finish(_ directory: String) {
        lock.lock()
        pending.remove(directory)
        let done = pending.isEmpty
        lock.unlock()
        if done { releaseWaiters() }
    }

    private func releaseWaiters() {
        lock.lock()
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    /// Finds the project root above `start`, named after its folder. Only
    /// asks whether files exist.
    private func locate(from start: String) -> Project? {
        let fileManager = FileManager.default
        var directory = start
        // The home folder and the filesystem root are never projects, even
        // when they hold a `.git` (a dotfiles repository, say).
        for _ in 0..<64 {
            if directory == "/" || directory == homeDirectory || directory.isEmpty { return nil }
            for marker in markers where fileManager.fileExists(atPath: directory + "/" + marker) {
                return Project(rootPath: directory, name: (directory as NSString).lastPathComponent, marker: marker)
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The `name` field of the directory's `package.json`, if it has one.
    /// This reads a file's contents, which is what macOS may ask the user
    /// about; if they say no, the folder's own name is used instead.
    private func mayReadPackageName(in directory: String) -> Bool {
        lock.lock()
        let policy = packageNamePolicy
        lock.unlock()
        switch policy {
        case .never: return false
        case .everywhere: return true
        case .unprotectedOnly: return !isProtectedByPrivacyPrompt(directory)
        }
    }

    private func packageName(in directory: String) -> String? {
        guard mayReadPackageName(in: directory) else { return nil }
        let url = URL(fileURLWithPath: directory + "/package.json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // A megabyte is far more than any real package.json; do not read on.
        guard let data = try? handle.read(upToCount: 1 << 20),
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
