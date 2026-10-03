import VizierEngine
import Foundation

/// Per-user app preferences: the hotkey, Show in Dock, sounds, and whether onboarding is done.
/// They live in `UserDefaults` because they are app state, not dictation config: `vizier.jsonc`
/// keeps modes and engines, and the settings window edits only its selected `mode`.
///
/// The store is injected, so tests and the `--render-ui` command never touch the real defaults.
@Observable
final class AppPreferences {
    enum Setting: Equatable { case hotkey, showInDock, soundsEnabled, onboardingDone }

    enum Key {
        static let hotkey = "hotkeyModifier"
        static let showInDock = "showInDock"
        static let soundsEnabled = "soundsEnabled"
        static let onboardingDone = "onboardingDone"
    }

    /// The real defaults, for the running app only.
    static let standard = AppPreferences(defaults: .standard)

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after a setting changes and is saved, with which one.
    @ObservationIgnored var didChange: (Setting) -> Void = { _ in }

    var hotkey: HotkeyModifier {
        didSet { if hotkey != oldValue { defaults.set(hotkey.rawValue, forKey: Key.hotkey); didChange(.hotkey) } }
    }
    var showInDock: Bool {
        didSet { if showInDock != oldValue { defaults.set(showInDock, forKey: Key.showInDock); didChange(.showInDock) } }
    }
    var soundsEnabled: Bool {
        didSet { if soundsEnabled != oldValue { defaults.set(soundsEnabled, forKey: Key.soundsEnabled); didChange(.soundsEnabled) } }
    }
    var onboardingDone: Bool {
        didSet { if onboardingDone != oldValue { defaults.set(onboardingDone, forKey: Key.onboardingDone); didChange(.onboardingDone) } }
    }

    /// Reads the saved values. A missing or unrecognised hotkey is Right Command; sounds are on
    /// until turned off; Show in Dock and onboarding-done start false.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        hotkey = defaults.string(forKey: Key.hotkey).flatMap(HotkeyModifier.init(rawValue:)) ?? .rightCommand
        showInDock = defaults.bool(forKey: Key.showInDock)
        soundsEnabled = defaults.object(forKey: Key.soundsEnabled) as? Bool ?? true
        onboardingDone = defaults.bool(forKey: Key.onboardingDone)
    }
}
