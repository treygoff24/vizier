import Foundation

// The take session's contracts. The engine's take
// session implements `TakeControl`; the macOS app and the Linux daemon supply the adapters below.
// The daemon talks only to `TakeControl`, so it can be built and tested against a fake. Changing a
// declaration here means updating every consumer before merge.

/// Where a take is in its life.
public enum TakePhase: String, Codable, Sendable, Equatable {
    case idle, arming, recording, finalizing
}

/// How a take ended, as the board and the daemon report it. (History keeps its own finer
/// `TakeOutcome`, which also has the in-progress states.)
public enum TakeResult: Codable, Sendable, Equatable {
    case pasted
    case rerouted(TakeRoute)
    case held
    case failed
    case cancelled
}

/// Why a take that pasted took another road than its mode's normal one.
public enum TakeRoute: String, Codable, Sendable, Equatable {
    case batch, rawText
}

/// The end of the most recent take, without its text.
public struct TakeEnding: Codable, Sendable, Equatable {
    public var takeID: String
    public var result: TakeResult
    /// The board's remark: one sentence of fact about the outcome, never transcript text.
    public var remark: String?
    public var endedAt: Date

    public init(takeID: String, result: TakeResult, remark: String?, endedAt: Date) {
        self.takeID = takeID
        self.result = result
        self.remark = remark
        self.endedAt = endedAt
    }
}

/// A snapshot of the session. Carries no transcript text and no audio.
public struct TakeStatus: Codable, Sendable, Equatable {
    public var phase: TakePhase
    /// The take in progress (arming, recording or finalizing); nil when idle.
    public var takeID: String?
    /// Audio captured so far in the take in progress, in seconds; 0 when idle.
    public var seconds: Double
    /// The active mode's id from the config.
    public var mode: String
    /// The last take that ended since the session started.
    public var lastEnding: TakeEnding?

    public init(phase: TakePhase, takeID: String?, seconds: Double, mode: String, lastEnding: TakeEnding?) {
        self.phase = phase
        self.takeID = takeID
        self.seconds = seconds
        self.mode = mode
        self.lastEnding = lastEnding
    }
}

/// Why a command was refused. The raw value is the stable code the socket protocol carries.
public enum TakeCommandError: String, Error, Codable, Sendable, Equatable {
    /// `start` while a take is arming or recording.
    case alreadyRecording = "already_recording"
    /// `stop` or `cancel` with no take in progress.
    case notRecording = "not_recording"
    /// `start`, `stop` or `toggle` while the last take is still being transcribed and delivered.
    case busyFinalizing = "busy_finalizing"
    /// A command before the session finished starting (recovery of crashed takes still running),
    /// and `start` or `toggle` after `quiesce` began (the session is shutting down).
    case startupNotReady = "startup_not_ready"
}

/// What a hotkey, the CLI or a test drives. Every command returns at once with a snapshot taken
/// after it was applied: `stop` does not wait for transcription or delivery, and `status`
/// reports them. A refused command changes nothing.
@MainActor
public protocol TakeControl: AnyObject {
    /// Starts a take when idle, stops it when arming or recording; `busyFinalizing` otherwise.
    func toggle() throws(TakeCommandError) -> TakeStatus
    func start() throws(TakeCommandError) -> TakeStatus
    func stop() throws(TakeCommandError) -> TakeStatus
    /// Cancels the take in progress, finalizing included. Its audio is kept.
    func cancel() throws(TakeCommandError) -> TakeStatus
    func status() -> TakeStatus
    /// Winds the session down for shutdown (the daemon's SIGTERM): from now on `start` and
    /// `toggle` are refused; a take that is arming or recording is stopped, not cancelled, so
    /// its audio is saved and it is delivered like any other; a take that is finalizing is
    /// allowed to finish its delivery. Waits for the in-flight delivery and audio saves up to
    /// `deadline`, and returns true when nothing is left in flight. `cancel()` still works.
    func quiesce(until deadline: ContinuousClock.Instant) async -> Bool
}

// MARK: - Adapters the session calls

/// Everything the user sees of a take: the Mac's status item and strip, the daemon's
/// notifications and status. Called on the main actor, in take order.
@MainActor
public protocol TakePresentation: AnyObject {
    func phaseChanged(_ phase: TakePhase)
    /// Something needs attention (a config error, a missing key, a failed take).
    func raiseAlert()
    /// A take started. `level` and `seconds` may be polled from any thread.
    func begin(destination: String, platform: String, level: @escaping @Sendable () -> Float, seconds: @escaping @Sendable () -> Double)
    /// The first real audio arrived.
    func setLive()
    func setWords(_ plates: [WordLine.Plate])
    func streamLost(remark: String)
    /// The take stopped; delivery is on time if it lands within `onTime` seconds.
    func stopped(onTime: TimeInterval)
    func reroutingToBatch()
    func finish(_ result: TakeResult, remark: String?)
}

public enum TakeSound: String, Sendable, CaseIterable {
    case start, stop, problem, cancel
}

@MainActor
public protocol SoundPlayer: AnyObject {
    func play(_ sound: TakeSound)
}

@MainActor
public protocol MicPermission: AnyObject {
    /// True only when the user has refused microphone access; not-yet-asked is false.
    func microphoneDenied() -> Bool
}

@MainActor
public protocol FocusProbe: AnyObject {
    /// The focused app's name for the board and history, or "" when unknown.
    func destinationName() -> String
    /// The focused app's process id at the stop, or nil when the platform cannot tell.
    func focusedProcess() -> Int32?
    /// The focused app's process id at the moment of the stop, read fresh (a platform whose
    /// `focusedProcess()` is a cached answer reads again here). Defaults to `focusedProcess()`.
    func focusAtStop() async -> Int32?
}

extension FocusProbe {
    public func focusAtStop() async -> Int32? { focusedProcess() }
}

/// What became of a paste. The clipboard and the keystroke are recorded apart (amendment A16):
/// a remark says the text is on the clipboard only when `onClipboard` is true.
public struct PasteOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The paste keystroke (or its platform equivalent) went out.
        case pasted
        /// The take was cancelled during the pre-paste pause; nothing went out.
        case withdrawn
        /// Nowhere safe to paste (a password field, focus moved, no target); nothing went out.
        case held
        /// The paste was attempted or prepared and failed.
        case failed
    }

    public var kind: Kind
    /// For `.pasted`, how: "keystroke", "AppleScript", "portal", "wtype", "xdotool", "ydotool".
    /// History records it as the paste method.
    public var method: String
    /// For `.held` and `.failed`, why. May name the focused app, so it stays out of public logs;
    /// held reasons use the `PasteDecision` constants.
    public var reason: String?
    /// The text was published to the clipboard and is still there.
    public var onClipboard: Bool
    /// The paste could not run because a platform permission is missing (macOS Accessibility).
    public var permissionMissing: Bool
    /// A fixed code for public logs: "keystroke", "held-focus-moved", "failed", and so on.
    public var logCode: String

    public init(kind: Kind, method: String, reason: String?, onClipboard: Bool, permissionMissing: Bool, logCode: String) {
        self.kind = kind
        self.method = method
        self.reason = reason
        self.onClipboard = onClipboard
        self.permissionMissing = permissionMissing
        self.logCode = logCode
    }
}

@MainActor
public protocol PasteService: AnyObject {
    /// Pastes `text` into the app that had focus at the stop. `stillWanted` is checked just
    /// before the keystroke; false withdraws the paste.
    func paste(_ text: String, focusAtStop: Int32?, stillWanted: @escaping @MainActor () -> Bool) async -> PasteOutcome
}
