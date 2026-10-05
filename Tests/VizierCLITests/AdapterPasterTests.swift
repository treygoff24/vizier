import Foundation
import Testing
import VizierEngine
@testable import VizierCLI

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private struct FakeWriter: ClipboardWriter {
    let name: String
    let log: Log
    var fails = false
    func probe() async -> AdapterProbe { AdapterProbe(name: name, available: true, detail: "") }
    func publish(_ text: String) async throws {
        log.add("publish:\(name)")
        if fails { throw AdapterError("\(name) broke") }
    }
}

private struct FakeSender: KeySender {
    let name: String
    let log: Log
    var fails = false
    func probe() async -> AdapterProbe { AdapterProbe(name: name, available: true, detail: "") }
    func send(_ chord: PasteChord) async throws {
        log.add("send:\(name):\(chord.rawValue)")
        if fails { throw AdapterError("\(name) broke") }
    }
}

private struct FixedFocus: FocusReader {
    var window: FocusedWindow?
    func focusedWindow() async -> FocusedWindow? { window }
}

@MainActor
@Suite struct AdapterPasterTests {
    private let log = Log()

    private func paster(_ routes: [(writerFails: Bool, senderFails: Bool, name: String)], focus: FocusedWindow? = nil) -> LinuxPaster {
        LinuxPaster(
            routes: routes.map { PasteRoute(writer: FakeWriter(name: "w-\($0.name)", log: log, fails: $0.writerFails), sender: FakeSender(name: $0.name, log: log, fails: $0.senderFails)) },
            focus: FixedFocus(window: focus), prePasteDelay: .milliseconds(1))
    }

    @Test func pastesWithCtrlVByDefaultAndNamesTheSender() async {
        let outcome = await paster([(false, false, "xdotool")]).paste("t", focusAtStop: nil, stillWanted: { true })
        #expect(outcome == PasteOutcome(kind: .pasted, method: "xdotool", reason: nil, onClipboard: true, permissionMissing: false, logCode: "xdotool"))
        #expect(log.all == ["publish:w-xdotool", "send:xdotool:ctrl+v"])
    }

    @Test func terminalGetsCtrlShiftV() async {
        let terminal = FocusedWindow(appName: "foot", pid: 5, isTerminal: true)
        _ = await paster([(false, false, "wtype")], focus: terminal).paste("t", focusAtStop: 5, stillWanted: { true })
        #expect(log.all.last == "send:wtype:ctrl+shift+v")
    }

    @Test func nonTerminalAndUnknownFocusGetCtrlV() async {
        _ = await paster([(false, false, "a")], focus: FocusedWindow(appName: "firefox", pid: 5, isTerminal: false)).paste("t", focusAtStop: nil, stillWanted: { true })
        _ = await paster([(false, false, "b")], focus: FocusedWindow(appName: "", pid: nil, isTerminal: nil)).paste("t", focusAtStop: nil, stillWanted: { true })
        #expect(log.all.filter { $0.hasPrefix("send") } == ["send:a:ctrl+v", "send:b:ctrl+v"])
    }

    @Test func failedPublicationTriesTheNextRoutesWriter() async {
        let outcome = await paster([(true, false, "one"), (false, false, "two")]).paste("t", focusAtStop: nil, stillWanted: { true })
        // Writers and senders are independent: the second writer published, the first sender sends.
        #expect(outcome.kind == .pasted)
        #expect(outcome.method == "one")
        #expect(log.all == ["publish:w-one", "publish:w-two", "send:one:ctrl+v"])
    }

    @Test func publicationFailureEverywhereSendsNothingAndDoesNotClaimTheClipboard() async {
        let outcome = await paster([(true, false, "one"), (true, false, "two")]).paste("t", focusAtStop: nil, stillWanted: { true })
        #expect(outcome.kind == .failed)
        #expect(!outcome.onClipboard)
        #expect(outcome.logCode == "failed-clipboard")
        #expect(!log.all.contains { $0.hasPrefix("send") })
    }

    @Test func noRoutesIsAFailureWithoutClipboard() async {
        let outcome = await paster([]).paste("t", focusAtStop: nil, stillWanted: { true })
        #expect(outcome.kind == .failed)
        #expect(!outcome.onClipboard)
    }

    @Test func aSenderThatThrewSentNothingSoTheNextSenderIsTried() async {
        let outcome = await paster([(false, true, "wtype"), (false, false, "ydotool")]).paste("t", focusAtStop: nil, stillWanted: { true })
        #expect(outcome.kind == .pasted)
        #expect(outcome.method == "ydotool")
        #expect(log.all == ["publish:w-wtype", "send:wtype:ctrl+v", "send:ydotool:ctrl+v"])
    }

