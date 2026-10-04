import Foundation
import Testing
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
        for value in ["", "\n", "first\nsecond", "bad\tapp", String(repeating: "x", count: 1025)] {
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
        await #expect(throws: CLIError.self) {
            try await CosmicKeySender(env: env, focus: CosmicTestFocus(terminal: nil)).send(.ctrlV)
        }
        #expect(bins.argv("ydotool").count == 2)
        #expect(bins.socketSeen("ydotool") == socket.path)
        withExtendedLifetime(socket) {}
    }

    @Test func missingInputLeavesCosmicClipboardOnlyEvenWhenWtypeExists() async {
        let bins = FakeBins(); bins.add("wtype", reads: false)
        bins.addClipboardTool("wl-copy"); bins.addClipboardReader()
        let env = bins.env(["WAYLAND_DISPLAY": "wayland-test"])
        let desktop = DesktopSession(display: .wayland, family: .cosmic, currentDesktop: "COSMIC")
        let plan = await DesktopRoutes.make(session: desktop, env: env, allowYdotool: true)
        #expect(plan.writers.count == 1 && plan.senders.isEmpty)
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
        let dependency = try String(contentsOf: directory.appending(path: "vizier.service.d/cosmic-input.conf"), encoding: .utf8)
        #expect(dependency.contains("After=vizier-input.service") && dependency.contains("Wants=vizier-input.service"))
        try Data("custom service\n".utf8).write(to: unit)
        _ = await CosmicSetup.prepare(env: env, directory: directory, autostart: false)
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
}
