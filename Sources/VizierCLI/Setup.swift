import Foundation
import Glibc
import VizierEngine

/// `vizier setup`: one pass that probes what this desktop can do, asks the portals for the consents
/// a take must never wait on (A17), writes the starter config, installs the systemd user unit and
/// prints the compositor binds. It prints what it found; nothing here is verified against a real
/// desktop until someone runs it on one.
public enum Setup {
    public struct Options: Sendable {
        /// Enable and start the user unit (`systemctl --user enable --now`).
        public var autostart = false
        /// Skip the portal consent dialogs.
        public var noPortal = false
        public init(autostart: Bool = false, noPortal: Bool = false) {
            self.autostart = autostart
            self.noPortal = noPortal
        }
    }

    public struct Environment: Sendable {
        public var variables: [String: String]
        public var configDirectory: URL
        public var dataDirectory: URL
        /// The binary the unit and the binds run; nil reads /proc/self/exe.
        public var executable: String?
        /// Where the unit goes; nil is `$XDG_CONFIG_HOME/systemd/user`.
        public var systemdUserDirectory: URL?
        public var desktop: DesktopSession?
        public var useSecretService = true
        public var distro: DistroFamily?
        /// Where a package installs its unit (`/usr/lib/systemd/user` and the like); nil uses the standard places.
        public var packagedUnitDirectories: [URL]?
        /// Where a package installs `.desktop` files: the `applications` folders of `XDG_DATA_DIRS`; nil reads them from the environment.
        public var systemApplicationDirectories: [URL]?

        public init(variables: [String: String], configDirectory: URL, dataDirectory: URL, executable: String? = nil,
                    systemdUserDirectory: URL? = nil, desktop: DesktopSession? = nil, useSecretService: Bool = true, distro: DistroFamily? = nil,
                    packagedUnitDirectories: [URL]? = nil, systemApplicationDirectories: [URL]? = nil) {
            self.packagedUnitDirectories = packagedUnitDirectories
            self.systemApplicationDirectories = systemApplicationDirectories
            self.variables = variables
            self.configDirectory = configDirectory
            self.dataDirectory = dataDirectory
            self.executable = executable
            self.systemdUserDirectory = systemdUserDirectory
            self.desktop = desktop
            self.useSecretService = useSecretService
            self.distro = distro
        }
    }

    public static let unitName = "vizier.service"
    /// The desktop-file id the GNOME and KDE portals identify Vizier by.
    public static let desktopEntryName = "net.praxient.vizier.desktop"

    /// The persistent binary under an AppImage (`$APPIMAGE`), which is not the transient mount path
    /// the running process sees; nil outside one.
    public static func appImagePath(_ variables: [String: String]) -> String? {
        guard let path = variables["APPIMAGE"], path.hasPrefix("/") else { return nil }
        return path
    }

