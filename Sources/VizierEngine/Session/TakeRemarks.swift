import Foundation

/// The board's remarks: one plain sentence of fact each, never transcript text. The sentences that
/// name a platform (where to add a key, where to grant a permission, how to paste by hand) come
/// from the table the platform supplies; the rest are shared. `TakeRemarks.mac` reproduces the
/// macOS app's strings byte for byte. A remark says "on the clipboard" only when the paste outcome
/// says the clipboard holds the text (amendment A16); otherwise it points to the platform's way
/// of reading the history text.
public struct TakeRemarks: Sendable, Equatable {
    // MARK: Platform wording

    /// The sentence after "There is no <name> key yet, so nothing was transcribed." naming where to add one.
    public var addKeyHint: String
    public var speechModelMissing: String
    /// A cloud engine could not be reached and the local one answered.
    public var offline: String
    public var micDenied: String
    /// "The paste did not go through." and the like, without the clipboard sentence.
    public var pasteFailedBase: String
    /// A paste that failed because a platform permission is missing, without the clipboard sentence.
    public var permissionMissingBase: String
    /// Appended to a held or failed paste's remark when the text is on the clipboard.
    public var clipboardSuffix: String
    /// Appended when it is not: the text is in history, and the platform says how to read it.
    public var noClipboardSuffix: String

    public init(
        addKeyHint: String, speechModelMissing: String, offline: String, micDenied: String,
        pasteFailedBase: String, permissionMissingBase: String, clipboardSuffix: String, noClipboardSuffix: String
    ) {
        self.addKeyHint = addKeyHint
        self.speechModelMissing = speechModelMissing
        self.offline = offline
        self.micDenied = micDenied
        self.pasteFailedBase = pasteFailedBase
        self.permissionMissingBase = permissionMissingBase
        self.clipboardSuffix = clipboardSuffix
        self.noClipboardSuffix = noClipboardSuffix
    }

    /// The macOS app's wording, as it has always read.
    public static let mac = TakeRemarks(
        addKeyHint: "Add one in Settings › Accounts.",
        speechModelMissing: "The Apple speech model is not ready (it may still be downloading), so nothing was transcribed. Get it in Settings › Transcription › Download speech model. The audio is saved.",
        offline: "The cloud could not be reached, so this Mac transcribed the saved audio.",
        micDenied: "Vizier does not have microphone access, so nothing was recorded. Turn it on in System Settings › Privacy & Security › Microphone.",
        pasteFailedBase: "The paste did not go through.",
        permissionMissingBase: "Vizier does not have Accessibility access, so nothing was pasted. Turn it on in System Settings › Privacy & Security › Accessibility.",
        clipboardSuffix: " The text is on the clipboard; ⌘V pastes it.",
        noClipboardSuffix: " The text is saved in History.")

    /// The Linux wording. There is no Apple speech model on Linux, so that sentence is never used.
    public static let linux = TakeRemarks(
        addKeyHint: "Add one with `vizier key set <name>`.",
        speechModelMissing: "The speech model is not ready, so nothing was transcribed. The audio is saved.",
        offline: "The cloud could not be reached, so this computer transcribed the saved audio.",
        micDenied: "Vizier does not have microphone access, so nothing was recorded. Allow it in your desktop's privacy settings.",
        pasteFailedBase: "The paste did not go through.",
        permissionMissingBase: "Vizier is not allowed to send keystrokes, so nothing was pasted. Run `vizier doctor` to see what is missing.",
        clipboardSuffix: " The text is on the clipboard; Ctrl+V pastes it.",
        noClipboardSuffix: " The text is saved in history; `vizier last` prints it.")

    // MARK: Shared sentences

