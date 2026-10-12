import Foundation

/// The data-driven rules in `runtimes.json` that decide which processes
/// without a listening port still count as dev processes.
public struct RuntimeRules: Codable, Sendable, Equatable {
    public struct Runtime: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var displayName: String
        /// SF Symbol name.
        public var symbol: String?
        /// True for runtimes that run a script (`node server.js`), where the
        /// interesting name is the script and not the executable.
        public var isInterpreter: Bool?
        public var executableNames: [String]?
        public var executableNamePatterns: [String]?

        public init(
            id: String,
            displayName: String,
            symbol: String? = nil,
            isInterpreter: Bool? = nil,
            executableNames: [String]? = nil,
            executableNamePatterns: [String]? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.symbol = symbol
            self.isInterpreter = isInterpreter
            self.executableNames = executableNames
            self.executableNamePatterns = executableNamePatterns
        }
    }

    public struct Ignore: Codable, Sendable, Equatable {
        public var executableNames: [String]?
        public var cwdPatterns: [String]?
        public var commandLinePatterns: [String]?

        public init(executableNames: [String]? = nil, cwdPatterns: [String]? = nil, commandLinePatterns: [String]? = nil) {
            self.executableNames = executableNames
            self.cwdPatterns = cwdPatterns
            self.commandLinePatterns = commandLinePatterns
        }
    }

    public var version: Int
    /// Processes without a port are only shown once they have lived this
    /// long, so short-lived build steps do not flicker through the list.
    public var minimumAgeSeconds: Double?
    public var runtimes: [Runtime]
    public var devBinaryPathPatterns: [String]?
    public var devBinaryExcludedPathPatterns: [String]?
    public var ignore: Ignore?

    public init(
        version: Int = 1,
        minimumAgeSeconds: Double? = nil,
        runtimes: [Runtime],
        devBinaryPathPatterns: [String]? = nil,
        devBinaryExcludedPathPatterns: [String]? = nil,
        ignore: Ignore? = nil
    ) {
        self.version = version
        self.minimumAgeSeconds = minimumAgeSeconds
        self.runtimes = runtimes
        self.devBinaryPathPatterns = devBinaryPathPatterns
        self.devBinaryExcludedPathPatterns = devBinaryExcludedPathPatterns
        self.ignore = ignore
    }

    /// The rules shipped inside StraysCore.
    public static let bundled: RuntimeRules = {
        guard let url = Bundle.module.url(forResource: "runtimes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode(RuntimeRules.self, from: data)
        else {
            assertionFailure("runtimes.json is missing or malformed")
            return RuntimeRules(runtimes: [])
        }
        return rules
    }()

    public func runtime(withID id: String) -> Runtime? {
        runtimes.first { $0.id == id }
    }
}

/// A set of regular expressions compiled once and matched many times.
struct PatternSet: Sendable {
    private let expressions: [NSRegularExpression]

    /// Invalid patterns are skipped rather than failing the whole rule file.
    init(_ patterns: [String], homeDirectory: String) {
        expressions = patterns.compactMap { pattern in
            var expanded = pattern
            if expanded.hasPrefix("^~") {
                expanded = "^" + NSRegularExpression.escapedPattern(for: homeDirectory) + expanded.dropFirst(2)
            }
            return try? NSRegularExpression(pattern: expanded)
        }
    }

    var isEmpty: Bool { expressions.isEmpty }

    func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return expressions.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}
