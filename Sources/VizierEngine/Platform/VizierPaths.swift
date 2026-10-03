import Foundation

/// Where Vizier keeps its files. The one place that knows the per-OS layout.
/// macOS values are the ones the app has always used; Linux follows the XDG base directories.
public enum VizierPaths {
    /// Settings, vocabulary and replacements: `~/.config/vizier` (Linux: `$XDG_CONFIG_HOME/vizier`).
    public static var config: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/vizier")
        #else
        return xdgConfig(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
        #endif
    }

    /// History and takes: `~/Library/Application Support/Vizier` (Linux: `$XDG_DATA_HOME/vizier`).
    public static var data: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Vizier")
        #else
        return xdgData(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
        #endif
    }

    /// The daemon's socket folder, `$XDG_RUNTIME_DIR/vizier`. Nil on macOS, and on Linux when the
    /// session has no runtime directory.
    public static var runtime: URL? {
        #if os(macOS)
        return nil
        #else
        return xdgRuntime(environment: ProcessInfo.processInfo.environment)
        #endif
    }

    // The XDG rules, taking the environment as a parameter so tests can run them on any OS. Per the
    // XDG spec, an unset or relative value is ignored.

    static func xdgConfig(environment: [String: String], home: URL) -> URL {
        base(environment["XDG_CONFIG_HOME"], fallback: home.appending(path: ".config")).appending(path: "vizier")
    }

    static func xdgData(environment: [String: String], home: URL) -> URL {
        base(environment["XDG_DATA_HOME"], fallback: home.appending(path: ".local/share")).appending(path: "vizier")
    }

    static func xdgRuntime(environment: [String: String]) -> URL? {
        guard let value = environment["XDG_RUNTIME_DIR"], value.hasPrefix("/") else { return nil }
        return URL(filePath: value, directoryHint: .isDirectory).appending(path: "vizier")
    }

    private static func base(_ value: String?, fallback: URL) -> URL {
        guard let value, value.hasPrefix("/") else { return fallback }
        return URL(filePath: value, directoryHint: .isDirectory)
    }
}
