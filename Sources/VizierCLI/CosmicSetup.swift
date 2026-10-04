import Foundation
import Glibc

/// COSMIC needs an evdev input helper. Keep its socket private to the user and leave
/// device permissions to the administrator; setup never runs sudo or grants input access.
enum CosmicSetup {
    static let unitName = "vizier-input.service"
    static let fix = "Install ydotool and ydotoold 1.0 or newer, allow your user to open /dev/uinput, then run vizier setup --autostart. See docs/linux.md#pop_os-cosmic."

    struct Result {
        var status: String
        var detail: String
    }

    static func unitText(daemon: String) -> String {
        // systemd expands specifiers and environment variables even inside quotes.
        let escaped = daemon.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "$", with: "$$")
        return """
        [Unit]
        Description=Private input helper for Vizier on COSMIC
        PartOf=graphical-session.target
        After=graphical-session.target

        [Service]
        ExecStart="\(escaped)" --socket-path=%t/vizier-input/socket --socket-perm=0600
        RuntimeDirectory=vizier-input
        RuntimeDirectoryMode=0700
        Restart=on-failure
        RestartSec=2

        [Install]
        WantedBy=graphical-session.target

        """
    }

    static func prepare(env: HelperEnvironment, directory: URL, autostart: Bool) async -> Result {
        if await YdotoolKeySender(env: env).probe().available {
            return Result(status: "ok", detail: "An existing ydotoold socket is available; its service and permissions were left unchanged.")
        }
        guard env.resolve("ydotool") != nil, let daemon = env.resolve("ydotoold") else {
            return Result(status: "warn", detail: "COSMIC automatic paste needs ydotool and ydotoold; clipboard-only remains available.")
        }
        guard !daemon.contains("\n"), !daemon.contains("\r") else {
            return Result(status: "warn", detail: "The ydotoold path cannot be used in a systemd unit.")
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let unit = directory.appending(path: unitName)
            if !fm.fileExists(atPath: unit.path) {
                try Data(unitText(daemon: daemon).utf8).write(to: unit, options: .withoutOverwriting)
            }
            let dropIn = directory.appending(path: "vizier.service.d")
            try fm.createDirectory(at: dropIn, withIntermediateDirectories: true)
            let dependency = dropIn.appending(path: "cosmic-input.conf")
            if !fm.fileExists(atPath: dependency.path) {
                try Data("[Unit]\nWants=vizier-input.service\nAfter=vizier-input.service\n".utf8).write(to: dependency, options: .withoutOverwriting)
            }
        } catch {
            return Result(status: "warn", detail: "Could not install the COSMIC input user unit; existing files were not replaced.")
        }
        guard autostart else {
            return Result(status: "warn", detail: "Installed the private input user unit. Run vizier setup --autostart to enable it.")
        }
        guard access("/dev/uinput", R_OK | W_OK) == 0 else {
            return Result(status: "warn", detail: "The input unit is installed, but this user cannot open /dev/uinput; no device permissions were changed.")
        }
        for argv in [["systemctl", "--user", "daemon-reload"], ["systemctl", "--user", "enable", "--now", unitName]] {
            guard let result = try? await ProcessRunner.run(argv, environment: env.variables, timeout: .seconds(20)), result.succeeded else {
                return Result(status: "warn", detail: "Could not start the input user unit; check systemctl --user status vizier-input.service.")
            }
        }
        // Type=simple starts before the socket exists. Check readiness without injecting keys.
        for _ in 0..<20 {
            if await YdotoolKeySender(env: env).probe().available {
                return Result(status: "ok", detail: "Private input service enabled; its socket accepts connections.")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Result(status: "warn", detail: "The input service started but no usable socket appeared. Check the ydotool version and service journal.")
    }
}