    @Test func onceASenderReturnedNoOtherSenderIsEverTried() async {
        let outcome = await paster([(false, false, "wtype"), (false, false, "ydotool")]).paste("t", focusAtStop: nil, stillWanted: { true })
        #expect(outcome.method == "wtype")
        #expect(log.all.filter { $0.hasPrefix("send") } == ["send:wtype:ctrl+v"])
    }

    @Test func everySenderFailingKeepsTheClipboardClaim() async {
        let outcome = await paster([(false, true, "a"), (false, true, "b")]).paste("t", focusAtStop: nil, stillWanted: { true })
        #expect(outcome.kind == .failed)
        #expect(outcome.onClipboard)
        #expect(outcome.logCode == "failed")
        #expect(outcome.reason?.contains("a:") == true)
    }

    @Test func aSenderIsNotAskedTwiceAcrossRoutesThatShareIt() async {
        let shared = FakeSender(name: "ydotool", log: log, fails: true)
        let p = LinuxPaster(routes: [PasteRoute(writer: FakeWriter(name: "w1", log: log), sender: shared),
                                     PasteRoute(writer: FakeWriter(name: "w2", log: log), sender: shared)],
                            focus: FixedFocus(window: nil), prePasteDelay: .milliseconds(1))
        _ = await p.paste("t", focusAtStop: nil, stillWanted: { true })
        #expect(log.all.filter { $0.hasPrefix("send") }.count == 1)
    }

    @Test func withdrawnLeavesTheTextOnTheClipboardAndSendsNothing() async {
        let order = Log()
        let outcome = await paster([(false, false, "x")]).paste("t", focusAtStop: nil, stillWanted: { order.add("asked"); return false })
        #expect(outcome.kind == .withdrawn)
        #expect(outcome.onClipboard)
        #expect(outcome.logCode == "withdrawn")
        #expect(log.all == ["publish:w-x"])
        #expect(order.all == ["asked"])
    }

    @Test func stillWantedIsReadAfterPublicationAndTheFocusCheck() async {
        // Escape pressed during the pause: the answer is read once the clipboard is published.
        var asked = false
        let published = log
        let outcome = await paster([(false, false, "x")]).paste("t", focusAtStop: nil, stillWanted: {
            asked = true
            #expect(published.all == ["publish:w-x"])
            return true
        })
        #expect(asked)
        #expect(outcome.kind == .pasted)
    }

    @Test func movedFocusHoldsWithTheSharedReason() async {
        let outcome = await paster([(false, false, "x")], focus: FocusedWindow(appName: "firefox", pid: 22, isTerminal: false))
            .paste("t", focusAtStop: 11, stillWanted: { true })
        #expect(outcome.kind == .held)
        #expect(outcome.reason == PasteDecision.focusMoved)
        #expect(outcome.logCode == "held-focus-moved")
        #expect(outcome.onClipboard)
        #expect(!log.all.contains { $0.hasPrefix("send") })
    }

    @Test func unknownPidAtEitherEndDoesNotHold() async {
        let same = await paster([(false, false, "a")], focus: FocusedWindow(appName: "x", pid: 11, isTerminal: false)).paste("t", focusAtStop: 11, stillWanted: { true })
        let unknownNow = await paster([(false, false, "b")], focus: FocusedWindow(appName: "x", pid: nil, isTerminal: nil)).paste("t", focusAtStop: 11, stillWanted: { true })
        let unknownThen = await paster([(false, false, "c")], focus: FocusedWindow(appName: "x", pid: 11, isTerminal: false)).paste("t", focusAtStop: nil, stillWanted: { true })
        #expect([same.kind, unknownNow.kind, unknownThen.kind] == [.pasted, .pasted, .pasted])
    }

    // MARK: the clipboard is checked again right before the chord

