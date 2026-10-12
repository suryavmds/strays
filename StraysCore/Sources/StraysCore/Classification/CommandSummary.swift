import Foundation

/// Turns a raw argument vector into the short name a developer would
/// recognise: `node /…/node_modules/.bin/next dev` becomes `next dev`.
public enum CommandSummary {
    private static let scriptExtensions: Set<String> = ["js", "mjs", "cjs", "ts", "py", "rb", "php"]
    private static let javaValueFlags: Set<String> = ["-cp", "-classpath", "--class-path", "-p", "--module-path"]
    /// Interpreter flags whose value is the thing being run.
    private static let moduleFlags: Set<String> = ["-m"]
    private static let inlineCodeFlags: Set<String> = ["-c", "-e", "--eval", "-p", "--print"]
    private static let maximumWords = 6
    private static let maximumLength = 64

    public static func title(arguments: [String], executableName: String, isInterpreter: Bool = false) -> String {
        guard let first = arguments.first, !first.isEmpty else { return executableName }
        let program = basename(first)

        let words: [String]
        if program == "java" || executableName == "java" {
            words = javaWords(arguments)
        } else if isInterpreter {
            words = interpreterWords(program: program, arguments: arguments)
        } else {
            words = [program] + arguments.dropFirst().map(shorten)
        }

        let title = words.filter { !$0.isEmpty }.prefix(maximumWords).joined(separator: " ")
        if title.isEmpty { return executableName }
        return title.count > maximumLength ? String(title.prefix(maximumLength - 1)) + "…" : title
    }

    /// Names an interpreter invocation by what it runs, not how:
    ///
    /// - `node /…/node_modules/.bin/vite --port 3000` → `vite --port 3000`
    /// - `node --env-file=.env server.js` → `node server.js`
    /// - `python3 -m http.server 8000` → `python3 -m http.server 8000`
    private static func interpreterWords(program: String, arguments: [String]) -> [String] {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if moduleFlags.contains(argument), index + 1 < arguments.count {
                return [program, argument] + arguments[(index + 1)...].map(shorten)
            }
            if inlineCodeFlags.contains(argument) {
                return [program, argument, "…"]
            }
            if !argument.hasPrefix("-") {
                let rest = arguments[(index + 1)...].map(shorten)
                if let tool = toolName(forScript: argument) { return [tool] + rest }
                return [program, basename(argument)] + rest
            }
            // Any other flag configures the interpreter; it is not the name.
            index += 1
        }
        return [program]
    }

    /// The tool a script path stands for, when the script is an installed
    /// command rather than the developer's own file.
    private static func toolName(forScript script: String) -> String? {
        guard script.contains("/node_modules/") || script.contains("/bin/") else { return nil }
        var name = basename(script)
        if let dot = name.lastIndex(of: "."), scriptExtensions.contains(String(name[name.index(after: dot)...])) {
            name = String(name[..<dot])
        }
        if name.hasSuffix("-cli"), name.count > 4 { name = String(name.dropLast(4)) }
        return name
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
