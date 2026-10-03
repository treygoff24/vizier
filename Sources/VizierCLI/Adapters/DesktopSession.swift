import Foundation

extension DesktopSession {
    /// Reads the session from the environment the daemon was started with.
    ///
    /// Wayland wins over X11 when both are present (a Wayland session also sets DISPLAY for
    /// XWayland, and its keys must be injected on the Wayland side). `XDG_SESSION_TYPE` decides
    /// when it says so; otherwise WAYLAND_DISPLAY, then DISPLAY.
    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> DesktopSession {
        func value(_ key: String) -> String { environment[key]?.trimmingCharacters(in: .whitespaces) ?? "" }
        let sessionType = value("XDG_SESSION_TYPE").lowercased()
        let hasWayland = !value("WAYLAND_DISPLAY").isEmpty
        let hasX11 = !value("DISPLAY").isEmpty
        let display: Display
        switch sessionType {
        case "wayland": display = .wayland
        case "x11": display = hasX11 ? .x11 : (hasWayland ? .wayland : .none)
        default: display = hasWayland ? .wayland : (hasX11 ? .x11 : .none)
        }
        let current = value("XDG_CURRENT_DESKTOP")
        return DesktopSession(display: display, family: family(of: current, environment: environment), currentDesktop: current)
    }

    /// `XDG_CURRENT_DESKTOP` is a colon list ("ubuntu:GNOME"); the first entry that names a family decides.
    static func family(of currentDesktop: String, environment: [String: String]) -> Family {
        for entry in currentDesktop.split(separator: ":").map({ $0.lowercased() }) {
            switch entry {
            case "gnome", "gnome-classic", "gnome-flashback", "unity", "pantheon": return .gnome
            case "kde", "plasma": return .kde
            case "hyprland": return .hyprland
            case "cosmic": return .cosmic
            case "sway", "river", "wlroots", "niri", "labwc", "wayfire", "dwl", "mango", "miracle-wm", "scroll": return .wlroots
            default: continue
            }
        }
        // No desktop name: a compositor's own socket still says which one it is.
        if let _ = environment["HYPRLAND_INSTANCE_SIGNATURE"] { return .hyprland }
        if let _ = environment["SWAYSOCK"] { return .wlroots }
        if let _ = environment["NIRI_SOCKET"] { return .wlroots }
        return .other
    }

    var hasWayland: Bool { display == .wayland }
    var hasX11: Bool { display == .x11 }
}

/// The distro family, for the install command in a probe's `fix`.
public enum DistroFamily: String, Sendable, Equatable {
    case debian, fedora, arch, suse, other

    /// From the text of /etc/os-release (ID and ID_LIKE).
    public static func parse(osRelease: String) -> DistroFamily {
        var tokens: [String] = []
        for line in osRelease.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "ID" || parts[0] == "ID_LIKE" else { continue }
            tokens += parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased().split(separator: " ").map(String.init)
        }
        for token in tokens {
            switch token {
            case "debian", "ubuntu", "linuxmint", "pop", "raspbian": return .debian
            case "fedora", "rhel", "centos", "rocky", "almalinux": return .fedora
            case "arch", "manjaro", "endeavouros": return .arch
            case "suse", "opensuse", "opensuse-leap", "opensuse-tumbleweed", "sles": return .suse
            default: continue
            }
        }
        return .other
    }

    public static func detect(osReleasePath: String = "/etc/os-release") -> DistroFamily {
        parse(osRelease: (try? String(contentsOfFile: osReleasePath, encoding: .utf8)) ?? "")
    }

    /// The command that installs `packages` (package names are the Debian ones; `names` maps the
    /// ones that differ elsewhere).
    public func install(_ packages: [String], names: [DistroFamily: [String]] = [:]) -> String {
        let list = (names[self] ?? packages).joined(separator: " ")
        switch self {
        case .debian: return "sudo apt install \(list)"
        case .fedora: return "sudo dnf install \(list)"
        case .arch: return "sudo pacman -S \(list)"
        case .suse: return "sudo zypper install \(list)"
        case .other: return "install \(list) with your package manager"
        }
    }
}

extension DistroFamily: Hashable {}

/// What an adapter needs to decide whether it can work here: the environment the helper would
/// run in and the distro family for fix hints. Tests give both.
public struct HelperEnvironment: Sendable {
    public var variables: [String: String]
    public var distro: DistroFamily

    public init(variables: [String: String] = ProcessInfo.processInfo.environment, distro: DistroFamily = DistroFamily.detect()) {
        self.variables = variables
        self.distro = distro
    }

    public func resolve(_ name: String) -> String? { ProcessRunner.resolve(name, environment: variables) }
}
