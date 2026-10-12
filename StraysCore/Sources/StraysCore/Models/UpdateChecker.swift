import Foundation

/// A version such as `1.4.2` or `v2.0.0-beta.1`, ordered as semantic
/// versioning orders them.
public struct SemanticVersion: Comparable, Sendable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Empty for a normal release. A pre-release sorts before its release.
    public let prerelease: [String]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // Build metadata ("+abc") does not take part in ordering.
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }

        var prerelease: [String] = []
        if let dash = text.firstIndex(of: "-") {
            prerelease = text[text.index(after: dash)...].split(separator: ".").map(String.init)
            text = String(text[..<dash])
        }
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(numbers.count), !numbers.contains(nil), numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        major = numbers[0] ?? 0
        minor = numbers.count > 1 ? numbers[1] ?? 0 : 0
        patch = numbers.count > 2 ? numbers[2] ?? 0 : 0
        self.prerelease = prerelease
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // 1.0.0-beta < 1.0.0
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (a?, b?): return a < b
            case (_?, nil): return true // numeric identifiers sort first
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// A published release of Strays.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: SemanticVersion
    public let tag: String
    /// The release page, for the user to open. Strays never downloads or
    /// installs an update itself.
    public let pageURL: URL
    public let notes: String

    public init(version: SemanticVersion, tag: String, pageURL: URL, notes: String = "") {
        self.version = version
        self.tag = tag
        self.pageURL = pageURL
        self.notes = notes
    }
}

public enum UpdateCheckError: Error, Equatable {
    case malformedResponse
    case unexpectedStatus(Int)
}

/// Asks GitHub whether a newer release exists. It only ever reports; the
/// user decides whether to go and get it.
public struct UpdateChecker: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static let defaultRepository = "suryavmds/strays"

    public let repository: String
    private let fetch: Fetch

    public init(repository: String = UpdateChecker.defaultRepository, fetch: Fetch? = nil) {
        self.repository = repository
        self.fetch = fetch ?? Self.fetchFromGitHub
    }

    public var endpoint: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// GitHub's "latest release", which skips drafts and pre-releases.
    public func latestRelease() async throws -> ReleaseInfo {
        try Self.parse(try await fetch(endpoint))
    }

    /// The newer release, or nil when this one is current. Also nil when
    /// the check could not be made: being offline is not worth reporting.
    public func update(newerThan current: String) async -> ReleaseInfo? {
        guard let installed = SemanticVersion(current),
              let latest = try? await latestRelease(),
              latest.version > installed
        else { return nil }
        return latest
    }

    static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Payload: Decodable {
            let tagName: String
            let htmlURL: String
            let body: String?

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
                case body
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let version = SemanticVersion(payload.tagName),
              let url = URL(string: payload.htmlURL), url.scheme == "https"
        else { throw UpdateCheckError.malformedResponse }
        return ReleaseInfo(version: version, tag: payload.tagName, pageURL: url, notes: payload.body ?? "")
    }

    private static let fetchFromGitHub: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Sends nothing about this Mac: no identifier, no version, no cookies.
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw UpdateCheckError.unexpectedStatus(status)
        }
        return data
    }
}
