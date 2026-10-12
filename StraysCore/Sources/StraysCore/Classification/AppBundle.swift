import Foundation

/// Facts derived from an executable's location on disk.
public enum AppBundle {
    /// The name of the outermost `.app` the executable lives in, so that a
    /// helper such as `…/Visual Studio Code.app/…/Code Helper (Plugin).app/…`
    /// is reported as "Visual Studio Code".
    public static func name(forExecutablePath path: String) -> String? {
        for component in path.split(separator: "/") where component.hasSuffix(".app") {
            let name = component.dropLast(".app".count)
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    /// The path of the outermost `.app` bundle, for revealing in Finder.
    public static func path(forExecutablePath path: String) -> String? {
        var result = ""
        for component in path.split(separator: "/") {
            result += "/" + component
            if component.hasSuffix(".app") { return result }
        }
        return nil
    }
}
