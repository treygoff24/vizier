import Foundation
import Testing
import VizierEngine
@testable import VizierCLI

// End-to-end tests for the Linux paste path against a real desktop. They run only inside the
// harness (scripts/linux/e2e/run.sh), which starts Xvfb or headless sway and sets
// VIZIER_E2E_DESKTOP to "x11" or "sway"; anywhere else they are skipped.

private let desktop = ProcessInfo.processInfo.environment["VIZIER_E2E_DESKTOP"]
private let outDirectory = ProcessInfo.processInfo.environment["E2E_OUT"] ?? "/tmp/e2e"

private func waitFor(_ seconds: Double = 8, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

private func read(_ name: String) -> Data { FileManager.default.contents(atPath: "\(outDirectory)/\(name)") ?? Data() }

@MainActor
@Suite(.enabled(if: desktop == "x11", "needs the x11 e2e desktop (VIZIER_E2E_DESKTOP=x11)"), .serialized)
struct AdapterE2EX11 {
    @Test func pasteLandsInATkTextBoxAndASecondPasteReplacesTheClipboard() async throws {
        let session = DesktopSession.detect()
        #expect(session.display == .x11)
        let plan = await DesktopRoutes.make(session: session)
        #expect(plan.senders.map(\.name) == ["xdotool"])
        #expect(plan.writers.map(\.name) == ["xclip", "xsel"])
        let paster = LinuxPaster(plan: plan, focus: FocusReaders.make(for: session))

        let first = "e2e x11 paste: ünïcode ✓ and 'quotes' $HOME"
        let outcome = await paster.paste(first, focusAtStop: nil, stillWanted: { true })
        #expect(outcome == PasteOutcome(kind: .pasted, method: "xdotool", reason: nil, onClipboard: true, permissionMissing: false, logCode: "xdotool"))
        let arrived1 = await waitFor { String(decoding: read("x11.out"), as: UTF8.self) == first }
        #expect(arrived1)

        let second = " + second"
        #expect(await paster.paste(second, focusAtStop: nil, stillWanted: { true }).kind == .pasted)
        let arrived2 = await waitFor { String(decoding: read("x11.out"), as: UTF8.self) == first + second }
        #expect(arrived2)
    }

    @Test func aWithdrawnPasteTypesNothingButLeavesTheTextOnTheClipboard() async throws {
        let session = DesktopSession.detect()
        let paster = LinuxPaster(plan: await DesktopRoutes.make(session: session), focus: FocusReaders.make(for: session))
        let before = read("x11.out")
        let outcome = await paster.paste("never typed", focusAtStop: nil, stillWanted: { false })
        #expect(outcome.kind == .withdrawn)
        #expect(outcome.onClipboard)
        try await Task.sleep(for: .milliseconds(500))
        #expect(read("x11.out") == before)
        // The text is on the clipboard: read it back with the real xclip.
        let readBack = try await ProcessRunner.run(["xclip", "-selection", "clipboard", "-out"])
        #expect(readBack.stdoutText == "never typed")
    }

    @Test func xselPublishesAndTheRealSelectionHoldsTheText() async throws {
        let writer = X11ClipboardWriter(tool: .xsel)
        try await writer.publish("via xsel: ünï")
        let readBack = try await ProcessRunner.run(["xclip", "-selection", "clipboard", "-out"])
        #expect(readBack.stdoutText == "via xsel: ünï")
        #expect(await writer.readBack(maxBytes: 64) == "via xsel: ünï")
    }
}

/// Sway runs two foot windows (A and B, each in raw mode writing what it receives to its own file);
/// the harness records their pids in footA.pid and footB.pid.
private func windowPid(_ name: String) -> Int32? {
    Int32(String(decoding: read(name), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

private func swaymsg(_ command: String) async throws {
    _ = try await ProcessRunner.run(["swaymsg", command], timeout: .seconds(5))
}

private func focus(pid: Int32, reader: FocusReader) async throws -> Bool {
    try await swaymsg("[pid=\(pid)] focus")
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await reader.focusedWindow()?.pid == pid { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// Waits for `file` to equal `expected` exactly, then again after a settle interval: nothing more arrives.
private func expectExactlyThenStable(_ file: String, _ expected: Data, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let arrived = await waitFor { read(file) == expected }
    #expect(arrived, "\(file) did not become exactly the expected bytes", sourceLocation: sourceLocation)
    try await Task.sleep(for: .milliseconds(700))
    #expect(read(file) == expected, "\(file) changed after the settle interval", sourceLocation: sourceLocation)
}

@MainActor
@Suite(.enabled(if: desktop == "sway", "needs the sway e2e desktop (VIZIER_E2E_DESKTOP=sway)"), .serialized)
struct AdapterE2ESway {
    @Test func swayFocusIsReadAndFootIsATerminal() async throws {
        let session = DesktopSession.detect()
        #expect(session.display == .wayland)
        #expect(session.family == .wlroots)
        let reader = FocusReaders.make(for: session)
        let a = try #require(windowPid("footA.pid"))
        #expect(try await focus(pid: a, reader: reader))
        let window = await reader.focusedWindow()
        #expect(window?.appName == "foot")
        #expect(window?.isTerminal == true)
        #expect(window?.pid == a)
    }

    @Test func wtypeChordsReachTheFocusedWindowExactly() async throws {
        let session = DesktopSession.detect()
        let sender = WtypeKeySender(session: session)
        #expect(await sender.probe().available)
        let a = try #require(windowPid("footA.pid"))
        #expect(try await focus(pid: a, reader: FocusReaders.make(for: session)))
        let before = read("foot.out")
        try await sender.send(.ctrlV)
        // Ctrl+V in a raw terminal is the single byte 0x16, and nothing else follows.
        try await expectExactlyThenStable("foot.out", before + Data([0x16]))
    }

    @Test func pasteIntoTheTerminalUsesCtrlShiftVAndExactlyTheTextArrives() async throws {
        let session = DesktopSession.detect()
        let plan = await DesktopRoutes.make(session: session)
        #expect(plan.senders.map(\.name) == ["wtype"])
        #expect(plan.writers.map(\.name) == ["wl-copy"])
        let reader = FocusReaders.make(for: session)
        let a = try #require(windowPid("footA.pid"))
        #expect(try await focus(pid: a, reader: reader))
        let paster = LinuxPaster(plan: plan, focus: reader)

        let text = "e2e sway paste: ünïcode ✓ no newline"
        let before = read("foot.out")
        let atStop = await reader.focusedWindow()?.pid
        let outcome = await paster.paste(text, focusAtStop: atStop, stillWanted: { true })
        #expect(outcome == PasteOutcome(kind: .pasted, method: "wtype", reason: nil, onClipboard: true, permissionMissing: false, logCode: "wtype"))
        // Ctrl+Shift+V is foot's paste binding; a plain Ctrl+V would have added only a 0x16 byte. The
        // appended bytes are the text and nothing else, now and after a settle interval.
        try await expectExactlyThenStable("foot.out", before + Data(text.utf8))
    }

    @Test func aFocusMoveBetweenStopAndPasteHoldsTheTextAndDeliversNothing() async throws {
        let session = DesktopSession.detect()
        let reader = FocusReaders.make(for: session)
        let a = try #require(windowPid("footA.pid"))
        let b = try #require(windowPid("footB.pid"))
        #expect(a != b)
        // The take stopped with window A focused; the user then moved to window B.
        #expect(try await focus(pid: a, reader: reader))
        let atStop = await reader.focusedWindow()?.pid
        #expect(atStop == a)
        #expect(try await focus(pid: b, reader: reader))
        let paster = LinuxPaster(plan: await DesktopRoutes.make(session: session), focus: reader)
        let beforeA = read("foot.out"), beforeB = read("foot2.out")
        let outcome = await paster.paste("held text", focusAtStop: atStop, stillWanted: { true })
        #expect(outcome.kind == .held)
        #expect(outcome.reason == PasteDecision.focusMoved)
        #expect(outcome.onClipboard)
        try await Task.sleep(for: .milliseconds(700))
        #expect(read("foot.out") == beforeA)
        #expect(read("foot2.out") == beforeB)
        _ = try await focus(pid: a, reader: reader)
    }
}
