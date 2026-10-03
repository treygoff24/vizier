/// Whether a paste has somewhere to land. Vizier asks the frontmost app for its focused UI element
/// just before posting Cmd+V. Many ordinary apps with windows (Safari, Electron apps) answer "no
/// focused element" or time out even when a paste would work, so a failed focus query holds the
/// take only when the app also looks like a background helper: not a regular app, or a regular app
/// that reported zero windows. The case this guards against, a windowless accessory helper that took focus,
/// holds; role, editability, and window are never required for a paste.
///
/// A secure text field (subrole `AXSecureTextField`) always holds: dictated text must never be
/// typed into a password field. Secure event input holds only when the focused element could not
/// be read. It is system-wide, and terminals turn it on for long stretches (Terminal's and iTerm's
/// Secure Keyboard Entry, Ghostty around password prompts), so holding whenever it is on would hold
/// every paste into them. When the focused element can be read and is not a secure field, Vizier
/// knows where the text is going; when it cannot be read, secure input is the only sign that a
/// password field the app does not describe may have focus. Editability is still never required;
/// on this Mac many apps do not report it.
public struct PasteTargetFacts: Sendable, Equatable {
    /// The focused-element query on the frontmost app's accessibility element.
    public enum FocusQuery: Sendable, Equatable {
        /// `subrole` is `AXSecureTextField` for a password field; nil when the app did not say.
        case element(role: String?, subrole: String? = nil)
        case noValue
        /// An AXError raw value other than success or no-value (timeouts and cannot-complete).
        case error(Int32)
    }

    public var frontmostApp: Bool
    public var bundleID: String?
    public var focus: FocusQuery
    /// The app's activation policy is `.regular` (a Dock app), not accessory or prohibited.
    public var isRegularApp: Bool
    /// Windows the app reported; nil when the windows query failed or was not made.
    public var windowCount: Int?
    /// Process ids of the frontmost app now and of the app that was frontmost when the take
    /// stopped. Both known and different means the user moved on while the text was being made.
    public var frontmostPID: Int32?
    public var pidAtStop: Int32?
    /// `IsSecureEventInputEnabled()`: some process (a password field, a terminal's secure
    /// keyboard entry) has asked that keystrokes not be observed.
    public var secureEventInput: Bool

    public init(frontmostApp: Bool, bundleID: String?, focus: FocusQuery, isRegularApp: Bool, windowCount: Int?,
                frontmostPID: Int32? = nil, pidAtStop: Int32? = nil, secureEventInput: Bool = false) {
        self.secureEventInput = secureEventInput
        self.frontmostPID = frontmostPID
        self.pidAtStop = pidAtStop
        self.frontmostApp = frontmostApp
        self.bundleID = bundleID
        self.focus = focus
        self.isRegularApp = isRegularApp
        self.windowCount = windowCount
    }
}

public enum PasteDecision: Sendable, Equatable {
    case paste
    case hold(reason: String)

    /// Vizier's own bundle id. With a Vizier window focused (History's search field, say), a paste
    /// would land in Vizier, so the take is held on the clipboard instead.
    public static let vizierBundleID = "net.praxient.dictum"
    public static let vizierHadFocus = "Vizier itself had focus"
    /// The same reason as history rows recorded it before the rename (Vizier was called Dictum until
    /// 2026-10-03). Only read, to explain those rows; never written.
    public static let legacyDictumHadFocus = "Dictum itself had focus"
    public static let focusMoved = "you switched apps after the take stopped"
    public static let secureField = "a password field had focus"
    public static let secureInput = "secure input was on and the focused field could not be read"
    public static let secureSubrole = "AXSecureTextField"

    /// The secure-input checks, shared by `decide` and `finalCheck`. A readable focused element
    /// decides on its subrole alone; secure event input counts only when the focus is unreadable
    /// (no element, a failed query, or, in the final check, not read again).
    static func secureHold(focus: PasteTargetFacts.FocusQuery?, secureEventInput: Bool) -> PasteDecision? {
        if case .element(_, let subrole)? = focus {
            return subrole == secureSubrole ? .hold(reason: secureField) : nil
        }
        if secureEventInput { return .hold(reason: secureInput) }
        return nil
    }

    /// The last look, just before the keystroke: the user may have switched apps or moved focus
    /// into a password field during the pause. `focus` is nil when it could not be read again,
    /// which does not hold the paste on its own.
    public static func finalCheck(frontmostPID: Int32?, pidAtStop: Int32?, focus: PasteTargetFacts.FocusQuery?, secureEventInput: Bool) -> PasteDecision {
        if let hold = secureHold(focus: focus, secureEventInput: secureEventInput) { return hold }
        if focusMoved(now: frontmostPID, atStop: pidAtStop) { return .hold(reason: focusMoved) }
        return .paste
    }

    /// True when the frontmost app is not the one that was frontmost at the stop tap.
    public static func focusMoved(now: Int32?, atStop: Int32?) -> Bool {
        guard let now, let atStop else { return false }
        return now != atStop
    }

    public static func decide(_ facts: PasteTargetFacts) -> PasteDecision {
        guard facts.frontmostApp else { return .hold(reason: "no frontmost app") }
        if let hold = secureHold(focus: facts.focus, secureEventInput: facts.secureEventInput) { return hold }
        if facts.bundleID == vizierBundleID { return .hold(reason: vizierHadFocus) }
        if focusMoved(now: facts.frontmostPID, atStop: facts.pidAtStop) { return .hold(reason: focusMoved) }
        let app = facts.bundleID ?? "an app with no bundle id"
        let failure: String
        switch facts.focus {
        case .element: return .paste
        case .noValue: failure = "no focused element"
        case .error(let code): failure = "focus query failed (\(code))"
        }
        if !facts.isRegularApp { return .hold(reason: "\(failure) in \(app), a background app") }
        if facts.windowCount == 0 { return .hold(reason: "\(failure) and no windows in \(app)") }
        return .paste
    }
}
