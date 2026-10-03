import Foundation

/// The first-run walk: welcome, the two permissions, the speech model, the hotkey, an optional key,
/// and a practice take. Every step can be skipped; the primary button says "Continue" once a step
/// is satisfied and "Skip this step" until then.
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, speechModel, hotkey, accuracy, practice

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
            case .speechModel: "Speech model"
            case .hotkey: "Hotkey"
            case .accuracy: "Higher accuracy"
            case .practice: "Practice"
            }
        }
    }

    var step: Step = .welcome {
        didSet {
            guard (step == .practice) != (oldValue == .practice) else { return }
            if step == .practice { armPractice() } else { disarmPractice() }
        }
    }
    /// The text of the last practice take, delivered by the take pipeline. Typing in the window
    /// cannot set it, so it only ever means a real take happened.
    private(set) var practiceResult: String?
    /// Installs or removes the take pipeline's practice sink. Armed only while the Practice step
    /// is showing, so a take made anywhere else pastes as usual.
    var setPracticeSink: (((String) -> Void)?) -> Void = { _ in }
    let permissions: PermissionsModel
    let speech: SpeechModelModel
    let preferences: AppPreferences
    let accounts: [AccountKeyModel]
    /// Called when the walk ends, by finishing or by skipping out; the window closes.
    var onFinish: () -> Void = {}
    /// Called when Accessibility turns on while its step is showing, which happens in System
    /// Settings: the shell brings the window back so the person sees it worked.
    var onAccessibilityGranted: () -> Void = {}

    init(permissions: PermissionsModel, speech: SpeechModelModel, preferences: AppPreferences, accounts: [AccountKeyModel]) {
        self.permissions = permissions
        self.speech = speech
        self.preferences = preferences
        self.accounts = accounts
    }

    var isFirst: Bool { step == .welcome }
    var isLast: Bool { step == Step.allCases.last }
    var position: String { "STEP \(step.rawValue + 1) OF \(Step.allCases.count)" }

    /// Whether the step has what it needs, so the primary button can say "Continue". A key is
    /// optional and the practice take is not required, so those are always satisfied.
    var isSatisfied: Bool {
        switch step {
        case .welcome, .hotkey, .accuracy: true
        case .practice: practiceResult != nil
        case .microphone: permissions.microphone == .granted
        case .accessibility: permissions.accessibility
        case .speechModel: speech.isInstalled || speech.state == .unsupported
        }
    }

    func next() {
        if isLast {
            finish()
        } else if let following = Step(rawValue: step.rawValue + 1) {
            step = following
        }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    /// Ends onboarding for good: it will not open by itself again.
    func finish() {
        disarmPractice()
        preferences.onboardingDone = true
        onFinish()
    }

    /// Re-reads both permissions. Accessibility has no grant callback, and the Microphone can be
    /// switched in System Settings too, so the window calls this once a second while it is up.
    func pollPermissions() {
        let had = permissions.accessibility
        permissions.refresh()
        if !had, permissions.accessibility, step == .accessibility { onAccessibilityGranted() }
    }

    /// The window closed: stop routing takes here.
    func windowClosed() { disarmPractice() }

    private func armPractice() {
        practiceResult = nil
        setPracticeSink { [weak self] text in self?.practiceResult = text }
    }

    private func disarmPractice() { setPracticeSink(nil) }
}

enum OnboardingPolicy {
    /// An install from before onboarding existed has takes in its history; a fresh Mac has none.
    /// Permissions alone are not evidence, since a new user may grant both and quit before the
    /// speech model step. With no readable history there is no evidence either.
    static func isExistingUser(takeCount: Int?) -> Bool { (takeCount ?? 0) > 0 }

    /// Whether the guide should open by itself at launch.
    static func shouldOfferAtLaunch(onboardingDone: Bool, takeCount: Int?) -> Bool {
        !onboardingDone && !isExistingUser(takeCount: takeCount)
    }
}
