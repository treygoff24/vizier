import Testing
import VizierEngine
@testable import Vizier

/// A remark for a problem the user can fix says how to fix it.
@Suite struct TakeRemarkTests {
    typealias Remark = TakeController.Remark

    @Test func aPasteFailedForAccessibilitySaysWhereToGrantIt() {
        #expect(Remark.forPasteFailure(Paster.accessibilityMissing) == Remark.accessibilityMissing)
        #expect(Remark.accessibilityMissing.contains("System Settings › Privacy & Security › Accessibility"))
        #expect(Paster.Outcome.failed(Paster.accessibilityMissing).failedForAccessibility)
    }

    @Test func anyOtherPasteFailureKeepsTheGeneralRemark() {
        #expect(Remark.forPasteFailure("AppleScript paste failed") == Remark.pasteFailed)
        #expect(Remark.forPasteFailure("could not create the Cmd+V events") == Remark.pasteFailed)
        #expect(!Paster.Outcome.failed("AppleScript paste failed").failedForAccessibility)
    }

    @Test func deniedMicrophoneAccessStopsTheTakeWithTheSettingsPath() {
        #expect(Remark.micBlocked(.denied) == Remark.micDenied)
        #expect(Remark.micDenied.contains("System Settings › Privacy & Security › Microphone"))
        // Granted records; not yet asked records too, so macOS can show its prompt.
        #expect(Remark.micBlocked(.granted) == nil)
        #expect(Remark.micBlocked(.notAsked) == nil)
    }

    @Test func aMissingSpeechModelPointsToTheDownloadButton() {
        #expect(Remark.speechModelMissing.contains("Settings › Transcription › Download speech model"))
    }

    /// The moved remarks read exactly as the app always has (golden copies of the original strings).
    @Test func theMacRemarksReadAsTheyAlwaysHave() {
        #expect(Remark.noKey("Gemini") == "There is no Gemini key yet, so nothing was transcribed. Add one in Settings › Accounts. The audio is saved.")
        #expect(Remark.speechModelMissing == "The Apple speech model is not ready (it may still be downloading), so nothing was transcribed. Get it in Settings › Transcription › Download speech model. The audio is saved.")
        #expect(Remark.offline == "The cloud could not be reached, so this Mac transcribed the saved audio.")
        #expect(Remark.micDenied == "Vizier does not have microphone access, so nothing was recorded. Turn it on in System Settings › Privacy & Security › Microphone.")
        #expect(Remark.pasteFailed == "The paste did not go through. The text is on the clipboard; ⌘V pastes it.")
        #expect(Remark.accessibilityMissing == "Vizier does not have Accessibility access, so nothing was pasted. Turn it on in System Settings › Privacy & Security › Accessibility. The text is on the clipboard; ⌘V pastes it.")
        #expect(Remark.noPasteTarget == "No text field had focus, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
        #expect(Remark.vizierHadFocus == "Vizier itself had focus, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
        #expect(Remark.focusMoved == "You switched apps after the take stopped, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
        #expect(Remark.secureField == "A password field had focus, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
        #expect(Remark.secureInput == "Secure input was on and the focused field could not be read, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
    }

    @Test func thePasterOutcomeMapsWithTheSameLogCodeAndMethod() {
        let keystroke = PasterService.outcome(.keystroke)
        #expect(keystroke.kind == .pasted && keystroke.method == "keystroke" && keystroke.logCode == "keystroke")
        let script = PasterService.outcome(.appleScript)
        #expect(script.kind == .pasted && script.method == "AppleScript" && script.logCode == "applescript")
        let held = PasterService.outcome(.held(PasteDecision.focusMoved))
        #expect(held.kind == .held && held.reason == PasteDecision.focusMoved && held.logCode == "held-focus-moved" && held.onClipboard)
        let denied = PasterService.outcome(.failed(Paster.accessibilityMissing))
        #expect(denied.kind == .failed && denied.permissionMissing && denied.logCode == "failed-accessibility")
        let failed = PasterService.outcome(.failed("x"))
        #expect(!failed.permissionMissing && failed.logCode == "failed" && failed.onClipboard)
        #expect(denied.onClipboard)
        let unwritten = PasterService.outcome(.failed(Paster.clipboardWriteFailed))
        #expect(unwritten.kind == .failed && !unwritten.onClipboard)
        #expect(PasterService.outcome(.withdrawn).kind == .withdrawn)
    }
}
