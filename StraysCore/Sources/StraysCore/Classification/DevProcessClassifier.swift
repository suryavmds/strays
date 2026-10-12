import Foundation

/// Why a process without a port still counts as a dev process.
public struct DevClassification: Sendable, Hashable {
    /// A runtime id from `runtimes.json`, or `binary` for a compiled program
    /// that lives inside a project.
    public let runtimeID: String
    public let runtimeName: String
    public let symbol: String?
    public let isInterpreter: Bool

    public static let binaryRuntimeID = "binary"

    public init(runtimeID: String, runtimeName: String, symbol: String? = nil, isInterpreter: Bool = false) {
        self.runtimeID = runtimeID
        self.runtimeName = runtimeName
        self.symbol = symbol
        self.isInterpreter = isInterpreter
    }
}

/// Applies `RuntimeRules` to processes. Classification is two-phase so the
/// expensive facts are only read for plausible candidates:
///
/// 1. `runtime(forExecutablePath:)` needs just the executable path.
/// 2. `classify(_:)` also checks the working directory, command line, and age.
public struct DevProcessClassifier: Sendable {
    private struct CompiledRuntime: Sendable {
        let classification: DevClassification
        let names: Set<String>
        let namePatterns: PatternSet
    }

    private let homeDirectory: String
    private let runtimes: [CompiledRuntime]
    private let devBinaryPaths: PatternSet
    private let devBinaryExcludedPaths: PatternSet
    private let ignoredNames: Set<String>
    private let ignoredCwds: PatternSet
    private let ignoredCommandLines: PatternSet
    private let projectResolver: ProjectResolver
    public let minimumAge: TimeInterval

    public init(
        rules: RuntimeRules = .bundled,
        homeDirectory: String = NSHomeDirectory(),
        projectResolver: ProjectResolver? = nil,
        minimumAge: TimeInterval? = nil
    ) {
        let home = (homeDirectory as NSString).standardizingPath
        self.homeDirectory = home
        self.projectResolver = projectResolver ?? ProjectResolver(homeDirectory: home)
        self.minimumAge = minimumAge ?? rules.minimumAgeSeconds ?? 0
        runtimes = rules.runtimes.map { runtime in
            CompiledRuntime(
                classification: DevClassification(
                    runtimeID: runtime.id,
                    runtimeName: runtime.displayName,
                    symbol: runtime.symbol,
                    isInterpreter: runtime.isInterpreter ?? false
                ),
                names: Set(runtime.executableNames ?? []),
                namePatterns: PatternSet(runtime.executableNamePatterns ?? [], homeDirectory: home)
            )
        }
        devBinaryPaths = PatternSet(rules.devBinaryPathPatterns ?? [], homeDirectory: home)
        devBinaryExcludedPaths = PatternSet(rules.devBinaryExcludedPathPatterns ?? [], homeDirectory: home)
        ignoredNames = Set(rules.ignore?.executableNames ?? [])
        ignoredCwds = PatternSet(rules.ignore?.cwdPatterns ?? [], homeDirectory: home)
        ignoredCommandLines = PatternSet(rules.ignore?.commandLinePatterns ?? [], homeDirectory: home)
    }

    /// Phase 1: does the executable look like a dev runtime or a dev binary?
    public func runtime(forExecutablePath path: String?, name: String) -> DevClassification? {
        let executableName = path.map { ($0 as NSString).lastPathComponent } ?? name
        if ignoredNames.contains(executableName) { return nil }

        for runtime in runtimes
            where runtime.names.contains(executableName) || runtime.namePatterns.matches(executableName) {
            return runtime.classification
        }

        guard let path, !devBinaryExcludedPaths.matches(path) else { return nil }
        let binary = DevClassification(runtimeID: DevClassification.binaryRuntimeID, runtimeName: "Binary", symbol: "terminal")
        if devBinaryPaths.matches(path) { return binary }
        // A compiled program that lives inside a project folder: `go build`
        // output, a C binary, and so on.
        if isInsideHome(path), projectResolver.project(forDirectory: (path as NSString).deletingLastPathComponent) != nil {
            return binary
        }
        return nil
    }

    /// Phase 2: the full check, including where the process is running.
    ///
    /// The "inside the home folder" rule exists to keep unrelated runtimes
    /// out of the list. It is waived when there is independent evidence
    /// that this is the developer's process: it listens on a port, or an AI
    /// agent started it. A dev server an agent launched in `/tmp` counts.
    ///
    /// - Parameters:
    ///   - listens: the process holds a listening TCP port. Shown at once.
    ///   - startedByAgent: an agent is among its ancestors, or left its
    ///     marker in the environment.
    public func classify(
        _ details: ProcessDetails,
        now: Date = Date(),
        listens: Bool = false,
        startedByAgent: Bool = false
    ) -> DevClassification? {
        guard details.isInspectable,
              let classification = runtime(forExecutablePath: details.executablePath, name: details.entry.name)
        else { return nil }

        if listens || startedByAgent {
            // Still not from inside an app bundle or a tool's private folder.
            if let cwd = details.cwd, ignoredCwds.matches((cwd as NSString).standardizingPath) { return nil }
        } else {
            guard let cwd = details.cwd, isEligibleWorkingDirectory(cwd) else { return nil }
        }

        if !listens, now.timeIntervalSince(details.identity.startDate) < minimumAge { return nil }
        if !details.arguments.isEmpty, ignoredCommandLines.matches(details.arguments.joined(separator: " ")) {
            return nil
        }
        return classification
    }

    /// Inside the home folder, but not in `~/Library`, a hidden tool folder,
    /// or an app bundle.
    public func isEligibleWorkingDirectory(_ cwd: String) -> Bool {
        let path = (cwd as NSString).standardizingPath
        return isInsideHome(path) && !ignoredCwds.matches(path)
    }

    private func isInsideHome(_ path: String) -> Bool {
        path == homeDirectory || path.hasPrefix(homeDirectory + "/")
    }
}
