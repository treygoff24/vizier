import Testing
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
}
