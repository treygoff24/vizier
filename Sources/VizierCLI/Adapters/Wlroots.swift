import Foundation

private func waylandMissing(_ name: String, env: HelperEnvironment) -> AdapterProbe? {
    guard let socket = env.variables["WAYLAND_DISPLAY"], !socket.isEmpty else {
        return AdapterProbe(name: name, available: false, detail: "WAYLAND_DISPLAY is not set, so there is no compositor to reach",
                            fix: "start the daemon from the graphical session (systemctl --user import-environment WAYLAND_DISPLAY)")
    }
    return nil
}

/// Wayland clipboard through wl-clipboard's `wl-copy`, which forks a server that holds the
/// selection. Works under any compositor that offers the wlr-data-control or ext-data-control
/// protocol (wlroots, Hyprland, COSMIC, niri); GNOME offers neither, so it is not chosen there.
public struct WlCopyClipboardWriter: ClipboardReadable {
    public let name = "wl-copy"
    private let env: HelperEnvironment
    private let session: DesktopSession

    public init(session: DesktopSession, env: HelperEnvironment = HelperEnvironment()) {
        self.session = session
        self.env = env
    }

    public func probe() async -> AdapterProbe {
        guard env.resolve("wl-copy") != nil else {
            return Helper.missing(name, tool: "wl-copy", env: env, packages: ["wl-clipboard"])
        }
        // wl-paste proves a publication by reading it back; wl-clipboard ships both.
        guard env.resolve("wl-paste") != nil else {
            return Helper.missing(name, tool: "wl-paste", env: env, packages: ["wl-clipboard"])
        }
        if let missing = waylandMissing(name, env: env) { return missing }
        if session.family == .gnome {
            return AdapterProbe(name: name, available: false,
                                detail: "GNOME's compositor has no data-control protocol, so wl-copy cannot publish without a focused window",
                                fix: "use the portal route on GNOME")
        }
        return AdapterProbe(name: name, available: true, detail: "wl-copy on \(env.variables["WAYLAND_DISPLAY"] ?? ""); the data-control protocol is not verified until the first paste")
    }

    public func publish(_ text: String) async throws {
        try await Helper.publish(["wl-copy"], text: text, environment: env.variables, readback: Self.readbackArgv)
    }

    static let readbackArgv = ["wl-paste", "--no-newline"]

    public func readBack(maxBytes: Int) async -> String? {
        await Helper.read(Self.readbackArgv, environment: env.variables, maxBytes: maxBytes)
    }
}

/// `wtype -M ctrl -k v -m ctrl`: the virtual-keyboard protocol. GNOME and KDE do not offer it
/// (wtype refuses there), so an installed wtype is not enough; the session has to be one that does.
public struct WtypeKeySender: KeySender {
    public let name = "wtype"
    private let env: HelperEnvironment
    private let session: DesktopSession

    public init(session: DesktopSession, env: HelperEnvironment = HelperEnvironment()) {
        self.session = session
        self.env = env
    }

    public func probe() async -> AdapterProbe {
        guard env.resolve("wtype") != nil else { return Helper.missing(name, tool: "wtype", env: env) }
        if let missing = waylandMissing(name, env: env) { return missing }
        switch session.family {
        case .gnome, .kde:
            return AdapterProbe(name: name, available: false,
                                detail: "\(session.family.rawValue.uppercased()) does not offer the virtual-keyboard protocol wtype needs",
                                fix: "use the portal route, or ydotool (opt in) on this desktop")
        default:
            return AdapterProbe(name: name, available: true, detail: "wtype on \(env.variables["WAYLAND_DISPLAY"] ?? ""); only the environment and the desktop family are checked, the virtual-keyboard protocol is not verified until the first paste")
        }
    }

    public func send(_ chord: PasteChord) async throws {
        let keys: [String]
        switch chord {
        case .ctrlV: keys = ["-M", "ctrl", "-k", "v", "-m", "ctrl"]
        case .ctrlShiftV: keys = ["-M", "ctrl", "-M", "shift", "-k", "v", "-m", "shift", "-m", "ctrl"]
        }
        try await Helper.send(["wtype"] + keys, environment: env.variables)
    }
}