    /// `$XDG_DATA_HOME/applications` (default `~/.local/share/applications`).
    public static func userApplicationsDirectory(_ variables: [String: String]) -> URL {
        let base: URL
        if let path = variables["XDG_DATA_HOME"], path.hasPrefix("/") { base = URL(filePath: path) }
        else { base = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share") }
        return base.appending(path: "applications")
    }

    /// The `applications` folders under `XDG_DATA_DIRS` (default `/usr/local/share:/usr/share`).
    public static func systemApplicationDirectories(_ variables: [String: String]) -> [URL] {
        let value = (variables["XDG_DATA_DIRS"] ?? "").isEmpty ? "/usr/local/share:/usr/share" : variables["XDG_DATA_DIRS"]!
        return value.split(separator: ":").filter { $0.hasPrefix("/") }.map { URL(filePath: String($0)).appending(path: "applications") }
    }

    /// Where the portal's desktop file is installed, the user's folder first; nil when it is nowhere.
    public static func installedDesktopEntry(variables: [String: String], systemDirectories: [URL]? = nil) -> URL? {
        let folders = [userApplicationsDirectory(variables)] + (systemDirectories ?? systemApplicationDirectories(variables))
        return folders.map { $0.appending(path: desktopEntryName) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The `.desktop` file for an AppImage: the same as `Resources/linux/net.praxient.vizier.desktop`
    /// with `Exec` naming the AppImage. Quoted per the Desktop Entry spec (`"`, `` ` ``, `$` and `\` escaped).
    public static func desktopEntryText(executable: String) -> String {
        var quoted = ""
        for character in executable {
            if "\"`$\\".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return """
        [Desktop Entry]
        Type=Application
        Name=Vizier
        Comment=Dictation daemon
        Exec="\(quoted)" daemon
        Icon=audio-input-microphone
        Terminal=false
        NoDisplay=true
        Categories=Utility;
        X-GNOME-Autostart-enabled=false

        """
    }

    /// Seconds systemd waits on a stop. The daemon's quiesce deadline is 5 s plus 1 s to flush replies.
    public static let timeoutStopSeconds = 15
    /// The variables `vizier setup --autostart` imports into the systemd user manager (when set):
    /// where the display, the session bus and the compositor are, which the desktop-facing helpers need.
    public static let importedEnvironment = [
        "WAYLAND_DISPLAY", "DISPLAY", "XAUTHORITY", "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "XDG_RUNTIME_DIR",
        "XDG_DATA_DIRS", "XDG_CONFIG_DIRS", "SWAYSOCK", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS",
    ]
    public static let enableCommand = "systemctl --user enable --now vizier.service"

    // MARK: Unit and binds

    public static func unitText(executable: String) -> String {
        let quoted = executable.contains(" ") ? "\"\(executable)\"" : executable
        return """
        [Unit]
        Description=Vizier dictation daemon
        Documentation=man:vizier(1)
        After=graphical-session.target
        PartOf=graphical-session.target

        [Service]
        Type=simple
        ExecStart=\(quoted) daemon
        Restart=on-failure
        RestartSec=2
        # The daemon finishes an active take's audio on SIGTERM (5 s deadline); stay above that.
        TimeoutStopSec=\(timeoutStopSeconds)

        [Install]
        WantedBy=graphical-session.target

        """
    }

    public struct Bind: Sendable, Equatable {
        public var desktop: String
        public var file: String
        public var lines: [String]
    }

    public static func binds(executable: String) -> [Bind] {
        let bin = executable.contains(" ") ? "\"\(executable)\"" : executable
        return [
            Bind(desktop: "sway", file: "~/.config/sway/config",
                 lines: ["bindsym Ctrl+Alt+space exec \(bin) toggle", "bindsym Ctrl+Alt+BackSpace exec \(bin) cancel"]),
            Bind(desktop: "hyprland", file: "~/.config/hypr/hyprland.conf",
                 lines: ["bind = CTRL ALT, space, exec, \(bin) toggle", "bind = CTRL ALT, BackSpace, exec, \(bin) cancel"]),
            Bind(desktop: "niri", file: "~/.config/niri/config.kdl (inside binds { })",
                 lines: ["Ctrl+Alt+Space { spawn \"\(executable)\" \"toggle\"; }", "Ctrl+Alt+BackSpace { spawn \"\(executable)\" \"cancel\"; }"]),
            Bind(desktop: "gnome", file: "Settings > Keyboard > Keyboard Shortcuts > Custom Shortcuts",
                 lines: ["Name: Vizier toggle   Command: \(bin) toggle   Shortcut: Ctrl+Alt+Space", "Name: Vizier cancel   Command: \(bin) cancel   Shortcut: Ctrl+Alt+Backspace"]),
            Bind(desktop: "kde", file: "System Settings > Keyboard > Shortcuts > Add Command",
                 lines: ["Command: \(bin) toggle   Shortcut: Ctrl+Alt+Space", "Command: \(bin) cancel   Shortcut: Ctrl+Alt+Backspace"]),
        ]
    }

    static func bindDesktops(for family: DesktopSession.Family) -> [String] {
        switch family {
        case .gnome: ["gnome"]
        case .kde: ["kde"]
        case .hyprland: ["hyprland"]
        case .wlroots: ["sway", "niri"]
        case .cosmic, .other: ["sway", "hyprland", "niri", "gnome", "kde"]
        }
    }

    // MARK: Run

    @MainActor
    public static func run(_ options: Options, environment env: Environment) async -> JSONValue {
        let desktop = env.desktop ?? DesktopSession.detect(environment: env.variables)
        let helpers = HelperEnvironment(variables: env.variables, distro: env.distro ?? DistroFamily.detect())
        // Under an AppImage the running binary lives on a transient mount: the unit, the desktop
        // entry and the binds must name the AppImage file itself.
        let appImage = Self.appImagePath(env.variables)
        let executable = appImage ?? env.executable ?? ((try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? "vizier")
        var checks: [JSONValue] = []
        var essentialFailures = 0
        func add(_ name: String, _ status: String, _ detail: String, _ fix: String = "", essential: Bool = false) {
            checks.append(.object(["name": .string(name), "status": .string(status), "detail": .string(detail), "fix": .string(status == "ok" ? "" : fix)]))
            if essential && status == "fail" { essentialFailures += 1 }
        }

        // Config first: it names the modes the later checks look at.
        let config = ConfigStore(directory: env.configDirectory)
        var configNote = "starter files present"
        do {
            let existed = FileManager.default.fileExists(atPath: config.settingsURL.path)
            try config.writeStarterFilesIfMissing()
            if !existed { configNote = "wrote the starter config" }
        } catch { configNote = "could not write the starter config: \(error)" }
        let loaded = config.load()

        // Desktop and capture.
        add("desktop", desktop.display == .none ? "fail" : "ok",
            "\(desktop.display.rawValue) session, \(desktop.family.rawValue) family (XDG_CURRENT_DESKTOP=\(desktop.currentDesktop.isEmpty ? "unset" : desktop.currentDesktop)).",
            "Run vizier setup from a terminal inside your desktop session (WAYLAND_DISPLAY or DISPLAY must be set).", essential: true)
        let recorder = LinuxRuntime.recorderCommand(environment: env.variables)
        let recorderPath = ProcessRunner.resolve(recorder[0], environment: env.variables)
        add("capture", recorderPath == nil ? "fail" : "ok",
            recorderPath.map { "\(recorder[0]) found at \($0). Which microphone it records is the system default; that is not checked here." } ?? "\(recorder[0]) is not installed.",
            helpers.distro.install(["pipewire-bin"], names: [.fedora: ["pipewire-utils"], .arch: ["pipewire"], .suse: ["pipewire-tools"]]), essential: true)

        // Paste route.
        var portalDetail: JSONValue = .null
        var plan = await DesktopRoutes.make(session: desktop, env: helpers, allowYdotool: env.variables["VIZIER_YDOTOOL"] == "1")
        let portalFamily = desktop.display != .none && [.gnome, .kde].contains(desktop.family)
        if portalFamily && !options.noPortal {
            let portal = PortalRemoteDesktop()
            do {
                try await portal.prepare()
                let probe = await portal.probe()
                portalDetail = .object(["remoteDesktop": .string(probe.detail), "granted": .bool(probe.available)])
                if probe.available { plan.writers.insert(portal, at: 0); plan.senders.insert(portal, at: 0) }
            } catch {
                portalDetail = .object(["remoteDesktop": .string("consent failed: \(error)"), "granted": .bool(false)])
            }
        }
        let writerNames = plan.writers.map(\.name), senderNames = plan.senders.map(\.name)
        if plan.writers.isEmpty {
            if desktop.display == .none {
                add("clipboard", "fail", "No graphical session was detected, so no clipboard tool applies.", "Run vizier setup from a terminal inside your desktop session.", essential: true)
            } else {
                let probes = await DesktopRoutes.probes(session: desktop, env: helpers)
                let detail = probes.map { "\($0.name): \($0.detail)" }.joined(separator: "; ")
                add("clipboard", "fail", detail.isEmpty ? "No clipboard tool for this desktop." : detail,
                    probes.compactMap(\.fix).first ?? "Install wl-clipboard (Wayland) or xclip (X11).", essential: true)
            }
        } else {
            add("clipboard", "ok", "Text will go to the clipboard with \(writerNames.joined(separator: ", ")).")
        }
        if plan.senders.isEmpty {
            // Clipboard-only still delivers: the take says the text is on the clipboard.
            let probes = await DesktopRoutes.probes(session: desktop, env: helpers)
            let sender = probes.filter { $0.name.contains("wtype") || $0.name.contains("xdotool") || $0.name.contains("ydotool") }
            add("paste", "warn", "No way to press the paste keys here, so a take leaves its text on the clipboard. " + sender.map { "\($0.name): \($0.detail)" }.joined(separator: "; "),
                sender.compactMap(\.fix).first ?? "Install wtype (Wayland) or xdotool (X11); on GNOME/KDE run vizier setup from a terminal in the session.")
        } else {
            add("paste", "ok", "Paste keys are sent with \(senderNames.joined(separator: ", ")). Unverified until a take lands in an app on this desktop.")
        }

        // Hotkey.
        var hotkeyRoute = "compositor-bind"
        if let source = LinuxRuntime.hotkeySource(for: desktop), !options.noPortal {
            do {
                try await source.start(onToggle: {}, onCancel: {})
                let probe = await source.probe()
                await source.stop()
                hotkeyRoute = probe.available ? "portal" : "compositor-bind"
                add("hotkey", probe.available ? "ok" : "warn", probe.available ? "Global shortcuts bound through the desktop portal (Ctrl+Alt+Space toggles, Ctrl+Alt+Backspace cancels). \(probe.detail)" : probe.detail,
                    "Bind vizier toggle and vizier cancel yourself (see binds).")
            } catch {
                add("hotkey", "warn", "The GlobalShortcuts portal did not bind: \(error)", "Bind vizier toggle and vizier cancel in your desktop's shortcut settings (see binds).")
            }
        } else if desktop.display != .none, [.gnome, .kde, .hyprland].contains(desktop.family), options.noPortal {
            add("hotkey", "warn", "Portal consent skipped (--no-portal).", "Run vizier setup without --no-portal, or bind vizier toggle yourself.")
        } else {
            add("hotkey", "warn", "This desktop has no global shortcut portal; bind \(executable) toggle and \(executable) cancel in the compositor (see binds).", "Add the lines under binds to your compositor's config.")
        }

        // Keys.
        let store = LinuxSecretStore(environment: env.variables, configDirectory: env.configDirectory, useSecretService: env.useSecretService)
        var keys: [JSONValue] = []
        for account in SecretAccount.allCases {
            let found = store.status(account.rawValue)
            keys.append(.object(["key": .string(account.rawValue), "resolvedFrom": found.resolvedFrom.map { .string($0.rawValue) } ?? .null, "errors": .array(found.errors.map(JSONValue.string))]))
        }
        let keyed = keys.filter { $0["resolvedFrom"] != .null }.compactMap { $0["key"]?.string }
        add("keys", "ok", keyed.isEmpty ? "No cloud keys set; the local mode needs none. Cloud modes: vizier key set gemini | elevenlabs." : "Keys set: \(keyed.joined(separator: ", ")).")

        // Local whisper (and local cleanup) for the modes that use them.
        let local = LocalServers.checks(loaded.config, environment: env.variables)
        for check in local { add(check.name, check.status == "fail" ? "warn" : check.status, check.detail, check.fix) }
        if local.isEmpty { add("local_whisper", "ok", "No mode uses a local server.") }

        // Feedback.
        let sounds = LinuxSounds(environment: env.variables)
        let soundNote = (sounds.player, sounds.directory?.path)
        add("sounds", soundNote.0 != nil && soundNote.1 != nil ? "ok" : "warn",
            soundNote.0.map { "\($0) plays the cues from \(soundNote.1 ?? "no sounds folder")." } ?? "No sound player (pw-play, paplay, aplay) is installed; cues stay silent.",
            helpers.distro.install(["pipewire-bin"]))
        let notifier = ProcessRunner.resolve("notify-send", environment: env.variables) != nil
        add("notifications", "ok", notifier ? "Notifications go over D-Bus; notify-send is the fallback." : "Notifications go over D-Bus; notify-send is not installed (only needed as a fallback).")

        // Autostart.
        var autostart: [String: JSONValue] = ["command": .string(enableCommand)]
        let unitDirectory = env.systemdUserDirectory ?? Self.systemdUserDirectory(env.variables)
        let unitURL = unitDirectory.appending(path: unitName)
        // A package (.deb, .rpm) already put the unit under /usr: setup then only checks it is there.
        let packagedDirectories = env.packagedUnitDirectories ?? ["/usr/lib/systemd/user", "/lib/systemd/user", "/etc/systemd/user"].map { URL(filePath: $0) }
        let packagedUnit = appImage == nil ? packagedDirectories.map { $0.appending(path: unitName) }.first { FileManager.default.fileExists(atPath: $0.path) } : nil
        if let packagedUnit {
            autostart["unit"] = .string(packagedUnit.path); autostart["installed"] = .bool(true); autostart["source"] = .string("package")
        } else {
            do {
                try FileManager.default.createDirectory(at: unitDirectory, withIntermediateDirectories: true)
                try Data(unitText(executable: executable).utf8).write(to: unitURL, options: .atomic)
                autostart["unit"] = .string(unitURL.path); autostart["installed"] = .bool(true); autostart["source"] = .string(appImage == nil ? "user" : "appimage")
            } catch {
                autostart["unit"] = .string(unitURL.path); autostart["installed"] = .bool(false); autostart["error"] = .string("\(error)")
            }
        }

        // The portal's app id: an AppImage installs its own desktop entry; a package has one under /usr.
        var desktopEntry: [String: JSONValue] = [:]
        if appImage != nil {
            let folder = Self.userApplicationsDirectory(env.variables)
            let url = folder.appending(path: Self.desktopEntryName)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(Self.desktopEntryText(executable: executable).utf8).write(to: url, options: .atomic)
                desktopEntry = ["path": .string(url.path), "installed": .bool(true), "source": .string("appimage")]
            } catch {
                desktopEntry = ["path": .string(url.path), "installed": .bool(false), "error": .string("\(error)")]
            }
        } else if let found = Self.installedDesktopEntry(variables: env.variables, systemDirectories: env.systemApplicationDirectories) {
            desktopEntry = ["path": .string(found.path), "installed": .bool(true), "source": .string("existing")]
        } else {
            desktopEntry = ["installed": .bool(false)]
        }
        if desktopEntry["installed"] == .bool(true) {
            add("desktop_entry", "ok", "\(desktopEntry["path"]?.string ?? "") (the GNOME and KDE portals need it to know Vizier).")
        } else {
            add("desktop_entry", "warn", "\(Self.desktopEntryName) is not installed; the GNOME and KDE portals identify Vizier by it.",
                "Install the package, or copy Resources/linux/\(Self.desktopEntryName) to ~/.local/share/applications/ with Exec set to this binary.")
        }
        autostart["enabled"] = .bool(false)
        if options.autostart {
            if autostart["installed"] == .bool(true) {
                var failure: String?
                var steps: [[String]] = [["systemctl", "--user", "daemon-reload"]]
                // The user manager does not have the terminal's variables (a login shell's, a
                // compositor's); the daemon needs the desktop ones. Only these names, only those
                // present here, are handed over: never the whole environment.
                let present = Self.importedEnvironment.filter { !(env.variables[$0] ?? "").isEmpty }
                if !present.isEmpty { steps.append(["systemctl", "--user", "import-environment"] + present) }
                steps.append(["systemctl", "--user", "enable", "--now", unitName])
                for argv in steps {
                    do {
                        let result = try await ProcessRunner.run(argv, environment: env.variables, timeout: .seconds(20), outputLimit: 8 * 1024)
                        // systemctl's own words can name paths and users: only the step and the status are reported.
                        if result.timedOut { failure = "\(argv.prefix(3).joined(separator: " ")) timed out"; break }
                        if !result.succeeded { failure = "\(argv.prefix(3).joined(separator: " ")) failed (exit status \(result.exitCode ?? -1))"; break }
                    } catch { failure = "\(argv.prefix(3).joined(separator: " ")) could not be run"; break }
                }
                autostart["enabled"] = .bool(failure == nil)
                if let failure { autostart["error"] = .string(failure) }
            }
        }

        let bindList = binds(executable: executable)
        let wanted = Set(bindDesktops(for: desktop.family))
        let relevant = bindList.filter { wanted.contains($0.desktop) }
        let bindJSON: [JSONValue] = relevant.map { .object(["desktop": .string($0.desktop), "file": .string($0.file), "lines": .array($0.lines.map(JSONValue.string))]) }

        return .object([
            "desktop": .object(["display": .string(desktop.display.rawValue), "family": .string(desktop.family.rawValue), "currentDesktop": .string(desktop.currentDesktop)]),
            "checks": .array(checks),
            "paste": .object(["clipboard": .array(writerNames.map(JSONValue.string)), "keys": .array(senderNames.map(JSONValue.string))]),
            "portal": portalDetail,
            "hotkey": .object(["route": .string(hotkeyRoute)]),
            "keys": .array(keys),
            "config": .object(["path": .string(config.settingsURL.path), "note": .string(configNote), "errors": .array(loaded.errors.map { .string($0.publicSummary) })]),
            "autostart": .object(autostart),
            "desktopEntry": .object(desktopEntry),
            "binds": .array(bindJSON),
            "healthy": .bool(essentialFailures == 0),
        ])
    }

    static func systemdUserDirectory(_ variables: [String: String]) -> URL {
        let base: URL
        if let path = variables["XDG_CONFIG_HOME"], path.hasPrefix("/") { base = URL(filePath: path) }
        else { base = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config") }
        return base.appending(path: "systemd/user")
    }

    /// The human text for a setup result.
    public static func describe(_ result: JSONValue) -> String {
        var lines: [String] = []
        if case .array(let checks) = result["checks"] {
            for check in checks {
                let status = check["status"]?.string ?? ""
                let mark = status == "ok" ? "ok  " : (status == "warn" ? "warn" : "FAIL")
                lines.append("[\(mark)] \(check["name"]?.string ?? ""): \(check["detail"]?.string ?? "")")
                if let fix = check["fix"]?.string, !fix.isEmpty { lines.append("       Fix: \(fix)") }
            }
        }
        if let config = result["config"], let path = config["path"]?.string { lines.append("Config: \(path) (\(config["note"]?.string ?? ""))") }
        if let unit = result["autostart"] {
            if unit["installed"]?.bool == true {
                lines.append("Autostart unit: \(unit["unit"]?.string ?? "")" + (unit["enabled"]?.bool == true ? " (enabled and started)" : ""))
                if unit["enabled"]?.bool != true { lines.append("  Enable it with: \(unit["command"]?.string ?? enableCommand)   (or rerun vizier setup --autostart)") }
            } else { lines.append("Autostart unit could not be written: \(unit["error"]?.string ?? "unknown error")") }
            if let error = unit["error"]?.string, unit["installed"]?.bool == true { lines.append("  Problem: \(error)") }
        }
        if case .array(let binds) = result["binds"], !binds.isEmpty {
            lines.append(result["hotkey"]?["route"]?.string == "portal" ? "Compositor binds (optional; the portal shortcut is active):" : "Bind these in your compositor, since there is no global shortcut here:")
            for bind in binds {
                lines.append("  \(bind["desktop"]?.string ?? "") (\(bind["file"]?.string ?? "")):")
                if case .array(let rows) = bind["lines"] { for row in rows { lines.append("    \(row.string ?? "")") } }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
