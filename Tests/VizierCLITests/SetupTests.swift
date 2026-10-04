import Foundation
import Glibc
import Testing
import VizierEngine
@testable import VizierCLI

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A loopback port held by a bound socket that is not listening yet: connecting to it is refused
/// until `listen` is called on `fd`, and no other test can take the port meanwhile. (Closing a
/// probe socket and binding the number again later raced the tests running beside it.)
private func reservedLoopbackPort() -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 } }
    precondition(fd >= 0 && named, "no loopback port could be reserved")
    return (fd, UInt16(bigEndian: address.sin_port))
}

private func tempRoot() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "vizier-setup-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite @MainActor struct SetupTests {
    private func environment(_ root: URL, bins: FakeBins, executable: String = "/opt/vizier bin/vizier") -> Setup.Environment {
        Setup.Environment(
            variables: bins.environment(["DISPLAY": ":99", "XDG_DATA_HOME": root.appending(path: "datahome").path]), configDirectory: root.appending(path: "config"), dataDirectory: root.appending(path: "data"),
            executable: executable, systemdUserDirectory: root.appending(path: "systemd/user"),
            desktop: DesktopSession(display: .x11, family: .other, currentDesktop: ""), useSecretService: false, distro: .debian,
            packagedUnitDirectories: [], systemApplicationDirectories: [])
    }

    @Test func reportsWhatWorksWritesTheConfigAndTheUnitButDoesNotEnableIt() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let bins = FakeBins()
        for name in ["pw-record", "paplay", "xdotool"] { bins.add(name, reads: false) }
        bins.addClipboardTool("xclip")
        bins.add("systemctl", reads: false)
        let result = await Setup.run(Setup.Options(), environment: environment(root, bins: bins))

        let found = checks(result)
        for name in ["desktop", "capture", "clipboard", "paste", "hotkey", "keys", "local_whisper", "sounds", "notifications"] {
            #expect(found[name] != nil, "missing check \(name)")
        }
        #expect(found["capture"]?["status"] == .string("ok") && found["clipboard"]?["status"] == .string("ok") && found["paste"]?["status"] == .string("ok"))
        #expect(found["hotkey"]?["status"] == .string("warn"))  // no portal on this desktop: the binds are the road
        #expect(result["healthy"] == .bool(true))
        #expect(result["desktop"]?["display"] == .string("x11"))
        #expect(result["paste"]?["clipboard"] == .array([.string("xclip")]) && result["paste"]?["keys"] == .array([.string("xdotool")]))
        // The starter config exists, 0600 in a 0700 folder.
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "config/vizier.jsonc").path))
        #expect(result["config"]?["path"] == .string(root.appending(path: "config/vizier.jsonc").path))
        // The unit is installed with the absolute, quoted path and a stop timeout above the daemon's 5 s quiesce.
        let unit = try String(contentsOf: root.appending(path: "systemd/user/vizier.service"), encoding: .utf8)
        #expect(unit.contains("ExecStart=\"/opt/vizier bin/vizier\" daemon") && unit.contains("Restart=on-failure"))
        let timeout = try #require(unit.split(separator: "\n").first { $0.hasPrefix("TimeoutStopSec=") }.flatMap { Int($0.dropFirst(15)) })
        #expect(timeout > 5)
        #expect(result["autostart"]?["installed"] == .bool(true) && result["autostart"]?["enabled"] == .bool(false))
        #expect(result["autostart"]?["command"] == .string("systemctl --user enable --now vizier.service"))
        #expect(bins.argv("systemctl").isEmpty, "without --autostart nothing is enabled")
        // Binds for an unknown desktop: every compositor, each running the toggle and the cancel.
        guard case .array(let binds) = result["binds"] else { Issue.record("no binds"); return }
        #expect(Set(binds.compactMap { $0["desktop"]?.string }) == ["sway", "hyprland", "niri", "gnome", "kde"])
        #expect(binds.allSatisfy { bind in
            guard case .array(let lines) = bind["lines"] else { return false }
            let text = lines.compactMap(\.string).joined(separator: "\n")
            return text.contains("toggle") && text.contains("cancel")
        })
        // The human text names the next step for what is not done.
        let text = Setup.describe(result)
        #expect(text.contains("systemctl --user enable --now vizier.service") && text.contains("[ok  ] capture"))
        // And the key (JSON) never carries a secret: none was set, so every key reads null.
        #expect(result["keys"] == .array([
            .object(["key": .string("elevenlabs"), "resolvedFrom": .null, "errors": .array([])]),
            .object(["key": .string("gemini"), "resolvedFrom": .null, "errors": .array([])]),
        ]))
    }

    @Test func autostartEnablesTheUnitAndAMissingRecorderIsNotHealthy() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let bins = FakeBins()
        bins.add("systemctl", reads: false)
        bins.addClipboardTool("xclip"); bins.add("xdotool", reads: false)
        let result = await Setup.run(Setup.Options(autostart: true), environment: environment(root, bins: bins, executable: "/usr/bin/vizier"))
        // Only the desktop variable that is set (DISPLAY, from the test environment) is handed to the manager.
        #expect(bins.argv("systemctl") == [["--user", "daemon-reload"], ["--user", "import-environment", "DISPLAY"], ["--user", "enable", "--now", "vizier.service"]])
        #expect(result["autostart"]?["enabled"] == .bool(true))
        #expect(checks(result)["capture"]?["status"] == .string("fail"))
        #expect(checks(result)["capture"]?["fix"]?.string?.contains("apt install") == true)
        #expect(result["healthy"] == .bool(false))
        // A failing systemctl is reported, not swallowed.
        bins.add("systemctl", body: "echo 'Failed to connect to bus' >&2; exit 1", reads: false)
        let failed = await Setup.run(Setup.Options(autostart: true), environment: environment(root, bins: bins))
        #expect(failed["autostart"]?["enabled"] == .bool(false) && failed["autostart"]?["error"]?.string?.contains("daemon-reload failed") == true)
        #expect(failed["autostart"]?["error"]?.string?.contains("Failed to connect to bus") == false, "systemctl's stderr must not reach the output")
    }

    @Test func autostartImportsOnlyTheNamedDesktopVariablesBeforeEnablingTheUnit() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let bins = FakeBins()
        // A user manager that starts without the terminal's environment: `import-environment NAME...`
        // copies those names from systemctl's own environment into it, and the unit can only start
        // once the display is known there.
        let manager = "\(bins.directory)/manager.env"
        bins.add("systemctl", body: """
        case "$2" in
        import-environment) shift 2; for n in "$@"; do eval "v=\\${$n}"; printf '%s=%s\\n' "$n" "$v" >> '\(manager)'; done;;
        enable) case "$(cat '\(manager)' 2>/dev/null)" in *WAYLAND_DISPLAY=*) ;; *) echo 'no display for the unit' >&2; exit 1;; esac;;
        esac
        exit 0
        """, reads: false)
        var env = environment(root, bins: bins)
        env.variables["WAYLAND_DISPLAY"] = "wayland-7"
        env.variables["XDG_CURRENT_DESKTOP"] = "sway"
        env.variables["AWS_SECRET_ACCESS_KEY"] = "must-not-be-imported"
        env.variables["XAUTHORITY"] = ""   // set but empty: not imported
        let result = await Setup.run(Setup.Options(autostart: true), environment: env)
        #expect(result["autostart"]?["enabled"] == .bool(true), "autostart: \(String(describing: result["autostart"]))")
        let calls = bins.argv("systemctl")
        #expect(calls.map { $0.dropFirst().first } == ["daemon-reload", "import-environment", "enable"])
        #expect(Array(calls[1].dropFirst(2)) == ["WAYLAND_DISPLAY", "DISPLAY", "XDG_CURRENT_DESKTOP"].sorted { Setup.importedEnvironment.firstIndex(of: $0)! < Setup.importedEnvironment.firstIndex(of: $1)! })
        let imported = (try? String(contentsOfFile: manager, encoding: .utf8)) ?? ""
        #expect(imported.contains("WAYLAND_DISPLAY=wayland-7") && imported.contains("DISPLAY=:99"))
        #expect(!imported.contains("must-not-be-imported") && !imported.contains("PATH="))
    }

    @Test func underAnAppImageSetupInstallsTheDesktopEntryAndTheUnitNameThePersistentPathNotTheMount() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let bins = FakeBins()
        bins.add("systemctl", reads: false)
        var env = environment(root, bins: bins, executable: "/tmp/.mount_ViziersXyZ/usr/bin/vizier")   // what /proc/self/exe shows
        env.variables["APPIMAGE"] = "/home/me/Apps/Vizier x86_64.AppImage"
        let result = await Setup.run(Setup.Options(autostart: true), environment: env)

        let unit = try String(contentsOf: root.appending(path: "systemd/user/vizier.service"), encoding: .utf8)
        #expect(unit.contains("ExecStart=\"/home/me/Apps/Vizier x86_64.AppImage\" daemon"), "unit: \(unit)")
        #expect(!unit.contains(".mount_"))
        let entry = root.appending(path: "datahome/applications/net.praxient.vizier.desktop")
        let text = try String(contentsOf: entry, encoding: .utf8)
        #expect(text.contains("Exec=\"/home/me/Apps/Vizier x86_64.AppImage\" daemon") && text.contains("NoDisplay=true"))
        #expect(!text.contains(".mount_"))
        #expect(result["desktopEntry"]?["installed"] == .bool(true) && result["desktopEntry"]?["source"] == .string("appimage"))
        #expect(checks(result)["desktop_entry"]?["status"] == .string("ok"))
        #expect(result["autostart"]?["source"] == .string("appimage"))
        // The compositor binds name it too.
        #expect(Setup.describe(result).contains("Vizier x86_64.AppImage") || Setup.binds(executable: "/home/me/Apps/Vizier x86_64.AppImage").first?.lines.first?.contains("Vizier x86_64.AppImage") == true)
    }

    @Test func aPackageInstallIsOnlyCheckedNotRewritten() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let bins = FakeBins()
        bins.add("systemctl", reads: false)
        // What a .deb leaves under /usr: the unit and the portal's desktop file.
        let packagedUnits = root.appending(path: "usr/lib/systemd/user"), applications = root.appending(path: "usr/share/applications")
        try FileManager.default.createDirectory(at: packagedUnits, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try Data("[Service]\nExecStart=/usr/bin/vizier daemon\n".utf8).write(to: packagedUnits.appending(path: "vizier.service"))
        try Data("[Desktop Entry]\nExec=vizier daemon\n".utf8).write(to: applications.appending(path: "net.praxient.vizier.desktop"))
        var env = environment(root, bins: bins, executable: "/usr/bin/vizier")
        env.packagedUnitDirectories = [packagedUnits]
        env.systemApplicationDirectories = [applications]
        let result = await Setup.run(Setup.Options(), environment: env)
        #expect(result["autostart"]?["source"] == .string("package"))
        #expect(result["autostart"]?["unit"] == .string(packagedUnits.appending(path: "vizier.service").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "systemd/user/vizier.service").path), "setup wrote a second unit next to the packaged one")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "datahome/applications/net.praxient.vizier.desktop").path))
        #expect(result["desktopEntry"]?["source"] == .string("existing") && checks(result)["desktop_entry"]?["status"] == .string("ok"))
        // Without the desktop file the check says so and points at the fix.
        env.systemApplicationDirectories = []
        let missing = await Setup.run(Setup.Options(), environment: env)
        #expect(checks(missing)["desktop_entry"]?["status"] == .string("warn") && checks(missing)["desktop_entry"]?["fix"]?.string?.isEmpty == false)
    }

    @Test func doctorReportsWhetherThePortalsDesktopEntryIsInstalled() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ConfigStore(directory: root.appending(path: "config"))
        try config.writeStarterFilesIfMissing()
        let share = root.appending(path: "share")
        let variables = ["PATH": "/nonexistent", "XDG_DATA_HOME": root.appending(path: "home-share").path, "XDG_DATA_DIRS": share.path]
        func entryCheck() -> JSONValue? {
            let result = Doctor.report(config: config, historyURL: root.appending(path: "history.sqlite"), takesRoot: root.appending(path: "Takes"), environment: variables, probeSocket: false)
            guard case .array(let all)? = result["checks"] else { return nil }
            return all.first { $0["name"]?.string == "desktop_entry" }
        }
        let missing = try #require(entryCheck())
        #expect(missing["status"] == .string("warn") && missing["fix"] == .string("vizier setup"))
        // A system-wide install (an XDG_DATA_DIRS folder) satisfies it...
        try FileManager.default.createDirectory(at: share.appending(path: "applications"), withIntermediateDirectories: true)
        try Data().write(to: share.appending(path: "applications/net.praxient.vizier.desktop"))
        #expect(entryCheck()?["status"] == .string("ok"))
        // ...and so does a per-user one.
        try FileManager.default.removeItem(at: share.appending(path: "applications/net.praxient.vizier.desktop"))
        #expect(entryCheck()?["status"] == .string("warn"))
        let user = root.appending(path: "home-share/applications")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data().write(to: user.appending(path: "net.praxient.vizier.desktop"))
        #expect(entryCheck()?["status"] == .string("ok"))
    }

    @Test func localWhisperIsCheckedOnLoopbackWithAFixThatNamesTheServerAndTheModel() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let bins = FakeBins()
        let (listener, port) = reservedLoopbackPort(); defer { Glibc.close(listener) }
        let env = environment(root, bins: bins)
        try FileManager.default.createDirectory(at: env.configDirectory, withIntermediateDirectories: true)
        let url = "http://127.0.0.1:\(port)/v1/audio/transcriptions"
        try Data("""
        { "mode": "local", "modes": [ { "id": "local", "name": "Local",
          "transcriber": { "engine": "local-whisper", "model": "large-v3-turbo", "mode": "verbatim", "languages": ["en"], "final_timeout_ms": 4000, "url": "\(url)" } } ] }
        """.utf8).write(to: env.configDirectory.appending(path: "vizier.jsonc"))
        let down = Doctor.report(config: ConfigStore(directory: env.configDirectory), historyURL: root.appending(path: "h.sqlite"), takesRoot: root.appending(path: "t"), environment: env.variables)
        let whisper = try #require(checks(down)["local_whisper"])
        #expect(whisper["status"] == .string("fail"))  // the active mode's own engine is down
        let fix = try #require(whisper["fix"]?.string)
        #expect(fix.contains("whisper-server") && fix.contains("ggml-large-v3-turbo.bin") && fix.contains("--port \(port)") && fix.contains("huggingface.co/ggerganov/whisper.cpp"))
        #expect(down["healthy"] == .bool(false))
        // Setup reports the same server, but as a warning: it only reports what to start.
        let setup = await Setup.run(Setup.Options(), environment: env)
        #expect(checks(setup)["local_whisper"]?["status"] == .string("warn"))
        // Once something answers on that port the check passes.
        #expect(listen(listener, 4) == 0)
        let up = Doctor.report(config: ConfigStore(directory: env.configDirectory), historyURL: root.appending(path: "h.sqlite"), takesRoot: root.appending(path: "t"), environment: env.variables)
        #expect(checks(up)["local_whisper"]?["status"] == .string("ok"))
    }

    @Test func aCleanupServerIsCheckedOnlyForModesThatUseIt() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(directory: root)
        try Data("""
        { "mode": "polish", "modes": [
          { "id": "local", "name": "Local", "transcriber": { "engine": "local-whisper", "model": "large-v3-turbo", "mode": "verbatim", "languages": ["en"], "final_timeout_ms": 4000 } },
          { "id": "polish", "name": "Polish", "transcriber": { "engine": "local-whisper", "model": "base", "mode": "verbatim", "languages": ["en"], "final_timeout_ms": 4000, "url": "http://127.0.0.1:9/x" },
            "cleanup": { "engine": "local-cleanup", "model": "tidy", "timeout_ms": 5000 } } ] }
        """.utf8).write(to: store.settingsURL)
        let loaded = store.load()
        #expect(loaded.errors.isEmpty, "\(loaded.errors)")
        let config = loaded.config
        let checks: [LocalServers.Check] = LocalServers.checks(config, environment: ["PATH": "/nonexistent"], answers: { _ in false })
        #expect(checks.map(\.name).sorted() == ["local_cleanup", "local_whisper", "local_whisper"])
        #expect(checks.allSatisfy { $0.status == "fail" || $0.status == "warn" })
        let cleanup = try #require(checks.first { $0.name == "local_cleanup" })
        #expect(cleanup.status == "fail" && cleanup.fix.contains("8747"))
        // The inactive mode's default whisper server is a warning, the active mode's is a failure.
        #expect(checks.filter { $0.name == "local_whisper" }.map(\.status).sorted() == ["fail", "warn"])
        let none = LocalServers.checks(VizierConfig(), environment: [:], answers: { _ in false })
        #expect(none.allSatisfy { $0.name == "local_whisper" })
        // A non-loopback URL is refused outright.
        #expect(LocalServers.answers(URL(string: "http://example.com:80/")!) == false)
    }

    @Test func thePackagedUnitAndDesktopFileMatchWhatSetupWrites() throws {
        let template = try String(contentsOf: repoRoot.appending(path: "Resources/linux/vizier.service"), encoding: .utf8)
        #expect(template.replacingOccurrences(of: "@VIZIER_BIN@", with: "/usr/bin/vizier") == Setup.unitText(executable: "/usr/bin/vizier"))
        let desktop = try String(contentsOf: repoRoot.appending(path: "Resources/linux/net.praxient.vizier.desktop"), encoding: .utf8)
        #expect(desktop.contains("NoDisplay=true") && desktop.contains("Exec=vizier daemon"))
        #expect(FileManager.default.fileExists(atPath: repoRoot.appending(path: "Resources/linux/README.md").path))
    }

    @Test func setupAndKeyParseWithTheirFlagsOnly() throws {
        #expect(try Invocation.parse(["setup", "--autostart", "--json"]).args["autostart"] == .bool(true))
        #expect(try Invocation.parse(["setup", "--no-portal"]).args["noPortal"] == .bool(true))
        #expect(throws: CLIError.self) { try Invocation.parse(["setup", "--bogus"]) }
    }

    @Test func doctorAcceptsParecWhenPwRecordIsMissingAndNamesTheFixWhenNeitherIsThere() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(directory: root.appending(path: "config")); try store.writeStarterFilesIfMissing()
        func capture(_ bins: FakeBins) -> JSONValue? {
            let report = Doctor.report(config: store, historyURL: root.appending(path: "h.sqlite"), takesRoot: root.appending(path: "t"), environment: bins.environment(), probeSocket: false)
            return checks(report)["pw_record"]
        }
        let parec = FakeBins(); parec.add("parec", reads: false)
        #expect(capture(parec)?["status"] == .string("ok") && capture(parec)?["detail"]?.string?.contains("parec") == true)
        let pw = FakeBins(); pw.add("pw-record", reads: false)
        #expect(capture(pw)?["status"] == .string("ok"))
        let none = capture(FakeBins())
        #expect(none?["status"] == .string("fail") && none?["fix"]?.string?.contains("pipewire") == true)
    }

    private func checks(_ result: JSONValue) -> [String: JSONValue] {
        guard case .array(let rows) = result["checks"] else { return [:] }
        return Dictionary(rows.compactMap { row in row["name"]?.string.map { ($0, row) } }, uniquingKeysWith: { $1 })
    }
}
