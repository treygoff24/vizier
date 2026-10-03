import Foundation

/// Terminal emulators, by app id (Wayland) or process name (X11 and /proc/<pid>/comm).
public enum TerminalList {
    public static let names: [String] = [
        "foot", "footclient", "kitty", "alacritty", "wezterm", "wezterm-gui", "gnome-terminal-server", "gnome-terminal",
        "org.gnome.terminal", "konsole", "xterm", "ptyxis", "ghostty", "tilix", "terminator", "xfce4-terminal",
        "urxvt", "rxvt", "st", "st-256color", "cosmic-term", "lxterminal", "kgx", "sakura",
    ]

    /// True when `identifier` names a terminal. Case-insensitive; a reverse-DNS app id
    /// ("org.wezfurlong.wezterm", "com.mitchellh.ghostty") matches on its last component; a
    /// /proc comm, which the kernel cuts to 15 characters ("gnome-terminal-"), matches a name
    /// cut the same way.
    public static func isTerminal(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        guard !id.isEmpty else { return false }
        let last = id.split(separator: ".").last.map(String.init) ?? id
        for name in names {
            if id == name || last == name { return true }
            if name.count > 15, id.count == 15, name.hasPrefix(id) { return true }
        }
        return false
    }
}

/// X11: `xdotool getactivewindow getwindowpid`, then /proc/<pid>/comm for the app's name. The
/// window title is not read (it can hold private text and is not needed). Needs a window manager
/// that keeps `_NET_ACTIVE_WINDOW`; without one the focus is unknown (nil).
public struct X11FocusReader: FocusReader {
    private let env: HelperEnvironment
    private let procRoot: String

    public init(env: HelperEnvironment = HelperEnvironment(), procRoot: String = "/proc") {
        self.env = env
        self.procRoot = procRoot
    }

    public func focusedWindow() async -> FocusedWindow? {
        guard let result = try? await ProcessRunner.run(["xdotool", "getactivewindow", "getwindowpid"], environment: env.variables, timeout: .seconds(2), outputLimit: 1024),
              result.succeeded,
              let pid = Int32(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }
        let comm = (try? String(contentsOfFile: "\(procRoot)/\(pid)/comm", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FocusedWindow(appName: comm, pid: pid, isTerminal: comm.isEmpty ? nil : TerminalList.isTerminal(comm))
    }
}

/// Hyprland: `hyprctl activewindow -j` (class and pid). Prints `{}` or nothing with no window.
///
/// Privacy: the JSON includes the window title, which can hold private text. It is parsed in
/// memory for `class` and `pid` only; the raw output and the title are never logged, stored or
/// returned (the same holds for the sway tree below).
public struct HyprlandFocusReader: FocusReader {
    private let env: HelperEnvironment
    public init(env: HelperEnvironment = HelperEnvironment()) { self.env = env }

    public func focusedWindow() async -> FocusedWindow? {
        guard let result = try? await ProcessRunner.run(["hyprctl", "activewindow", "-j"], environment: env.variables, timeout: .seconds(2), outputLimit: 1 << 16),
              result.succeeded else { return nil }
        return Self.parse(result.stdout)
    }

    static func parse(_ data: Data) -> FocusedWindow? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let app = (object["class"] as? String) ?? ""
        let pid = (object["pid"] as? NSNumber).map { Int32(truncating: $0) }
        guard !app.isEmpty || pid != nil else { return nil }
        return FocusedWindow(appName: app, pid: pid, isTerminal: app.isEmpty ? nil : TerminalList.isTerminal(app))
    }
}

/// sway: `swaymsg -t get_tree`, the node with `"focused": true` (app_id, or the X11 class under XWayland, and pid).
public struct SwayFocusReader: FocusReader {
    private let env: HelperEnvironment
    public init(env: HelperEnvironment = HelperEnvironment()) { self.env = env }

    public func focusedWindow() async -> FocusedWindow? {
        guard let result = try? await ProcessRunner.run(["swaymsg", "-t", "get_tree"], environment: env.variables, timeout: .seconds(2), outputLimit: 4 << 20),
              result.succeeded else { return nil }
        return Self.parse(result.stdout)
    }

    static func parse(_ data: Data) -> FocusedWindow? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func find(_ node: Any) -> [String: Any]? {
            guard let object = node as? [String: Any] else { return nil }
            if (object["focused"] as? Bool) == true { return object }
            for key in ["nodes", "floating_nodes"] {
                for child in (object[key] as? [Any]) ?? [] { if let hit = find(child) { return hit } }
            }
            return nil
        }
        guard let node = find(root) else { return nil }
        // A focused workspace or output with no window on it has no pid.
        guard let pid = (node["pid"] as? NSNumber).map({ Int32(truncating: $0) }) else { return nil }
        let properties = node["window_properties"] as? [String: Any]
        let app = (node["app_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (properties?["class"] as? String) ?? ""
        return FocusedWindow(appName: app, pid: pid, isTerminal: app.isEmpty ? nil : TerminalList.isTerminal(app))
    }
}

/// GNOME and KDE keep the focused window from other clients: unknown.
public struct UnknownFocusReader: FocusReader {
    public init() {}
    public func focusedWindow() async -> FocusedWindow? { nil }
}

public enum FocusReaders {
    public static func make(for session: DesktopSession, env: HelperEnvironment = HelperEnvironment()) -> FocusReader {
        switch (session.display, session.family) {
        case (.x11, _): return X11FocusReader(env: env)
        case (.wayland, .hyprland): return HyprlandFocusReader(env: env)
        case (.wayland, .wlroots):
            return env.variables["SWAYSOCK"] != nil ? SwayFocusReader(env: env) : UnknownFocusReader()
        default: return UnknownFocusReader()
        }
    }
}
