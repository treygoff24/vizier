import Foundation
import Testing
@testable import VizierEngine
@testable import Vizier

/// History's sentence for a held take, for rows written before and after the rename.
@Suite struct HistoryReasonTests {
    private func held(_ reason: String) -> TakeRecord {
        TakeRecord(id: "t", startedAt: Date(timeIntervalSince1970: 0), stoppedAt: nil, destinationAtStart: nil, destinationAtPaste: nil,
                   audioPath: nil, audioBytes: nil, durationMs: nil, modeID: "apple", transcriberEngine: "e", transcriberModel: "m",
                   fallbackEngine: nil, fallbackModel: nil, cleanerEngine: nil, cleanerModel: nil,
                   rawTranscript: nil, cleanedText: nil, finalText: nil, route: nil, transcriptionMs: nil, cleanupMs: nil,
                   replacementMs: nil, pasteMs: nil, outcome: .held, outcomeReason: reason, pasteMethod: nil,
                   verbatimBaseline: nil, verbatimBaselineModel: nil, verbatimBaselineMs: nil, rerunText: nil)
    }

    private let hadFocus = "Vizier itself had focus, so nothing was pasted. The text went to the clipboard."

    @Test func aTakeHeldBecauseVizierHadFocusSaysSo() {
        #expect(HistoryDetail.reason(held(PasteDecision.vizierHadFocus)) == hadFocus)
    }

    @Test func aRowRecordedBeforeTheRenameStillReadsAsHadFocus() {
        // Vizier was called Dictum until 2026-10-03, and history rows keep the reason they were written with.
        #expect(HistoryDetail.reason(held("Dictum itself had focus")) == hadFocus)
    }
}