    public static let streamDroppedRecording = "The live stream dropped. Audio is still recording and will go through batch when you stop."
    public static let streamDroppedNoBatch = "The live stream dropped. Audio is still recording and will be saved when you stop."
    public static let streamDropped = "The live stream dropped, so the saved audio went through batch."
    public static let finalLate = "The live transcript did not finish in time, so the saved audio went through batch."
    public static let unreachable = "The engine could not be reached. The audio is saved."
    public static let localDown = "Local whisper did not answer. Is its server running? The audio is saved."
    public static let noSpeech = "No speech came through. The audio is saved."
    public static let noFlac = "The live transcript failed and the audio could not be prepared for batch. The recording is saved."
    public static let noAudio = "The mic never delivered audio. Check the input device."
    public static let micFailed = "The mic could not start. Check the input device."
    public static let noFolder = "The take could not be saved, so nothing was recorded."
    public static let cleanupLate = "The cleanup pass did not finish in time, so the raw transcript was pasted."
    public static let cleanupFailed = "The cleanup pass failed, so the raw transcript was pasted."
    public static let cleanupDropped = "The cleanup pass dropped too many words to trust, so the raw transcript was pasted."
    public static let cleanupAdded = "The cleanup pass added words, so the raw transcript was pasted."
    public static let settledWords = "The live transcript did not finish, so the settled words were pasted."
    public static let batchTooLong = "The take is longer than the batch model's one-hour limit, so it was not sent to batch. The audio is saved."
    public static let batchTruncated = "The batch transcript hit the model's output limit and may be cut off."

    private static let noPasteTargetBase = "No text field had focus, so nothing was pasted."
    private static let vizierHadFocusBase = "Vizier itself had focus, so nothing was pasted."
    private static let focusMovedBase = "You switched apps after the take stopped, so nothing was pasted."
    private static let secureFieldBase = "A password field had focus, so nothing was pasted."
    private static let secureInputBase = "Secure input was on and the focused field could not be read, so nothing was pasted."

    public static func batchRepeated(words: Int, durationMs: Int) -> String {
        "The batch transcript has \(words) words for \(spoken(durationMs)) of audio, so it may contain repeated text."
    }

    private static func spoken(_ durationMs: Int) -> String {
        let seconds = durationMs / 1000
        if seconds < 90 { return "\(seconds) seconds" }
        return "\(Int((Double(seconds) / 60).rounded())) minutes"
    }

    public static func cleanup(_ fallback: TextCleanup.Fallback) -> String {
        switch fallback {
        case .timedOut: cleanupLate
        case .failed: cleanupFailed
        case .tooShort: cleanupDropped
        case .tooLong: cleanupAdded
        }
    }

    // MARK: Composed sentences

    public func noKey(_ name: String) -> String {
        "There is no \(name) key yet, so nothing was transcribed. \(addKeyHint) The audio is saved."
    }

    private func suffix(_ onClipboard: Bool) -> String { onClipboard ? clipboardSuffix : noClipboardSuffix }

    public func pasteFailed(onClipboard: Bool = true) -> String { pasteFailedBase + suffix(onClipboard) }
    public func permissionMissing(onClipboard: Bool = true) -> String { permissionMissingBase + suffix(onClipboard) }
    public func noPasteTarget(onClipboard: Bool = true) -> String { Self.noPasteTargetBase + suffix(onClipboard) }
    public func vizierHadFocus(onClipboard: Bool = true) -> String { Self.vizierHadFocusBase + suffix(onClipboard) }
    public func focusMoved(onClipboard: Bool = true) -> String { Self.focusMovedBase + suffix(onClipboard) }
    public func secureField(onClipboard: Bool = true) -> String { Self.secureFieldBase + suffix(onClipboard) }
    public func secureInput(onClipboard: Bool = true) -> String { Self.secureInputBase + suffix(onClipboard) }

    /// The remark for a paste that failed: a missing permission says how to grant it.
    public func forFailure(_ outcome: PasteOutcome) -> String {
        outcome.permissionMissing ? permissionMissing(onClipboard: outcome.onClipboard) : pasteFailed(onClipboard: outcome.onClipboard)
    }

    /// The remark for a paste that was held, from the `PasteDecision` reason constants.
    public func forHeld(_ outcome: PasteOutcome) -> String {
        let clip = outcome.onClipboard
        switch outcome.reason {
        case PasteDecision.vizierHadFocus: return vizierHadFocus(onClipboard: clip)
        case PasteDecision.focusMoved: return focusMoved(onClipboard: clip)
        case PasteDecision.secureField: return secureField(onClipboard: clip)
        case PasteDecision.secureInput: return secureInput(onClipboard: clip)
        default: return noPasteTarget(onClipboard: clip)
        }
    }
}
