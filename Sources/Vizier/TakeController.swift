import Foundation
import VizierEngine

/// The app's handle on the take lifecycle. The orchestration lives in the engine's `TakeSession`
/// (so the macOS app and the Linux daemon run the same state machine); this façade builds it with
/// the Mac's collaborators and keeps the surface the hotkey, onboarding and the app shell use.
final class TakeController {
    /// The remarks line's sentences: one plain sentence of fact each. The wording is the engine's
    /// `TakeRemarks.mac`; these names keep the tests and call sites that read it.
    enum Remark {
        private static let table = TakeRemarks.mac

        static let streamDroppedRecording = TakeRemarks.streamDroppedRecording
        static let streamDroppedNoBatch = TakeRemarks.streamDroppedNoBatch
        static let streamDropped = TakeRemarks.streamDropped
        static let finalLate = TakeRemarks.finalLate
        static let unreachable = TakeRemarks.unreachable
        static let localDown = TakeRemarks.localDown
        static var offline: String { table.offline }
        static func noKey(_ name: String) -> String { table.noKey(name) }
        static var speechModelMissing: String { table.speechModelMissing }
        static let noSpeech = TakeRemarks.noSpeech
        static let noFlac = TakeRemarks.noFlac
        static let noAudio = TakeRemarks.noAudio
        static let micFailed = TakeRemarks.micFailed
        static var micDenied: String { table.micDenied }
        static let noFolder = TakeRemarks.noFolder
        static var pasteFailed: String { table.pasteFailed() }
        static var accessibilityMissing: String { table.permissionMissing() }

        /// A failed paste's remark: missing Accessibility says how to grant it.
        static func forPasteFailure(_ reason: String) -> String {
            reason == Paster.accessibilityMissing ? accessibilityMissing : pasteFailed
        }

        /// The remark that stops a take before it records, when microphone access is denied;
        /// nil when the take may start. Not yet asked goes ahead, so macOS can ask.
        static func micBlocked(_ access: PermissionState) -> String? {
            access == .denied ? micDenied : nil
        }
        static var noPasteTarget: String { table.noPasteTarget() }
        static var vizierHadFocus: String { table.vizierHadFocus() }
        static var focusMoved: String { table.focusMoved() }
        static var secureField: String { table.secureField() }
        static var secureInput: String { table.secureInput() }
        static let cleanupLate = TakeRemarks.cleanupLate
        static let cleanupFailed = TakeRemarks.cleanupFailed
        static let cleanupDropped = TakeRemarks.cleanupDropped
        static let cleanupAdded = TakeRemarks.cleanupAdded
        static let settledWords = TakeRemarks.settledWords
        static let batchTooLong = TakeRemarks.batchTooLong
        static let batchTruncated = TakeRemarks.batchTruncated
        static func batchRepeated(words: Int, durationMs: Int) -> String {
            TakeRemarks.batchRepeated(words: words, durationMs: durationMs)
        }

        static func cleanup(_ fallback: TextCleanup.Fallback) -> String {
            TakeRemarks.cleanup(fallback)
        }
    }

    private let session: TakeSession

    init(statusItem: StatusItemController, strip: StripController, history: HistoryStore?) {
        session = TakeSession(
            config: .standard, store: .standard, recorder: TakeRecorder(), history: history, secrets: KeychainStore(),
            presentation: StripTakePresentation(statusItem: statusItem, strip: strip), sounds: CueSoundPlayer(),
            microphone: SystemMicPermission(), focus: WorkspaceFocusProbe(), paster: PasterService(),
            remarks: .mac, speech: .apple)
        // The hotkey has never waited for the crash repair; it must not start to.
        session.markReady()
    }

    /// Times the take's stop and paste, so a typed Cmd+V near them can be logged.
    var pasteWatch: TypedPasteWatch {
        get { session.pasteWatch }
        set { session.pasteWatch = newValue }
    }

    /// Set only while onboarding's Practice step is on screen: a finished take's text goes here
    /// instead of being pasted, since Vizier never pastes into itself. Everywhere else it is nil.
    var practiceSink: ((String) -> Void)? {
        get { session.practiceSink }
        set { session.practiceSink = newValue }
    }

    /// Readies the mic so the first take after launch doesn't lose its opening words. Call once
    /// mic access is granted; a take started meanwhile waits for it and uses the readied unit.
    func warmUpCapture() { session.warmUpCapture() }

    var isCancelable: Bool { session.isCancelable }
    var acceptsToggle: Bool { session.acceptsToggle }

    /// `time` is the Right Command key-down; the stop's latency figures count from it. A toggle
    /// while finalizing does nothing (callers check `acceptsToggle` first).
    func toggle(at time: TimeInterval) {
        _ = try? session.toggle(at: time)
    }

    func cancel() {
        _ = try? session.cancel()
    }

    /// Repairs history from the files on disk, then encodes recordings a crash left behind.
    func recoverUnfinishedTakes() {
        session.recoverUnfinishedTakes()
    }

    static func platformCode(_ name: String) -> String { HistoryBoard.platformCode(name) }
}
