import AppKit
import VizierEngine

// The macOS side of the engine take session's collaborators.
// Each adapter is a thin wrapper over a service the app already had; none carries take logic.

/// The status item and the strip, as the session's presentation.
final class StripTakePresentation: TakePresentation {
    private let statusItem: StatusItemController
    private let strip: StripController

    init(statusItem: StatusItemController, strip: StripController) {
        self.statusItem = statusItem
        self.strip = strip
    }

    func phaseChanged(_ phase: TakePhase) {
        statusItem.phase = switch phase {
        case .idle: .idle
        case .arming: .arming
        case .recording: .recording
        case .finalizing: .finalizing
        }
    }

    func raiseAlert() { statusItem.alert = true }

    func begin(destination: String, platform: String, level: @escaping @Sendable () -> Float, seconds: @escaping @Sendable () -> Double) {
        strip.begin(destination: destination, platform: platform, level: level, seconds: seconds)
    }

    func setLive() { strip.setLive() }
    func setWords(_ plates: [WordLine.Plate]) { strip.setWords(plates) }
    func streamLost(remark: String) { strip.streamLost(remark: remark) }
    func stopped(onTime: TimeInterval) { strip.stopped(onTime: onTime) }
    func reroutingToBatch() { strip.reroutingToBatch() }

    func finish(_ result: TakeResult, remark: String?) {
        let outcome: StripController.Outcome = switch result {
        case .pasted: .pasted
        case .rerouted(.batch): .rerouted(.batch)
        case .rerouted(.rawText): .rerouted(.rawText)
        case .held: .held
        case .failed: .failed
        case .cancelled: .cancelled
        }
        strip.finish(outcome, remark: remark)
    }
}

/// The four cues.
final class CueSoundPlayer: SoundPlayer {
    private let sounds = Sounds()

    func play(_ sound: TakeSound) {
        let cue: Sounds.Cue = switch sound {
        case .start: .start
        case .stop: .stop
        case .problem: .problem
        case .cancel: .cancel
        }
        sounds.play(cue)
    }
}

/// Microphone access, read fresh at each take.
final class SystemMicPermission: MicPermission {
    func microphoneDenied() -> Bool { SystemPermissions().microphone() == .denied }
}

/// The frontmost app.
final class WorkspaceFocusProbe: FocusProbe {
    func destinationName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }

    func focusedProcess() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// `Paster`, with its outcome mapped to the session's neutral one. Every path of `Paster` leaves
/// the text on the clipboard (it writes the clipboard first), except a failed clipboard write,
/// which has always been reported with the same remark as any other failure; that stays.
final class PasterService: PasteService {
    func paste(_ text: String, focusAtStop: Int32?, stillWanted: @escaping @MainActor () -> Bool) async -> PasteOutcome {
        Self.outcome(await Paster.paste(text, appAtStop: focusAtStop) { stillWanted() })
    }

    static func outcome(_ outcome: Paster.Outcome) -> PasteOutcome {
        switch outcome {
        case .keystroke, .appleScript:
            PasteOutcome(kind: .pasted, method: outcome.description, reason: nil, onClipboard: true, permissionMissing: false, logCode: outcome.logCode)
        case .withdrawn:
            PasteOutcome(kind: .withdrawn, method: "", reason: nil, onClipboard: true, permissionMissing: false, logCode: outcome.logCode)
        case .held(let reason):
            PasteOutcome(kind: .held, method: "", reason: reason, onClipboard: true, permissionMissing: false, logCode: outcome.logCode)
        case .failed(let reason):
            PasteOutcome(kind: .failed, method: "", reason: reason, onClipboard: reason != Paster.clipboardWriteFailed, permissionMissing: outcome.failedForAccessibility, logCode: outcome.logCode)
        }
    }
}

extension SpeechModelCheck {
    /// Apple's speech engines' "model not installed" failures.
    static let apple = SpeechModelCheck(
        streamLostMeansModelMissing: { $0 == AppleSpeechTranscriber.modelMissingReason },
        batchErrorMeansModelMissing: { error in
            if case AppleSpeechError.modelNotInstalled = error { true } else { false }
        })
}
