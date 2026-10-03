import VizierEngine
import Testing
@testable import Vizier

/// The take log line is public. A paste outcome goes into it only as a fixed code: held reasons can
/// name the app that had focus, and a failure can carry AppleScript's error text.
@Suite struct PasteOutcomeLogTests {
    static let codes: Set<String> = [
        "keystroke", "applescript", "withdrawn", "failed", "failed-accessibility",
        "held-vizier-focus", "held-focus-moved", "held-secure-field", "held-secure-input", "held-no-target",
    ]

    @Test func everyOutcomeLogsAFixedCode() {
        let outcomes: [Paster.Outcome] = [
            .keystroke, .appleScript, .withdrawn,
            .failed("AppleScript paste: Can’t get window \"Bank — Statement 2026\" of process \"Mail\""),
            .failed(Paster.accessibilityMissing),
            .held(PasteDecision.vizierHadFocus), .held(PasteDecision.focusMoved),
            .held(PasteDecision.secureField), .held(PasteDecision.secureInput),
            .held("no focused element in com.example.private-helper, a background app"),
        ]
        for outcome in outcomes {
            #expect(Self.codes.contains(outcome.logCode), "\(outcome.logCode)")
        }
        #expect(Set(outcomes.map(\.logCode)) == Self.codes)
    }

    @Test func freeTextNeverReachesTheCode() {
        #expect(Paster.Outcome.failed("AppleScript paste: Bank — Statement 2026").logCode == "failed")
        #expect(Paster.Outcome.held("no focused element in com.example.private-helper, a background app").logCode == "held-no-target")
    }
}
