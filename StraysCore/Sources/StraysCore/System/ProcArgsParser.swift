import Foundation

/// The decoded contents of a KERN_PROCARGS2 buffer.
struct ProcArgs: Equatable, Sendable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
}

/// Parses the KERN_PROCARGS2 layout:
///
///     int32 argc | exec path \0 | \0 padding | argv[0] \0 … argv[argc-1] \0 | env \0 … | \0 | apple strings
enum ProcArgsParser {
    static func parse(_ bytes: [UInt8]) -> ProcArgs? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc >= 0, argc < 1 << 20 else { return nil }

        var cursor = MemoryLayout<Int32>.size
        let executablePath = readString(bytes, &cursor)
        skipNULs(bytes, &cursor)

        var arguments: [String] = []
        arguments.reserveCapacity(argc)
        while arguments.count < argc, cursor < bytes.count {
            arguments.append(readString(bytes, &cursor))
        }

        // Node, via libuv, rewrites its argv area in place when a script sets
        // `process.title` (npm does): argv[0] becomes the whole title and the
        // rest of the area is zeroed. Recover the words, and step over the
        // zeroed tail so we still find the environment.
        if isRewrittenTitle(arguments) {
            arguments = arguments[0].split(separator: " ").map(String.init)
            skipNULs(bytes, &cursor)
        }

        var environment: [String: String] = [:]
        while cursor < bytes.count {
            let entry = readString(bytes, &cursor)
            if entry.isEmpty { break }
            guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else { continue }
            let key = String(entry[..<separator])
            if environment[key] == nil {
                environment[key] = String(entry[entry.index(after: separator)...])
            }
        }

        return ProcArgs(executablePath: executablePath, arguments: arguments, environment: environment)
    }

    private static func isRewrittenTitle(_ arguments: [String]) -> Bool {
        guard arguments.count > 1, let first = arguments.first, first.contains(" ") else { return false }
        return arguments.dropFirst().allSatisfy(\.isEmpty)
    }

    private static func readString(_ bytes: [UInt8], _ cursor: inout Int) -> String {
        let start = cursor
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        let value = String(decoding: bytes[start..<cursor], as: UTF8.self)
        if cursor < bytes.count { cursor += 1 }
        return value
    }

    private static func skipNULs(_ bytes: [UInt8], _ cursor: inout Int) {
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
    }
}
