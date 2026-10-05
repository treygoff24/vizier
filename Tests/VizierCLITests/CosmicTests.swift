import Foundation
import Testing
import Glibc
@testable import VizierCLI

private struct CosmicTestFocus: FocusReader {
    let terminal: Bool?
    func focusedWindow() async -> FocusedWindow? {
        terminal.map { FocusedWindow(appName: "fixture", pid: nil, isTerminal: $0) }
    }
}

@Suite struct CosmicTests {
    @Test func cosmicAutomaticallyUsesPrivateYdotoolWithoutWtypeOrOptIn() async throws {
        let bins = FakeBins()
        bins.addClipboardTool("wl-copy"); bins.addClipboardReader()
        bins.add("ydotool", reads: false); bins.add("wtype", reads: false)
        try FileManager.default.createDirectory(atPath: bins.directory + "/vizier-input", withIntermediateDirectories: true)
        let socket = SocketFixture(in: bins.directory + "/vizier-input", name: "socket")
        let env = bins.env(["WAYLAND_DISPLAY": "wayland-test", "XDG_RUNTIME_DIR": bins.directory])
        let cosmic = DesktopSession(display: .wayland, family: .cosmic, currentDesktop: "COSMIC")
        let plan = await DesktopRoutes.make(session: cosmic, env: env)
        #expect(plan.writers.map(\.name) == ["wl-copy"])
        #expect(plan.senders.map(\.name) == ["ydotool-cosmic"])
        #expect(YdotoolKeySender.socketPath(variables: env.variables)?.path == socket.path)
        #expect(await WtypeKeySender(session: cosmic, env: env).probe().available == false)
        let opted = await DesktopRoutes.make(session: cosmic, env: env, allowYdotool: true)
        #expect(opted.senders.count == 1, "never retry with an unguarded ydotool sender")
        let sway = DesktopSession(display: .wayland, family: .wlroots, currentDesktop: "sway")
        #expect(await DesktopRoutes.make(session: sway, env: env).senders.map(\.name) == ["wtype"])
        #expect(bins.argv("ydotool").isEmpty && bins.argv("wtype").isEmpty, "probing must not type")
        withExtendedLifetime(socket) {}
    }

    @Test func focusHelperParsesAppIDsAndRejectsFailureOrMalformedOutput() async throws {
        let bins = FakeBins()
        bins.add("focus", body: "printf 'com.mitchellh.ghostty\\n'", reads: false)
        let reader = CosmicFocusReader(env: bins.env(), executable: bins.directory + "/focus")
        #expect(await reader.focusedWindow()?.isTerminal == true)
        #expect(bins.argv("focus") == [["--cosmic-focused-app"]])
        #expect(CosmicFocusReader.parse("org.mozilla.firefox\n")?.isTerminal == false)
        #expect(CosmicFocusReader.parse("com.system76.CosmicTerm\n")?.isTerminal == true)
        for app in ["org.gnome.Console", "io.elementary.terminal", "com.raggesilver.BlackBox"] {
            #expect(CosmicFocusReader.parse(app)?.isTerminal == true)
        }
        for value in ["", "\n", "first\nsecond", "bad\tapp", "bad\u{202E}app", "bad\u{200B}app", String(repeating: "x", count: 1025)] {
            #expect(CosmicFocusReader.parse(value) == nil)
        }
        bins.add("focus", body: "printf 'com.mitchellh.ghostty\\n'; exit 1", reads: false)
        #expect(await reader.focusedWindow() == nil)
    }

