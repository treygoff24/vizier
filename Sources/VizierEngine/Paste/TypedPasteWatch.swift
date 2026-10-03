/// Notes a Cmd+V typed on the keyboard near a take's own paste, for the log. It never blocks one.
///
/// A double paste can come from another dictation app on the same hotkey pasting its own copy;
/// this note, logged for every typed Cmd+V within a few seconds of a stop, makes that visible.
/// Vizier's own Cmd+V is recognized by its event tag and never reaches this.
public struct TypedPasteWatch: Sendable {
    /// A typed Cmd+V this long after the stop tap is ordinary typing, not worth a line.
    public static let window: Double = 5

    public private(set) var stoppedAt: Double?
    public private(set) var pastedAt: Double?

    public init() {}

    /// `time` is seconds on any monotonic clock shared by every call.
    public mutating func takeStopped(at time: Double) {
        stoppedAt = time
        pastedAt = nil
    }

    public mutating func pasted(at time: Double) {
        pastedAt = time
    }

    /// The take ended without Vizier's paste; a typed Cmd+V after it is how the text gets out.
    public mutating func endedWithoutPaste() {
        stoppedAt = nil
        pastedAt = nil
    }

    /// The log line for a Cmd+V typed at `time`, or nil when it is not near a take's paste.
    public func note(at time: Double) -> String? {
        guard let stoppedAt, time >= stoppedAt, time - stoppedAt < Self.window else { return nil }
        let sincePaste = pastedAt.map { "\(Self.ms(time - $0)) ms after Vizier's paste" } ?? "before Vizier's paste"
        return "typed Cmd+V \(Self.ms(time - stoppedAt)) ms after the stop tap, \(sincePaste)"
    }

    private static func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
}
