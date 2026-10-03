import Foundation
import Glibc
import Testing
@testable import VizierCLI

@Suite struct AdapterDesktopTests {
    // MARK: detection

    @Test(arguments: [
        // (environment, display, family)
        (["XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0", "XDG_CURRENT_DESKTOP": "GNOME"], DesktopSession.Display.wayland, DesktopSession.Family.gnome),
        (["XDG_SESSION_TYPE": "x11", "DISPLAY": ":0", "XDG_CURRENT_DESKTOP": "ubuntu:GNOME"], .x11, .gnome),
        (["XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "wayland-0", "XDG_CURRENT_DESKTOP": "KDE"], .wayland, .kde),
        (["XDG_SESSION_TYPE": "x11", "DISPLAY": ":1", "XDG_CURRENT_DESKTOP": "KDE"], .x11, .kde),
        (["WAYLAND_DISPLAY": "wayland-1", "XDG_CURRENT_DESKTOP": "sway"], .wayland, .wlroots),
        (["WAYLAND_DISPLAY": "wayland-1", "XDG_CURRENT_DESKTOP": "river"], .wayland, .wlroots),
        (["WAYLAND_DISPLAY": "wayland-1", "XDG_CURRENT_DESKTOP": "niri"], .wayland, .wlroots),
        (["WAYLAND_DISPLAY": "wayland-1", "XDG_CURRENT_DESKTOP": "Hyprland"], .wayland, .hyprland),
        (["WAYLAND_DISPLAY": "wayland-1", "XDG_CURRENT_DESKTOP": "COSMIC"], .wayland, .cosmic),
        (["WAYLAND_DISPLAY": "wayland-1", "SWAYSOCK": "/run/sway.sock"], .wayland, .wlroots),
        (["WAYLAND_DISPLAY": "wayland-1", "HYPRLAND_INSTANCE_SIGNATURE": "abc"], .wayland, .hyprland),
        (["DISPLAY": ":0", "XDG_CURRENT_DESKTOP": "XFCE"], .x11, .other),
        // XWayland: a Wayland session that also exports DISPLAY is Wayland.
        (["WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0", "XDG_CURRENT_DESKTOP": "sway"], .wayland, .wlroots),
        // session type says x11 but there is no DISPLAY: fall back to what exists.
        (["XDG_SESSION_TYPE": "x11", "WAYLAND_DISPLAY": "wayland-0"], .wayland, .other),
        (["XDG_SESSION_TYPE": "tty"], .none, .other),
        ([:], .none, .other),
    ])
    func detectMatrix(environment: [String: String], display: DesktopSession.Display, family: DesktopSession.Family) {
        let session = DesktopSession.detect(environment: environment)
        #expect(session.display == display)
        #expect(session.family == family)
        #expect(session.currentDesktop == (environment["XDG_CURRENT_DESKTOP"] ?? ""))
    }

    @Test func distroFamilyFromOsRelease() {
        #expect(DistroFamily.parse(osRelease: "ID=debian\nVERSION_ID=13\n") == .debian)
        #expect(DistroFamily.parse(osRelease: "ID=pop\nID_LIKE=\"ubuntu debian\"\n") == .debian)
        #expect(DistroFamily.parse(osRelease: "ID=fedora\n") == .fedora)
        #expect(DistroFamily.parse(osRelease: "ID=endeavouros\nID_LIKE=arch\n") == .arch)
        #expect(DistroFamily.parse(osRelease: "ID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n") == .suse)
        #expect(DistroFamily.parse(osRelease: "ID=nixos\n") == .other)
    }

    // MARK: terminals

    @Test(arguments: ["foot", "Alacritty", "kitty", "org.wezfurlong.wezterm", "com.mitchellh.ghostty", "gnome-terminal-server",
                      "gnome-terminal-", "org.kde.konsole", "XTerm", "org.gnome.Ptyxis", "Tilix", "terminator", "xfce4-terminal", "URxvt", "st"])
    func knownTerminals(id: String) { #expect(TerminalList.isTerminal(id)) }

    @Test(arguments: ["firefox", "code", "gedit", "", "org.mozilla.firefox", "stellarium", "footage", "slack"])
    func nonTerminals(id: String) { #expect(!TerminalList.isTerminal(id)) }

    // MARK: focus readers

    @Test func hyprlandAndSwayParsing() {
        let hypr = HyprlandFocusReader.parse(Data(#"{"class":"foot","pid":4242,"title":"secret"}"#.utf8))
        #expect(hypr == FocusedWindow(appName: "foot", pid: 4242, isTerminal: true))
        #expect(HyprlandFocusReader.parse(Data("{}".utf8)) == nil)
        #expect(HyprlandFocusReader.parse(Data("".utf8)) == nil)

        let tree = #"""
        {"type":"root","focused":false,"nodes":[{"type":"output","focused":false,"nodes":[{"type":"workspace","focused":false,
        "nodes":[{"type":"con","focused":false,"app_id":"firefox","pid":10,"nodes":[]},
        {"type":"con","focused":true,"app_id":"kitty","pid":11,"nodes":[]}],"floating_nodes":[]}]}]}
        """#
        #expect(SwayFocusReader.parse(Data(tree.utf8)) == FocusedWindow(appName: "kitty", pid: 11, isTerminal: true))
        let xway = #"{"focused":false,"nodes":[{"focused":true,"app_id":null,"pid":12,"window_properties":{"class":"Firefox"},"nodes":[]}]}"#
        #expect(SwayFocusReader.parse(Data(xway.utf8)) == FocusedWindow(appName: "Firefox", pid: 12, isTerminal: false))
        // A focused workspace with no window on it has no pid: unknown.
        #expect(SwayFocusReader.parse(Data(#"{"focused":false,"nodes":[{"type":"workspace","focused":true,"nodes":[]}]}"#.utf8)) == nil)
    }

    @Test func x11FocusReadsPidThenComm() async throws {
        let bins = FakeBins()
        bins.add("xdotool", body: "echo 4321", reads: false)
        let proc = NSTemporaryDirectory() + "vizier-proc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: proc + "/4321", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: proc) }
        try "gnome-terminal-\n".write(toFile: proc + "/4321/comm", atomically: true, encoding: .utf8)
        let reader = X11FocusReader(env: bins.env(), procRoot: proc)
        let window = await reader.focusedWindow()
        #expect(window == FocusedWindow(appName: "gnome-terminal-", pid: 4321, isTerminal: true))
        #expect(bins.argv("xdotool") == [["getactivewindow", "getwindowpid"]])

        let failing = FakeBins()
        failing.add("xdotool", body: "echo 'no window' >&2; exit 1", reads: false)
        #expect(await X11FocusReader(env: failing.env(), procRoot: proc).focusedWindow() == nil)
    }

    @Test func focusReaderSelection() {
        #expect(FocusReaders.make(for: DesktopSession(display: .wayland, family: .gnome, currentDesktop: "GNOME")) is UnknownFocusReader)
        #expect(FocusReaders.make(for: DesktopSession(display: .wayland, family: .kde, currentDesktop: "KDE")) is UnknownFocusReader)
        #expect(FocusReaders.make(for: DesktopSession(display: .x11, family: .gnome, currentDesktop: "GNOME")) is X11FocusReader)
        #expect(FocusReaders.make(for: DesktopSession(display: .wayland, family: .hyprland, currentDesktop: "Hyprland")) is HyprlandFocusReader)
        #expect(FocusReaders.make(for: DesktopSession(display: .wayland, family: .wlroots, currentDesktop: "sway"), env: HelperEnvironment(variables: ["SWAYSOCK": "/s"], distro: .other)) is SwayFocusReader)
        #expect(FocusReaders.make(for: DesktopSession(display: .wayland, family: .wlroots, currentDesktop: "river"), env: HelperEnvironment(variables: [:], distro: .other)) is UnknownFocusReader)
    }

    // MARK: X11

    @Test func x11WriterAndSenderArgv() async throws {
        let bins = FakeBins()
        bins.addClipboardTool("xclip"); bins.add("xdotool", reads: false)
        let env = bins.env(["DISPLAY": ":7"])
        try await X11ClipboardWriter(tool: .xclip, env: env).publish("hello clip")
        // The publication is proven by reading the selection back.
        #expect(bins.argv("xclip") == [["-selection", "clipboard", "-in"], ["-selection", "clipboard", "-o"]])
        #expect(bins.stdin("xclip") == "hello clip")
        try await XdotoolKeySender(env: env).send(.ctrlV)
        try await XdotoolKeySender(env: env).send(.ctrlShiftV)
        #expect(bins.argv("xdotool") == [["key", "--clearmodifiers", "ctrl+v"], ["key", "--clearmodifiers", "ctrl+shift+v"]])
    }

    @Test func xselIsTheFallbackTool() async throws {
        let bins = FakeBins()
        bins.addClipboardTool("xsel")
        let writer = X11ClipboardWriter.installed(env: bins.env(["DISPLAY": ":0"]))
        #expect(writer?.tool == .xsel)
        try await writer?.publish("t")
        #expect(bins.argv("xsel") == [["--clipboard", "--input"], ["--clipboard", "--output"]])
        #expect(X11ClipboardWriter.installed(env: emptyEnv()) == nil)
    }

    @Test func helperFailureThrowsAndKeepsTheTextOutOfTheMessage() async {
        let bins = FakeBins()
        bins.add("xclip", body: "echo 'Error: Can not open display' >&2; exit 1")
        let writer = X11ClipboardWriter(tool: .xclip, env: bins.env(["DISPLAY": ":0"]))
        do {
            try await writer.publish("a dictated secret")
            Issue.record("publish should have thrown")
        } catch {
            #expect(!"\(error)".contains("secret"))
            #expect("\(error)".contains("status 1"))
        }
    }

    @Test func x11ProbesNeedTheBinaryAndTheDisplay() async {
        let bins = FakeBins()
        bins.add("xclip"); bins.add("xdotool")
        #expect(await X11ClipboardWriter(tool: .xclip, env: bins.env(["DISPLAY": ":0"])).probe().available)
        let noDisplay = await XdotoolKeySender(env: bins.env()).probe()
        #expect(!noDisplay.available)
        #expect(noDisplay.detail.contains("DISPLAY"))
        let missing = await XdotoolKeySender(env: emptyEnv(["DISPLAY": ":0"], distro: .fedora)).probe()
        #expect(!missing.available)
        #expect(missing.fix == "sudo dnf install xdotool")
        #expect(await X11ClipboardWriter(tool: .xclip, env: emptyEnv(distro: .arch)).probe().fix == "sudo pacman -S xclip")
    }

    // MARK: wlroots

    @Test func wlCopyAndWtypeArgv() async throws {
        let bins = FakeBins()
        bins.addClipboardTool("wl-copy"); bins.addClipboardReader(); bins.add("wtype", reads: false)
        let session = DesktopSession(display: .wayland, family: .wlroots, currentDesktop: "sway")
        let env = bins.env(["WAYLAND_DISPLAY": "wayland-1"])
        try await WlCopyClipboardWriter(session: session, env: env).publish("wayland text")
        #expect(bins.argv("wl-paste") == [["--no-newline"]])
        #expect(bins.stdin("wl-copy") == "wayland text")
        try await WtypeKeySender(session: session, env: env).send(.ctrlV)
        try await WtypeKeySender(session: session, env: env).send(.ctrlShiftV)
        #expect(bins.argv("wtype") == [
            ["-M", "ctrl", "-k", "v", "-m", "ctrl"],
            ["-M", "ctrl", "-M", "shift", "-k", "v", "-m", "shift", "-m", "ctrl"],
        ])
    }

    @Test(arguments: [DesktopSession.Family.gnome, .kde])
    func wtypeIsNotAvailableOnGnomeOrKdeEvenWhenInstalled(family: DesktopSession.Family) async {
        let bins = FakeBins()
        bins.add("wtype"); bins.add("wl-copy")
        let session = DesktopSession(display: .wayland, family: family, currentDesktop: family.rawValue)
        let probe = await WtypeKeySender(session: session, env: bins.env(["WAYLAND_DISPLAY": "wayland-0"])).probe()
        #expect(!probe.available)
        #expect(probe.detail.contains("virtual-keyboard"))
    }

    @Test func wlCopyOnGnomeIsRefusedAndNeedsAWaylandSocket() async {
        let bins = FakeBins()
        bins.add("wl-copy"); bins.add("wl-paste")
        let gnome = DesktopSession(display: .wayland, family: .gnome, currentDesktop: "GNOME")
        #expect(!(await WlCopyClipboardWriter(session: gnome, env: bins.env(["WAYLAND_DISPLAY": "wayland-0"])).probe().available))
        let sway = DesktopSession(display: .wayland, family: .wlroots, currentDesktop: "sway")
        #expect(!(await WlCopyClipboardWriter(session: sway, env: bins.env()).probe().available))
        #expect(await WlCopyClipboardWriter(session: sway, env: bins.env(["WAYLAND_DISPLAY": "wayland-0"])).probe().available)
        #expect(await WlCopyClipboardWriter(session: sway, env: emptyEnv(["WAYLAND_DISPLAY": "w"], distro: .debian)).probe().fix == "sudo apt install wl-clipboard")
    }

    // MARK: ydotool

    @Test func ydotoolSocketResolution() {
        let both: (String) -> Bool = { $0 == "/run/user/1000/.ydotool_socket" || $0 == "/tmp/.ydotool_socket" }
        // YDOTOOL_SOCKET wins, without a check.
        #expect(YdotoolKeySender.socketPath(variables: ["YDOTOOL_SOCKET": "/x/s", "XDG_RUNTIME_DIR": "/run/user/1000"], usable: { _ in false })?.path == "/x/s")
        // Both usable: the runtime dir first.
        #expect(YdotoolKeySender.socketPath(variables: ["XDG_RUNTIME_DIR": "/run/user/1000"], usable: both)?.path == "/run/user/1000/.ydotool_socket")
        // Only the /tmp one is usable (ydotoold built for the old default, or a stale file in the runtime dir): found anyway.
        #expect(YdotoolKeySender.socketPath(variables: ["XDG_RUNTIME_DIR": "/run/user/1000"], usable: { $0 == "/tmp/.ydotool_socket" })?.path == "/tmp/.ydotool_socket")
        #expect(YdotoolKeySender.socketPath(variables: ["XDG_RUNTIME_DIR": "/run/user/1000"], usable: { _ in false }) == nil)
    }

    @Test func aSocketIsLiveOnlyWhenItIsASocketThatAcceptsAConnect() throws {
        let bins = FakeBins()
        let datagram = SocketFixture(in: bins.directory, name: "dgram")
        let stream = SocketFixture(in: bins.directory, name: "stream", stream: true)
        #expect(YdotoolKeySender.socketState(datagram.path) == .live)
        #expect(YdotoolKeySender.socketState(stream.path) == .live)
        let regular = bins.directory + "/regular"
        FileManager.default.createFile(atPath: regular, contents: nil)
        #expect(YdotoolKeySender.socketState(regular) == .notASocket)
        #expect(YdotoolKeySender.socketState(bins.directory + "/gone") == .missing)
        // A socket nobody listens on any more: the file is left behind when the owner closes.
        let stale = bins.directory + "/stale"
        do { _ = SocketFixture(in: bins.directory, name: "stale", stream: true) }
        #expect(FileManager.default.fileExists(atPath: stale))
        #expect(YdotoolKeySender.socketState(stale) == .refused)
    }

    @Test func aStaleOrPlainFileInTheRuntimeDirFallsThroughToTheNextCandidate() throws {
        let bins = FakeBins()
        // The runtime dir holds a regular file named like the socket; the default resolution must not use it.
        FileManager.default.createFile(atPath: bins.directory + "/.ydotool_socket", contents: nil)
        let variables = ["XDG_RUNTIME_DIR": bins.directory]
        #expect(YdotoolKeySender.socketPath(variables: variables, usable: { YdotoolKeySender.socketState($0) == .live })?.path != bins.directory + "/.ydotool_socket")
    }

    @Test func ydotoolSendsKeycodesAndTellsTheClientTheSocket() async throws {
        let bins = FakeBins()
        bins.add("ydotool", reads: false)
        let explicit = SocketFixture(in: bins.directory, name: "explicit")
        let env = bins.env(["YDOTOOL_SOCKET": explicit.path])
        try await YdotoolKeySender(env: env).send(.ctrlV)
        try await YdotoolKeySender(env: env).send(.ctrlShiftV)
        #expect(bins.argv("ydotool") == [
            ["key", "29:1", "47:1", "47:0", "29:0"],
            ["key", "29:1", "42:1", "47:1", "47:0", "42:0", "29:0"],
        ])
        #expect(bins.socketSeen("ydotool") == explicit.path)

        // No YDOTOOL_SOCKET: the socket that is live is found and handed to the client, so a client
        // whose built-in default is the other location still reaches the daemon.
        let found = SocketFixture(in: bins.directory)
        try await YdotoolKeySender(env: bins.env(["XDG_RUNTIME_DIR": bins.directory])).send(.ctrlV)
        #expect(bins.socketSeen("ydotool") == found.path)
    }

    @Test func ydotoolProbeChecksTheDaemonSocket() async throws {
        let bins = FakeBins()
        bins.add("ydotool")
        let real = SocketFixture(in: bins.directory, name: "real.sock")
        #expect(await YdotoolKeySender(env: bins.env(["YDOTOOL_SOCKET": real.path])).probe().available)
        let missing = await YdotoolKeySender(env: bins.env(["YDOTOOL_SOCKET": bins.directory + "/gone"])).probe()
        #expect(!missing.available)
        #expect(missing.detail.contains("does not exist"))
        #expect(missing.fix?.contains("ydotoold") == true)
        // A leftover regular file is not a daemon.
        let plain = bins.directory + "/plain"
        FileManager.default.createFile(atPath: plain, contents: nil)
        let notSocket = await YdotoolKeySender(env: bins.env(["YDOTOOL_SOCKET": plain])).probe()
        #expect(!notSocket.available)
        #expect(notSocket.detail.contains("not a socket"))
        // Binary absent: the install command for the distro family.
        let absent = await YdotoolKeySender(env: emptyEnv(["YDOTOOL_SOCKET": real.path], distro: .suse)).probe()
        #expect(!absent.available)
        #expect(absent.fix == "sudo zypper install ydotool")
    }

    // MARK: probes that reach the compositor

    @Test func xdotoolProbeRunsAnInertCallAndFailsWhenTheServerIsUnreachable() async {
        let bins = FakeBins()
        bins.add("xdotool", body: "[ \"$1\" = getmouselocation ] || exit 9; exit 0", reads: false)
        let ok = await XdotoolKeySender(env: bins.env(["DISPLAY": ":0"])).probe()
        #expect(ok.available)
        #expect(bins.argv("xdotool") == [["getmouselocation"]])
        let broken = FakeBins()
        broken.add("xdotool", body: "echo 'Error: Can not open display' >&2; exit 1", reads: false)
        let down = await XdotoolKeySender(env: broken.env(["DISPLAY": ":0"])).probe()
        #expect(!down.available)
        #expect(down.detail.contains("cannot reach the X server"))
    }

    @Test func wlrootsProbesSayTheProtocolIsNotVerified() async {
        let bins = FakeBins()
        bins.add("wl-copy"); bins.add("wl-paste"); bins.add("wtype")
        let session = DesktopSession(display: .wayland, family: .wlroots, currentDesktop: "sway")
        let env = bins.env(["WAYLAND_DISPLAY": "wayland-1"])
        #expect(await WtypeKeySender(session: session, env: env).probe().detail.contains("not verified"))
        #expect(await WlCopyClipboardWriter(session: session, env: env).probe().detail.contains("not verified"))
        // wl-copy without wl-paste cannot prove a publication, so it is not usable.
        let noPaste = FakeBins()
        noPaste.add("wl-copy")
        #expect(!(await WlCopyClipboardWriter(session: session, env: noPaste.env(["WAYLAND_DISPLAY": "w"])).probe().available))
    }

    // MARK: clipboard publication is proven by readback

    @Test func publicationIsAcceptedOnceTheSelectionIsTakenEvenWhenItIsLate() async throws {
        let bins = FakeBins()
        bins.addClipboardTool("xclip", delay: 0.25)
        try await X11ClipboardWriter(tool: .xclip, env: bins.env(["DISPLAY": ":0"])).publish("late text")
        #expect(bins.clipboard == "late text")
    }

    @Test func aHelperThatNeverTakesTheSelectionFailsPublicationAndIsStopped() async throws {
        let bins = FakeBins()
        // It reads its stdin, then runs on without ever owning the selection.
        bins.addClipboardTool("xclip", acquires: false, hangs: true)
        let writer = X11ClipboardWriter(tool: .xclip, env: bins.env(["DISPLAY": ":0"]))
        await #expect(throws: AdapterError.self) { try await writer.publish("secret words") }
        let pid = pid_t(try String(contentsOfFile: bins.directory + "/xclip.pid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        var alive = true
        for _ in 0..<40 {
            if kill(pid, 0) != 0 { alive = false; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!alive)
        // An exit-0 helper with nothing behind it fails the same way, without leaking the text into the message.
        let quiet = FakeBins()
        quiet.addClipboardTool("xclip", acquires: false)
        do {
            try await X11ClipboardWriter(tool: .xclip, env: quiet.env(["DISPLAY": ":0"])).publish("another secret")
            Issue.record("publish should have thrown")
        } catch {
            #expect(!"\(error)".contains("secret"))
        }
    }

    @Test func aForeignSelectionThatDiffersFromTheTextIsNotAcceptedAsOurs() async {
        let bins = FakeBins()
        bins.addClipboardTool("xclip", acquires: false)
        bins.setClipboard("someone else's text")
        await #expect(throws: AdapterError.self) { try await X11ClipboardWriter(tool: .xclip, env: bins.env(["DISPLAY": ":0"])).publish("ours") }
    }
}