    @Test func terminalAndApplicationPasteUseDifferentEvdevChordsAndUnknownFocusSendsNothing() async throws {
        let bins = FakeBins(); bins.add("ydotool", reads: false)
        let socket = SocketFixture(in: bins.directory)
        let env = bins.env(["YDOTOOL_SOCKET": socket.path])
        try await CosmicKeySender(env: env, focus: CosmicTestFocus(terminal: true)).send(.ctrlV)
        try await CosmicKeySender(env: env, focus: CosmicTestFocus(terminal: false)).send(.ctrlShiftV)
        #expect(bins.argv("ydotool") == [
            ["key", "29:1", "42:1", "47:1", "47:0", "42:0", "29:0"],
            ["key", "29:1", "47:1", "47:0", "29:0"],
        ])
        await #expect(throws: AdapterError.self) {
            try await CosmicKeySender(env: env, focus: CosmicTestFocus(terminal: nil)).send(.ctrlV)
        }
        #expect(bins.argv("ydotool").count == 2)
        #expect(bins.socketSeen("ydotool") == socket.path)
        withExtendedLifetime(socket) {}
    }

    @Test func missingInputKeepsCosmicSenderForLateSocketRecovery() async {
        let bins = FakeBins(); bins.add("wtype", reads: false)
        bins.addClipboardTool("wl-copy"); bins.addClipboardReader()
        let env = bins.env(["WAYLAND_DISPLAY": "wayland-test"])
        let desktop = DesktopSession(display: .wayland, family: .cosmic, currentDesktop: "COSMIC")
        let plan = await DesktopRoutes.make(session: desktop, env: env, allowYdotool: true)
        #expect(plan.writers.count == 1 && plan.senders.map(\.name) == ["ydotool-cosmic"])
        #expect(FocusReaders.make(for: desktop, env: env) is CosmicFocusReader)
        #expect(await WtypeKeySender(session: desktop, env: emptyEnv()).probe().fix == CosmicSetup.fix)
    }

    @Test func inputSetupInstallsPrivateUnitWithoutStartingOrOverwritingServices() async throws {
        let bins = FakeBins()
        bins.add("ydotool", reads: false); bins.add("ydotoold", reads: false); bins.add("systemctl", reads: false)
        let directory = URL(filePath: bins.directory).appending(path: "systemd/user")
        let env = bins.env(["YDOTOOL_SOCKET": bins.directory + "/missing"])
        let first = await CosmicSetup.prepare(env: env, directory: directory, autostart: false)
        #expect(first.status == "warn" && first.detail.contains("--autostart"))
        let unit = directory.appending(path: "vizier-input.service")
        let text = try String(contentsOf: unit, encoding: .utf8)
        #expect(text.contains("RuntimeDirectoryMode=0700") && text.contains("--socket-perm=0600"))
        #expect(text.contains("--socket-path=%t/vizier-input/socket") && text.contains(bins.directory + "/ydotoold"))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "vizier.service.d/cosmic-input.conf").path))
        // The whole line is pinned: a bound of 50 tries of 0.1 s, the %t socket path, the escaped counter,
        // and the final exit 1 that fails the unit when the socket never appears.
        let waitLine = "ExecStartPost=/bin/sh -c 'i=0; while [ $$i -lt 50 ]; do [ -S \"%t/vizier-input/socket\" ] && exit 0; i=$$((i+1)); sleep 0.1; done; exit 1'"
        #expect(text.split(separator: "\n").contains(Substring(waitLine)))
        // A cycle of the failing wait plus RestartSec is about 7 s, so systemd's default limit never trips;
        // these two lines stop an endless ydotoold restart loop when the socket never appears.
        let lines = text.split(separator: "\n").map(String.init)
        let unitSection = lines.prefix { $0 != "[Service]" }
        #expect(unitSection.contains("StartLimitIntervalSec=60") && unitSection.contains("StartLimitBurst=3"))
        try Data("custom service\n".utf8).write(to: unit)
        let repeated = await CosmicSetup.prepare(env: env, directory: directory, autostart: false)
        #expect(repeated.detail.contains("Left the existing input unit unchanged"))
        #expect(try String(contentsOf: unit, encoding: .utf8) == "custom service\n")
        #expect(bins.argv("systemctl").isEmpty)
        let escaped = CosmicSetup.unitText(daemon: "/opt/a b%$\"\\/ydotoold")
        #expect(escaped.contains("ExecStart=\"/opt/a b%%$$\\\"\\\\/ydotoold\""))
    }

    @Test func existingInputIsReusedAndMissingHelpersDoNotCreateUnits() async {
        let bins = FakeBins(); bins.add("ydotool", reads: false)
        let socket = SocketFixture(in: bins.directory)
        let directory = URL(filePath: bins.directory).appending(path: "systemd/user")
        let reused = await CosmicSetup.prepare(env: bins.env(["YDOTOOL_SOCKET": socket.path]), directory: directory, autostart: true)
        #expect(reused.status == "ok")
        let missing = await CosmicSetup.prepare(env: emptyEnv(), directory: directory, autostart: true)
        #expect(missing.status == "warn")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        withExtendedLifetime(socket) {}
    }

    @Test @MainActor func normalSetupDetectsCosmicAndPrintsOnlyItsShortcuts() async throws {
        let bins = FakeBins()
        bins.add("pw-record", reads: false); bins.add("ydotool", reads: false); bins.add("ydotoold", reads: false)
        bins.addClipboardTool("wl-copy"); bins.addClipboardReader()
        let root = URL(filePath: bins.directory)
        let environment = Setup.Environment(
            variables: bins.environment(["XDG_CURRENT_DESKTOP": "COSMIC", "WAYLAND_DISPLAY": "wayland-test",
                                         "YDOTOOL_SOCKET": bins.directory + "/missing", "XDG_DATA_HOME": bins.directory + "/data"]),
            configDirectory: root.appending(path: "config"), dataDirectory: root.appending(path: "data"),
            executable: "/opt/vizier", systemdUserDirectory: root.appending(path: "systemd/user"),
            useSecretService: false, distro: .debian, packagedUnitDirectories: [], systemApplicationDirectories: [])
        let result = await Setup.run(.init(), environment: environment)
        #expect(result["desktop"]?["family"] == .string("cosmic"))
        guard case .array(let binds) = result["binds"] else { Issue.record("no shortcuts"); return }
        #expect(binds.count == 1 && binds[0]["desktop"] == .string("cosmic"))
        let description = Setup.describe(result)
        #expect(description.contains("COSMIC Settings") && description.contains("/opt/vizier toggle") && description.contains("/opt/vizier cancel"))
        #expect(description.contains("cosmic_input"))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "systemd/user/vizier-input.service").path))
    }

    @Test func socketOwnershipAndPrivateCandidateOrder() {
        let bins = FakeBins()
        let socket = SocketFixture(in: bins.directory)
        #expect(YdotoolKeySender.socketOwnedByCurrentUser(socket.path))
        #expect(!YdotoolKeySender.socketOwnedByCurrentUser(socket.path, currentUID: getuid() &+ 1))
        #expect(YdotoolKeySender.defaultCandidates(["XDG_RUNTIME_DIR": "/run/fixture"]) ==
                ["/run/fixture/vizier-input/socket", "/run/fixture/.ydotool_socket", "/tmp/.ydotool_socket"])
        #expect(YdotoolKeySender.socketPath(variables: [:], usable: { _ in true }, ownedByCurrentUser: { _ in false }) == nil)
        #expect(YdotoolKeySender.socketPath(variables: [:], usable: { _ in true }, ownedByCurrentUser: { _ in true })?.path == "/tmp/.ydotool_socket")
        withExtendedLifetime(socket) {}
    }

    @Test func aLivePrivateSocketIsChosenOverALiveLegacyOne() throws {
        let bins = FakeBins()
        try FileManager.default.createDirectory(atPath: bins.directory + "/vizier-input", withIntermediateDirectories: true)
        let legacy = SocketFixture(in: bins.directory)
        let privateSocket = SocketFixture(in: bins.directory + "/vizier-input", name: "socket")
        let variables = ["XDG_RUNTIME_DIR": bins.directory]
        let chosen = YdotoolKeySender.socketPath(variables: variables)
        #expect(chosen?.path == privateSocket.path && chosen?.explicit == false)
        // Control: the legacy socket is reachable too, so the choice above was the order and not an absence.
        #expect(YdotoolKeySender.socketPath(variables: variables, usable: { $0 != privateSocket.path })?.path == legacy.path)
        withExtendedLifetime((legacy, privateSocket)) {}
    }

    @Test func autostartGatesDeviceAccessSystemctlAndSocketReadiness() async throws {
        for scenario in ["denied", "reload-fails", "enable-fails", "no-socket", "second-reload-fails", "ready"] {
            let bins = FakeBins()
            bins.add("ydotool", reads: false); bins.add("ydotoold", reads: false)
            let root = URL(filePath: bins.directory)
            let directory = root.appending(path: "systemd/user")
            let socketPath = bins.directory + "/ready.sock"
            // Bind a synthetic socket that the readiness wait can move into place.
            let socket = SocketFixture(in: bins.directory, name: "pending.sock")
            // Only these two see a socket appear during the readiness wait.
            let socketAppears = scenario == "ready" || scenario == "second-reload-fails"
            let body: String
            switch scenario {
            case "reload-fails": body = "exit 1"
            case "enable-fails": body = "[ \"$2\" = enable ] && exit 1; exit 0"
            // The first daemon-reload succeeds; the one that follows the drop-in is the second and fails.
            case "second-reload-fails":
                let counter = bins.directory + "/reloads"
                body = "if [ \"$2\" = daemon-reload ]; then n=0; [ -f '\(counter)' ] && read n < '\(counter)'; n=$((n+1)); echo $n > '\(counter)'; [ $n -ge 2 ] && exit 1; fi; exit 0"
            default: body = "exit 0"
            }
            bins.add("systemctl", body: body, reads: false)
            let env = bins.env(["YDOTOOL_SOCKET": socketPath])
            var accessCalls = 0
            var waitCalls = 0
            // Access seam runs before systemctl. Socket activation occurs only after enable.
            let result: CosmicSetup.Result
            result = await CosmicSetup.prepare(env: env, directory: directory, autostart: true,
                                               canOpenInput: { accessCalls += 1; return scenario != "denied" },
                                               readinessAttempts: 2, readinessPause: .zero,
                                               wait: { _ in
                                                   waitCalls += 1
                                                   if socketAppears, waitCalls == 1 {
                                                       try! FileManager.default.moveItem(atPath: socket.path, toPath: socketPath)
                                                   }
                                               })
            #expect(accessCalls == 1)
            #expect(waitCalls == (socketAppears ? 1 : scenario == "no-socket" ? 2 : 0))
            let calls = bins.argv("systemctl")
            let dropIn = directory.appending(path: "vizier.service.d/cosmic-input.conf")
            #expect(FileManager.default.fileExists(atPath: dropIn.path) == socketAppears, "the drop-in is written once the socket is live, before the second reload")
            #expect(result.status == (scenario == "ready" ? "ok" : "warn"))
            // Scenarios end in different warns; the detail tells them apart where the call lists cannot.
            let started = [["--user", "daemon-reload"], ["--user", "enable", "--now", "vizier-input.service"]]
            switch scenario {
            case "denied":
                #expect(calls.isEmpty)
                #expect(result.detail == "The input unit is installed, but this user cannot open /dev/uinput; no device permissions were changed.")
            case "reload-fails":
                #expect(calls == [["--user", "daemon-reload"]])
                #expect(result.detail == "Could not start the input user unit; check systemctl --user status vizier-input.service.")
            case "enable-fails":
                #expect(calls == started)
                #expect(result.detail == "Could not start the input user unit; check systemctl --user status vizier-input.service.")
            case "no-socket":
                #expect(calls == started)
                #expect(result.detail == "The input service started but no usable socket appeared. Check the ydotool version and service journal.")
            case "second-reload-fails":
                #expect(calls == started + [["--user", "daemon-reload"]])
                #expect(result.detail == "Input is ready, but the daemon dependency could not be reloaded.")
            case "ready":
                #expect(calls == started + [["--user", "daemon-reload"]])
                #expect(result.detail == "Private input service enabled; its socket accepts connections.")
                let text = try String(contentsOf: dropIn, encoding: .utf8)
                #expect(text.contains("Wants=vizier-input.service") && text.contains("After=vizier-input.service"))
            default: Issue.record("unhandled scenario \(scenario)")
            }
            withExtendedLifetime(socket) {}
        }
    }

    @Test func lateSocketRecoversAndFailedYdotoolIsReported() async throws {
        let bins = FakeBins(); bins.add("ydotool", reads: false)
        let env = bins.env(["YDOTOOL_SOCKET": bins.directory + "/late.sock"])
        let sender = CosmicKeySender(env: env, focus: CosmicTestFocus(terminal: false))
        #expect(await sender.probe().available == false)
        await #expect(throws: AdapterError.self) { try await sender.send(.ctrlV) }
        #expect(bins.argv("ydotool").isEmpty)
        let socket = SocketFixture(in: bins.directory, name: "late.sock")
        try await sender.send(.ctrlV)
        #expect(bins.argv("ydotool").count == 1)
        bins.add("ydotool", body: "exit 1", reads: false)
        await #expect(throws: KeyDeliveryError.self) { try await sender.send(.ctrlV) }
        withExtendedLifetime(socket) {}
    }

    @Test func focusHelperDoesNotInheritWaylandDebug() async {
        let bins = FakeBins()
        bins.add("focus", body: "[ -z \"${WAYLAND_DEBUG+x}\" ] || exit 1; printf 'org.mozilla.firefox\\n'", reads: false)
        let reader = CosmicFocusReader(env: bins.env(["WAYLAND_DEBUG": "1"]), executable: bins.directory + "/focus")
        #expect(await reader.focusedWindow()?.appName == "org.mozilla.firefox")
    }

}
