import AppKit
@testable import VizierEngine
import Foundation
import Testing
@testable import Vizier

@Suite struct AppPreferencesTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "vizier-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func aFreshStoreHasTheDocumentedDefaults() {
        let (store, name) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: store)
        #expect(preferences.hotkey == .rightCommand)
        #expect(preferences.showInDock == false)
        #expect(preferences.soundsEnabled == true)
        #expect(preferences.onboardingDone == false)
    }

    @Test func everySettingSurvivesANewInstanceOverTheSameStore() {
        let (store, name) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        let first = AppPreferences(defaults: store)
        first.hotkey = .rightOption
        first.showInDock = true
        first.soundsEnabled = false
        first.onboardingDone = true
        let second = AppPreferences(defaults: store)
        #expect(second.hotkey == .rightOption)
        #expect(second.showInDock == true)
        #expect(second.soundsEnabled == false)
        #expect(second.onboardingDone == true)
    }

    @Test func anUnrecognisedSavedHotkeyFallsBackToRightCommand() {
        let (store, name) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        store.set("leftShift", forKey: AppPreferences.Key.hotkey)
        #expect(AppPreferences(defaults: store).hotkey == .rightCommand)
    }

    @Test func aChangeIsAnnouncedOnceAndASameValueWriteIsNot() {
        let (store, name) = defaults()
        defer { store.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: store)
        var seen: [AppPreferences.Setting] = []
        preferences.didChange = { seen.append($0) }
        preferences.hotkey = .rightControl
        preferences.hotkey = .rightControl
        preferences.showInDock = true
        #expect(seen == [.hotkey, .showInDock])
    }
}

@Suite struct DockPolicyTests {
    // The activation-policy rule: a dock icon while any window is open or Show in Dock is on.
    @Test(arguments: [
        (0, false, NSApplication.ActivationPolicy.accessory),
        (1, false, .regular),
        (3, false, .regular),
        (0, true, .regular),
        (2, true, .regular),
    ])
    func windowsOpenAndShowInDockDecideThePolicy(openWindows: Int, showInDock: Bool, expected: NSApplication.ActivationPolicy) {
        #expect(DockPolicy.activationPolicy(openWindows: openWindows, showInDock: showInDock) == expected)
    }

    private func facts(_ id: Int, titled: Bool = true, panel: Bool = false, visible: Bool = true, miniaturized: Bool = false) -> DockPolicy.WindowFacts {
        DockPolicy.WindowFacts(id: ObjectIdentifier(Self.tokens[id]), isTitled: titled, isPanel: panel, isVisible: visible, isMiniaturized: miniaturized)
    }
    private static let tokens = (0..<6).map { _ in NSObject() }

    @Test func onlyTitledNonPanelWindowsThatAreUpCountAsOpen() {
        let windows = [
            facts(0),                          // Settings, on screen
            facts(1, visible: false, miniaturized: true), // History, minimized to the dock
            facts(2, panel: true),             // the popover
            facts(3, titled: false),           // the strip
            facts(4, visible: false),          // closed
        ]
        #expect(DockPolicy.openWindowCount(windows) == 2)
    }

    @Test func theWindowThatIsClosingIsLeftOut() {
        let windows = [facts(0), facts(1)]
        #expect(DockPolicy.openWindowCount(windows, excluding: windows[0].id) == 1)
        #expect(DockPolicy.openWindowCount([windows[0]], excluding: windows[0].id) == 0)
    }

    private func controller(showInDock: Bool, windows: @escaping () -> [DockPolicy.WindowFacts], applied: Box) -> DockController {
        let name = "vizier-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        let preferences = AppPreferences(defaults: store)
        preferences.showInDock = showInDock
        return DockController(preferences: preferences, windows: windows, apply: { applied.policies.append($0) }, activate: { applied.activations += 1 })
    }

    final class Box {
        var policies: [NSApplication.ActivationPolicy] = []
        var activations = 0
    }

    @Test func openingAWindowShowsTheDockIconAndClosingTheLastHidesIt() {
        let applied = Box()
        var open: [DockPolicy.WindowFacts] = []
        let dock = controller(showInDock: false, windows: { open }, applied: applied)
        dock.refresh()
        #expect(applied.policies.isEmpty) // already accessory: nothing to change
        open = [facts(0)]
        dock.refresh()
        #expect(applied.policies == [.regular])
        #expect(applied.activations == 1)
        // The close notification arrives while the window is still visible.
        dock.refresh(excluding: facts(0).id)
        #expect(applied.policies == [.regular, .accessory])
    }

    @Test func showInDockKeepsTheIconWithNoWindowOpen() {
        let applied = Box()
        let dock = controller(showInDock: true, windows: { [] }, applied: applied)
        dock.refresh()
        #expect(applied.policies == [.regular])
        #expect(applied.activations == 0) // nothing to bring forward
    }

    @Test func refreshingWithNothingChangedDoesNotReapplyThePolicy() {
        let applied = Box()
        let dock = controller(showInDock: false, windows: { [self.facts(0)] }, applied: applied)
        dock.refresh()
        dock.refresh()
        #expect(applied.policies == [.regular])
    }
}
