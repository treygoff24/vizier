import AppKit
import Testing
import VizierEngine
@testable import Vizier

@Suite struct PasterTests {
    enum ClipboardChange: CaseIterable, Sendable { case none, duringPause, duringFinalCheck, sameText }

    @Test(arguments: ClipboardChange.allCases)
    func pasteRequiresTheWrittenClipboardGeneration(_ change: ClipboardChange) async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let transcript = "Zorblex"
        var events: [Paster.CommandVEvent] = []

        func overwrite(with text: String) {
            let previous = pasteboard.changeCount
            pasteboard.clearContents()
            #expect(pasteboard.setString(text, forType: .string))
            #expect(pasteboard.changeCount != previous)
        }

        let dependencies = Paster.Dependencies(
            pasteboard: pasteboard,
            checkTarget: { _, _ in .paste },
            finalCheck: { _ in
                if change == .duringFinalCheck { overwrite(with: "Quaxil") }
                return .paste
            },
            hasAccessibility: { true },
            prepareShortcut: {
                if change == .sameText { overwrite(with: transcript) }
                return .commandV { events.append($0) }
            }
        )
        let result = await Paster.paste(transcript, appAtStop: nil, using: dependencies) {
            // This callback runs as the pause ends, before the first ownership recheck.
            if change == .duringPause { overwrite(with: "Quaxil") }
            return true
        }
        let outcome = PasterService.outcome(result)

        if change == .none {
            #expect(events == [.commandDown, .vDown, .vUp, .commandUp])
            #expect(outcome.kind == .pasted)
            #expect(outcome.onClipboard)
            #expect(pasteboard.string(forType: .string) == transcript)
        } else {
            #expect(events.isEmpty)
            #expect(outcome.kind == .held)
            #expect(outcome.reason == PasteDecision.clipboardChanged)
            #expect(!outcome.onClipboard)
        }
    }
}
