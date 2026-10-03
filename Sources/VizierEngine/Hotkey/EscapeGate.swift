/// Decides, for each Escape key event, whether Vizier swallows it.
///
/// One Escape cancels a take that is recording or finalizing, and the app underneath never sees
/// that press. Every Escape in the guard window after it is swallowed too, so mashing Escape to be
/// sure cannot leak presses into the terminal. The window runs from the canceling press and does
/// not slide, so mashing cannot extend it indefinitely. A held key that started swallowed stays
/// swallowed through its autorepeats and its release. Otherwise Escape passes through untouched.
public struct EscapeGate: Sendable {
    /// A constant, not a config setting.
    public static let guardWindow: Double = 1.0

    public enum Decision: Equatable, Sendable {
        case pass
        case swallow
        case swallowAndCancel
    }

    private var guardUntil = -Double.infinity
    private var swallowingHeldKey = false

    public init() {}

    /// `time` is seconds on any monotonic clock shared by every call.
    public mutating func keyDown(at time: Double, isRepeat: Bool, takeIsCancelable: Bool) -> Decision {
        if (isRepeat && swallowingHeldKey) || time < guardUntil {
            swallowingHeldKey = true
            return .swallow
        }
        if takeIsCancelable {
            guardUntil = time + Self.guardWindow
            swallowingHeldKey = true
            return .swallowAndCancel
        }
        swallowingHeldKey = false
        return .pass
    }

    /// A release is swallowed exactly when its press was, so no app sees half a keystroke.
    public mutating func keyUp() -> Decision {
        defer { swallowingHeldKey = false }
        return swallowingHeldKey ? .swallow : .pass
    }
}
