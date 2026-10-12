import Foundation

/// Turns a raw argument vector into the short name a developer would
/// recognise: `node /…/node_modules/.bin/next dev` becomes `next dev`.
public enum CommandSummary {
    private static let scriptExtensions: Set<String> = ["js", "mjs", "cjs", "ts", "py", "rb", "php"]
    private static let javaValueFlags: Set<String> = ["-cp", "-classpath", "--class-path", "-p", "--module-path"]
    private static let maximumWords = 6

    public static func title(arguments: [String], executableName: String, isInterpreter: Bool = false) -> String {
        guard let first = arguments.first, !first.isEmpty else { return executableName }
        let program = basename(first)

        let words: [String]
        if program == "java" || executableName == "java" {
            words = javaWords(arguments)
        } else if isInterpreter, let tool = toolInvocation(arguments) {
            words = tool
        } else {
            words = [program] + arguments.dropFirst().map(shorten)
        }

        let kept = words.filter { !$0.isEmpty }.prefix(maximumWords)
        let title = kept.joined(separator: " ")
        return title.isEmpty ? executableName : title
    }

    /// `node /…/node_modules/.bin/vite --port 3000` → `["vite", "--port", "3000"]`.
    /// Returns nil when the script is the developer's own file, where the
    /// interpreter is worth keeping (`node server.js`).
    private static func toolInvocation(_ arguments: [String]) -> [String]? {
        // The script is the first argument that is not an interpreter flag.
        guard let index = arguments.dropFirst().firstIndex(where: { !$0.hasPrefix("-") }) else { return nil }
        let script = arguments[index]
        guard script.contains("/node_modules/") || script.contains("/bin/") else { return nil }

        var name = basename(script)
        if let dot = name.lastIndex(of: "."), scriptExtensions.contains(String(name[name.index(after: dot)...])) {
            name = String(name[..<dot])
        }
        if name.hasSuffix("-cli"), name.count > 4 { name = String(name.dropLast(4)) }
        return [name] + arguments[(index + 1)...].map(shorten)
    }

    /// `java -Xmx2g -cp … org.gradle.launcher.GradleDaemon 8.5` → `["java", "GradleDaemon", "8.5"]`.
    private static func javaWords(_ arguments: [String]) -> [String] {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-jar", index + 1 < arguments.count {
                return ["java", "-jar", basename(arguments[index + 1])] + arguments[(index + 2)...].map(shorten)
            }
            if javaValueFlags.contains(argument) {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                let mainClass = argument.split(separator: ".").last.map(String.init) ?? argument
                return ["java", mainClass] + arguments[(index + 1)...].map(shorten)
            }
        }
        return ["java"]
    }

    /// Absolute paths are noise in a title; keep only the last component.
    private static func shorten(_ argument: String) -> String {
        guard argument.hasPrefix("/") else { return argument }
        return basename(argument)
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
