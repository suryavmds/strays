import Foundation

/// Hides credentials before anything reaches the screen or the clipboard.
public enum SecretMasker {
    public static let mask = "••••••••"

    /// A variable is treated as a secret when its name contains one of these.
    public static let sensitiveNameFragments = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "PRIVATE"]

    public static func isSensitive(name: String) -> Bool {
        let upper = name.uppercased()
        return sensitiveNameFragments.contains { upper.contains($0) }
    }

    /// The value to show for an environment variable.
    public static func display(name: String, value: String) -> String {
        if value.isEmpty { return value }
        return isSensitive(name: name) ? mask : maskURLCredentials(in: value)
    }

    /// True when `display` would hide something.
    public static func hidesSomething(name: String, value: String) -> Bool {
        display(name: name, value: value) != value
    }

    // scheme://user:password@host
    private static let urlCredentials = try! NSRegularExpression(pattern: #"([a-zA-Z][a-zA-Z0-9+.-]*://[^\s/:@]*):([^\s/@]+)@"#)

    /// `postgres://app:hunter2@db/x` → `postgres://app:••••••••@db/x`.
    public static func maskURLCredentials(in value: String) -> String {
        let range = NSRange(value.startIndex..., in: value)
        return urlCredentials.stringByReplacingMatches(in: value, range: range, withTemplate: "$1:\(mask)@")
    }

    /// Masks secrets passed on a command line: `--token=abc`, `--password abc`,
    /// `API_KEY=abc`, and credentials embedded in URLs.
    public static func maskArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var maskNext = false
        for argument in arguments {
            if maskNext {
                maskNext = false
                result.append(argument.hasPrefix("-") ? argument : mask)
                continue
            }
            if let separator = argument.firstIndex(of: "=") {
                let name = String(argument[..<separator])
                let value = String(argument[argument.index(after: separator)...])
                result.append(isSensitive(name: name) && !value.isEmpty ? "\(name)=\(mask)" : maskURLCredentials(in: argument))
            } else if argument.hasPrefix("-"), isSensitive(name: argument) {
                maskNext = true
                result.append(argument)
            } else {
                result.append(maskURLCredentials(in: argument))
            }
        }
        return result
    }
}