    private final class SharedClipboard: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        var value: String? { get { lock.lock(); defer { lock.unlock() }; return text } set { lock.lock(); text = newValue; lock.unlock() } }
    }

    private struct ReadableWriter: ClipboardReadable {
        let name = "readable"
        let clipboard: SharedClipboard
        func probe() async -> AdapterProbe { AdapterProbe(name: name, available: true, detail: "") }
        func publish(_ text: String) async throws { clipboard.value = text }
        func readBack(maxBytes: Int) async -> String? { clipboard.value }
    }

    private struct ReplacingFocus: FocusReader {
        let onRead: @Sendable () -> Void
        func focusedWindow() async -> FocusedWindow? { onRead(); return nil }
    }

    @Test func aSelectionReplacedDuringThePauseSendsNothingAndDropsTheClipboardClaim() async {
        let clipboard = SharedClipboard()
        // Another app takes the selection after publication, while the paster waits and reads the focus.
        let p = LinuxPaster(
            routes: [PasteRoute(writer: ReadableWriter(clipboard: clipboard), sender: FakeSender(name: "xdotool", log: log))],
            focus: ReplacingFocus(onRead: { clipboard.value = "the user's own copy" }), prePasteDelay: .milliseconds(1))
        let outcome = await p.paste("dictated", focusAtStop: nil, stillWanted: { true })
        #expect(outcome.kind == .failed)
        #expect(!outcome.onClipboard)
        #expect(outcome.logCode == "failed-clipboard-replaced")
        #expect(!log.all.contains { $0.hasPrefix("send") })
        // Control: the same wiring with nothing replacing the selection pastes.
        let untouched = SharedClipboard()
        let q = LinuxPaster(
            routes: [PasteRoute(writer: ReadableWriter(clipboard: untouched), sender: FakeSender(name: "xdotool", log: log))],
            focus: FixedFocus(window: nil), prePasteDelay: .milliseconds(1))
        #expect(await q.paste("dictated", focusAtStop: nil, stillWanted: { true }).kind == .pasted)
    }

    // MARK: real adapters against fake helper binaries

    @Test func realAdaptersPublishThenPasteAcrossFakeHelpers() async {
        let bins = FakeBins()
        bins.addClipboardTool("wl-copy"); bins.addClipboardReader(); bins.add("wtype", reads: false)
        let session = DesktopSession(display: .wayland, family: .wlroots, currentDesktop: "sway")
        let env = bins.env(["WAYLAND_DISPLAY": "wayland-1"])
        let plan = await DesktopRoutes.make(session: session, env: env)
        #expect(plan.senders.map(\.name) == ["wtype"])
        let p = LinuxPaster(plan: plan, focus: FixedFocus(window: FocusedWindow(appName: "foot", pid: 3, isTerminal: true)), prePasteDelay: .milliseconds(1))
        let outcome = await p.paste("dictated words", focusAtStop: 3, stillWanted: { true })
        #expect(outcome.kind == .pasted)
        #expect(outcome.method == "wtype")
        #expect(bins.stdin("wl-copy") == "dictated words")
        #expect(bins.argv("wtype") == [["-M", "ctrl", "-M", "shift", "-k", "v", "-m", "shift", "-m", "ctrl"]])
        // Publication readback, then the check right before the chord.
        #expect(bins.argv("wl-paste").count == 2)
    }

    @Test func routesAreChosenByProbeNotByInstallation() async {
        let bins = FakeBins()
        for name in ["wl-copy", "wl-paste", "wtype", "xdotool", "ydotool"] { bins.add(name) }
        bins.addClipboardTool("xclip")
        let socket = SocketFixture(in: bins.directory, name: "yd.sock")
        let gnome = DesktopSession(display: .wayland, family: .gnome, currentDesktop: "GNOME")
        let waylandEnv = bins.env(["WAYLAND_DISPLAY": "wayland-0", "YDOTOOL_SOCKET": socket.path])
        // GNOME Wayland: wtype and wl-copy are installed but unusable. Only an opted-in ydotool is left
        // as a sender, and there is no usable clipboard writer.
        #expect(await DesktopRoutes.make(session: gnome, env: waylandEnv).isEmpty)
        let gnomeYdotool = await DesktopRoutes.make(session: gnome, env: waylandEnv, allowYdotool: true)
        #expect(gnomeYdotool.isEmpty)
        #expect(gnomeYdotool.senders.map(\.name) == ["ydotool"])

        let sway = DesktopSession(display: .wayland, family: .wlroots, currentDesktop: "sway")
        #expect(await DesktopRoutes.make(session: sway, env: waylandEnv).senders.map(\.name) == ["wtype"])
        #expect(await DesktopRoutes.make(session: sway, env: waylandEnv, allowYdotool: true).senders.map(\.name) == ["wtype", "ydotool"])

        let x11 = DesktopSession(display: .x11, family: .gnome, currentDesktop: "GNOME")
        let x11Env = bins.env(["DISPLAY": ":0", "YDOTOOL_SOCKET": socket.path])
        #expect(await DesktopRoutes.make(session: x11, env: x11Env).senders.map(\.name) == ["xdotool"])
        #expect(await DesktopRoutes.make(session: x11, env: x11Env, allowYdotool: true).senders.map(\.name) == ["xdotool", "ydotool"])
        #expect(await DesktopRoutes.make(session: DesktopSession(display: .none, family: .other, currentDesktop: ""), env: x11Env).isEmpty)
    }

    @Test func aFailedKeyHelperReportsUncertainDelivery() async throws {
        let bins = FakeBins()
        bins.add("slow", body: "sleep 5", reads: false)
        // Uncertain delivery at the deadline must not invite a second injector.
        await #expect(throws: KeyDeliveryError.self) { try await Helper.send(["slow"], environment: bins.environment(), timeout: .milliseconds(200)) }
        // A non-zero exit and a death by signal are post-spawn results too: events may already have been written.
        bins.add("bad", body: "echo 'compositor refuses' >&2; exit 1", reads: false)
        await #expect(throws: KeyDeliveryError.self) { try await Helper.send(["bad"], environment: bins.environment()) }
        bins.add("killed", body: "kill -KILL $$", reads: false)
        await #expect(throws: KeyDeliveryError.self) { try await Helper.send(["killed"], environment: bins.environment()) }
        // Only a helper that could not be spawned at all sent nothing.
        await #expect(throws: AdapterError.self) { try await Helper.send(["vizier-absent"], environment: bins.environment()) }
    }

    @Test func aSenderThatDeliveredThenExitedNonZeroIsNotFollowedByAnotherSender() async {
        let bins = FakeBins()
        bins.addClipboardTool("wl-copy"); bins.addClipboardReader()
        // wtype records that it delivered the chord, then reports failure.
        bins.add("wtype", body: ": > '\(bins.directory)/delivered'; echo late failure >&2; exit 1", reads: false)
        bins.add("ydotool", reads: false)
        let socket = SocketFixture(in: bins.directory, name: "yd.sock")
        let session = DesktopSession(display: .wayland, family: .wlroots, currentDesktop: "sway")
        let env = bins.env(["WAYLAND_DISPLAY": "wayland-1", "YDOTOOL_SOCKET": socket.path])
        let plan = PastePlan(writers: [WlCopyClipboardWriter(session: session, env: env)],
                             senders: [WtypeKeySender(session: session, env: env), YdotoolKeySender(env: env)])
        let outcome = await LinuxPaster(plan: plan, focus: FixedFocus(window: nil), prePasteDelay: .milliseconds(1)).paste("once only", focusAtStop: nil, stillWanted: { true })
        #expect(FileManager.default.fileExists(atPath: bins.directory + "/delivered"))
        #expect(outcome.kind == .failed)
        #expect(outcome.logCode == "failed-key-helper")
        #expect(outcome.method == "wtype")
        #expect(bins.argv("ydotool").isEmpty)
    }

    @Test func withoutAnyWorkingSenderTheTextIsStillPublishedAndVerified() async {
        let bins = FakeBins()
        bins.addClipboardTool("wl-copy"); bins.addClipboardReader()
        let session = DesktopSession(display: .wayland, family: .wlroots, currentDesktop: "sway")
        let env = bins.env(["WAYLAND_DISPLAY": "wayland-1"])  // wtype is not installed
        let plan = await DesktopRoutes.make(session: session, env: env)
        #expect(plan.writers.map(\.name) == ["wl-copy"])
        #expect(plan.senders.isEmpty)
        let outcome = await LinuxPaster(plan: plan, focus: FixedFocus(window: nil), prePasteDelay: .milliseconds(1)).paste("paste me yourself", focusAtStop: nil, stillWanted: { true })
        #expect(outcome.kind == .failed)
        #expect(outcome.onClipboard)
        #expect(outcome.logCode == "failed-no-sender")
        #expect(bins.clipboard == "paste me yourself")
    }

    @Test func xselIsTriedWhenXclipIsInstalledButFails() async {
        let bins = FakeBins()
        bins.addClipboardTool("xclip", failsWith: 1)
        bins.addClipboardTool("xsel")
        bins.add("xdotool", reads: false)
        let session = DesktopSession(display: .x11, family: .other, currentDesktop: "")
        let plan = await DesktopRoutes.make(session: session, env: bins.env(["DISPLAY": ":0"]))
        #expect(plan.writers.map(\.name) == ["xclip", "xsel"])
        let outcome = await LinuxPaster(plan: plan, focus: FixedFocus(window: nil), prePasteDelay: .milliseconds(1)).paste("through xsel", focusAtStop: nil, stillWanted: { true })
        #expect(outcome.kind == .pasted)
        #expect(bins.stdin("xsel") == "through xsel")
        #expect(bins.stdin("xclip") == nil)
    }
}
