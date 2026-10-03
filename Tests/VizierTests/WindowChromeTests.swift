import AppKit
import VizierEngine
import SwiftUI
import Testing
@testable import Vizier

@Observable private final class PaneHeight {
    var height: CGFloat = 300
}

private struct PaneStandIn: View {
    var pane: PaneHeight
    var body: some View { Color.clear.frame(width: 640, height: pane.height) }
}

@Suite struct ShellWindowTests {
    /// Settings changes height with its pane. The window must take the new height from its top
    /// edge, so the tabs stay under the pointer.
    @Test @MainActor func aTallerPaneGrowsTheWindowDownwardWithItsTopEdgeStill() throws {
        _ = NSApplication.shared
        let pane = PaneHeight()
        let sizer = WindowSizer()
        sizer.visibleFrame = { _ in NSRect(x: 0, y: 0, width: 2560, height: 1400) }
        let controller = ShellWindowController(title: "Test", autosaveName: "", content: PaneStandIn(pane: pane), sizer: sizer)
        let window = try #require(controller.window)
        #expect(window.frame.size == CGSize(width: 640, height: 300))
        let top = window.frame.maxY, left = window.frame.minX

        pane.height = 420
        for _ in 0..<100 where window.frame.height != 420 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(window.frame.height == 420)
        #expect(window.frame.maxY == top)
        #expect(window.frame.minX == left)
    }

    /// A mode list longer than the screen, shown in a window sitting low on it: the window stops at
    /// the screen's visible frame, moves up rather than run off the bottom, and the pane scrolls.
    @Test @MainActor func aLongModeListNearTheScreenBottomKeepsTheWindowOnScreen() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appending(path: "vizier-window-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ConfigStore(directory: dir)
        let modes = (1...30).map {
            #"{ "id": "m\#($0)", "name": "Mode \#($0)", "transcriber": { "engine": "gemini-batch", "model": "gemini-3.5-transcribe", "mode": "verbatim", "languages": ["en"], "final_timeout_ms": 5000 } }"#
        }
        try Data(#"{ "mode": "m1", "modes": [\#(modes.joined(separator: ",\n"))] }"#.utf8).write(to: config.settingsURL)
        let suite = "vizier-window-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsModel(
            preferences: AppPreferences(defaults: defaults), config: config, speech: SpeechModelModel(source: FakeSpeechModelSource(status: .installed)),
            accounts: [], loginItem: FakeLoginItem(state: .off))
        try #require(model.modePicker.modes.count == 30, "\(model.modePicker.note ?? "no note")")

        let screen = NSRect(x: 0, y: 0, width: 1440, height: 700)
        let sizer = WindowSizer()
        sizer.visibleFrame = { _ in screen }
        let controller = ShellWindowController(title: "Test", autosaveName: "", content: SettingsView(model: model), sizer: sizer)
        let window = try #require(controller.window)
        settle(window)
        // The General pane fits; park the window near the bottom of the screen, then open the list.
        try #require(window.frame.height < 500)
        window.setFrameOrigin(NSPoint(x: 100, y: 40))
        model.pane = .transcription
        settle(window)

        let room = screen.insetBy(dx: 0, dy: WindowChrome.screenMargin)
        #expect(window.frame.height == room.height)
        #expect(window.frame.minY >= room.minY)
        #expect(window.frame.maxY <= room.maxY)
        #expect(window.frame.minX == 100)
    }

    @MainActor private func settle(_ window: NSWindow) {
        for _ in 0..<40 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
