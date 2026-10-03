import Foundation
import SQLite3
import Testing
@testable import VizierEngine

/// A second, independent connection to the history file, for reading what is really on disk and
/// for writing rows the store's API would never produce. Test-only; SQL here is literal.
private final class RawDatabase {
    let handle: OpaquePointer

    init(_ url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw HistoryError.open(path: url.path, code: 0, message: "raw open") }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw HistoryError.sqlite(code: code, message: String(cString: sqlite3_errmsg(handle))) }
    }

    func rows(_ sql: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryError.sqlite(code: 0, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return result
    }

    func value(_ sql: String) throws -> String? { try rows(sql).first?.first ?? nil }
}

@Suite struct HistoryStoreTests {
    private let root: URL
    private let takes: TakeStore
    private let databaseURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "vizier-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        takes = TakeStore(root: root.appending(path: "Takes"))
        databaseURL = root.appending(path: "Vizier/history.sqlite")
    }

    private func open() throws -> HistoryStore {
        try HistoryStore(databaseURL: databaseURL, takesRoot: takes.root)
    }

    private func raw() throws -> RawDatabase { try RawDatabase(databaseURL) }

    /// A take started at `seconds` past 1970, well before any test opens its store.
    private func newTake(_ seconds: Double) throws -> TakeFiles {
        try takes.newTake(startedAt: Date(timeIntervalSince1970: seconds))
    }

    private func draft(_ id: String, _ startedAt: Date, mode: String = "scribe") -> TakeDraft {
        TakeDraft(id: id, startedAt: startedAt, destinationAtStart: "com.example.terminal", modeID: mode,
                  transcriberEngine: "elevenlabs-scribe-realtime", transcriberModel: "scribe_v2_realtime",
                  fallbackEngine: "gemini-batch", fallbackModel: "gemini-3.5-transcribe",
                  cleanerEngine: nil, cleanerModel: nil)
    }

    private func stages(raw: String? = nil, cleaned: String? = nil, final: String? = nil, route: String? = nil,
                        transcriptionMs: Int? = nil, cleanupMs: Int? = nil, replacementMs: Int? = nil) -> TakeStages {
        TakeStages(raw: raw, cleaned: cleaned, final: final, route: route,
                   transcriptionMs: transcriptionMs, cleanupMs: cleanupMs, replacementMs: replacementMs)
    }

    private func dump(_ table: String) throws -> [[String?]] {
        try raw().rows("SELECT * FROM \(table) ORDER BY 1, 2")
    }

    // MARK: 1. Lifecycle

    @Test func aTakeRecordsEveryStageAndRecentListsNewestFirst() throws {
        let history = try open()
        let started = Date(timeIntervalSince1970: 1_780_000_000.123)
        let take = try takes.newTake(startedAt: started)
        try Data(repeating: 7, count: 1_234).write(to: take.flac)

        try history.begin(draft(take.id, started))
        #expect(try history.record(id: take.id)?.outcome == .recording)
        try history.setAudio(id: take.id, path: take.flac, byteCount: 1_234, durationMs: 1_500)
        try history.setStages(id: take.id, stages: stages(raw: "purple otter raw", route: "live", transcriptionMs: 260))
        try history.setStages(id: take.id, stages: stages(cleaned: "Purple otter, cleaned.", final: "Purple otter, final.", cleanupMs: 40, replacementMs: 2))
        // An empty raw transcript must not erase the one already stored.
        try history.setStages(id: take.id, stages: stages(raw: ""))
        try history.finish(id: take.id, stoppedAt: started.addingTimeInterval(5), outcome: .pasted, reason: nil,
                           destinationAtPaste: "com.example.terminal.paste", pasteMethod: "cmd-v", pasteMs: 101)

        let record = try #require(try history.record(id: take.id))
        #expect(record.id == take.id)
        #expect(record.startedAt == started)
        #expect(record.stoppedAt == started.addingTimeInterval(5))
        #expect(record.destinationAtStart == "com.example.terminal")
        #expect(record.destinationAtPaste == "com.example.terminal.paste")
        #expect(record.audioPath?.path == take.flac.standardizedFileURL.path)
        #expect(record.audioBytes == 1_234)
        #expect(record.durationMs == 1_500)
        #expect(record.modeID == "scribe")
        #expect(record.transcriberEngine == "elevenlabs-scribe-realtime")
        #expect(record.transcriberModel == "scribe_v2_realtime")
        #expect(record.fallbackEngine == "gemini-batch")
        #expect(record.fallbackModel == "gemini-3.5-transcribe")
        #expect(record.cleanerEngine == nil)
        #expect(record.cleanerModel == nil)
        #expect(record.rawTranscript == "purple otter raw")
        #expect(record.cleanedText == "Purple otter, cleaned.")
        #expect(record.finalText == "Purple otter, final.")
        #expect(record.route == "live")
        #expect(record.transcriptionMs == 260)
        #expect(record.cleanupMs == 40)
        #expect(record.replacementMs == 2)
        #expect(record.pasteMs == 101)
        #expect(record.outcome == .pasted)
        #expect(record.outcomeReason == nil)
        #expect(record.pasteMethod == "cmd-v")
        #expect(record.verbatimBaseline == nil)
        #expect(record.verbatimBaselineModel == nil)
        #expect(record.verbatimBaselineMs == nil)

        let older = Date(timeIntervalSince1970: 1_770_000_000)
        let newest = Date(timeIntervalSince1970: 1_785_000_000)
        try history.begin(draft("older", older))
        try history.begin(draft("newest", newest))
        #expect(try history.recent(limit: 2).map(\.id) == ["newest", take.id])
        #expect(try history.recent(limit: -1).isEmpty)
        #expect(try history.recent(limit: 10).map(\.id) == ["newest", take.id, "older"])
    }

    @Test func emptyOrBlankTextIsNoTextAndNeverReplacesStoredText() throws {
        let history = try open()
        try history.begin(draft("take", Date(timeIntervalSince1970: 1_780_000_000)))
        try history.setStages(id: "take", stages: stages(raw: "", cleaned: " ", final: "\n\t"))
        let blank = try #require(try history.record(id: "take"))
        #expect(blank.rawTranscript == nil)
        #expect(blank.cleanedText == nil)
        #expect(blank.finalText == nil)
        try history.setStages(id: "take", stages: stages(raw: "hello", cleaned: "Hello.", final: "Hello!"))
        try history.setStages(id: "take", stages: stages(raw: "   ", cleaned: "", final: " "))
        let kept = try #require(try history.record(id: "take"))
        #expect(kept.rawTranscript == "hello")
        #expect(kept.cleanedText == "Hello.")
        #expect(kept.finalText == "Hello!")
    }

    @Test func writesToAnUnknownTakeThrow() throws {
        let history = try open()
        let url = takes.root.appending(path: "2026-09/nope.flac")
        #expect(throws: HistoryError.unknownTake("nope")) { try history.setStages(id: "nope", stages: stages(raw: "x")) }
        #expect(throws: HistoryError.unknownTake("nope")) { try history.setAudio(id: "nope", path: url, byteCount: 1, durationMs: 1) }
        #expect(throws: HistoryError.unknownTake("nope")) {
            try history.finish(id: "nope", stoppedAt: nil, outcome: .failed, reason: nil, destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        }
    }

    @Test func audioOutsideTheTakesFolderIsRefused() throws {
        let history = try open()
        try history.begin(draft("take", Date(timeIntervalSince1970: 1_780_000_000)))
        let outside = root.appending(path: "elsewhere.flac")
        #expect(throws: HistoryError.audioOutsideTakesRoot(outside.path)) {
            try history.setAudio(id: "take", path: outside, byteCount: 1, durationMs: 1)
        }
        let sneaky = takes.root.appending(path: "2026-09/../../elsewhere.flac")
        #expect { try history.setAudio(id: "take", path: sneaky, byteCount: 1, durationMs: 1) } throws: { error in
            if case HistoryError.audioOutsideTakesRoot = error { return true }
            return false
        }
    }

    // MARK: 2. Attempt 0

    @Test func finishWritesAttemptZeroOnceAndLaterWritesNeverChangeIt() throws {
        let history = try open()
        let take = try newTake(1_780_000_000)
        try history.begin(draft(take.id, Date(timeIntervalSince1970: 1_780_000_000)))
        try history.setStages(id: take.id, stages: stages(raw: "first raw", cleaned: "First cleaned.", final: "First final.", route: "live",
                                                          transcriptionMs: 300, cleanupMs: 50, replacementMs: 3))
        // Moving to finalizing is not an ending, so there is no attempt yet.
        try history.finish(id: take.id, stoppedAt: Date(timeIntervalSince1970: 1_780_000_004), outcome: .finalizing, reason: nil,
                           destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        #expect(try dump("attempts").isEmpty)

        try history.finish(id: take.id, stoppedAt: nil, outcome: .held, reason: "no editable target",
                           destinationAtPaste: nil, pasteMethod: "clipboard", pasteMs: nil)
        let columns = "attempt_no, mode_id, transcriber_engine, transcriber_model, raw_transcript, cleaned_text, final_text, transcription_ms, cleanup_ms, replacement_ms, outcome, outcome_reason"
        let attemptZero = try raw().rows("SELECT \(columns) FROM attempts")
        #expect(attemptZero == [["0", "scribe", "elevenlabs-scribe-realtime", "scribe_v2_realtime", "first raw", "First cleaned.", "First final.",
                                 "300", "50", "3", "held", "no editable target"]])

        try history.setStages(id: take.id, stages: stages(cleaned: "Changed later.", final: "Changed final."))
        try history.finish(id: take.id, stoppedAt: nil, outcome: .pasted, reason: nil,
                           destinationAtPaste: "com.apple.TextEdit", pasteMethod: "cmd-v", pasteMs: 90)
        #expect(try history.record(id: take.id)?.finalText == "Changed final.")
        #expect(try history.record(id: take.id)?.outcome == .pasted)
        #expect(try raw().rows("SELECT \(columns) FROM attempts") == attemptZero)
        // A finished take never slips back to in flight.
        try history.finish(id: take.id, stoppedAt: nil, outcome: .finalizing, reason: nil, destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        #expect(try history.record(id: take.id)?.outcome == .pasted)
    }

    @Test func aCancelledTakeStaysCancelledWhenItsAudioOrALaterFinishArrives() throws {
        let history = try open()
        let take = try newTake(1_780_000_000)
        try Data(repeating: 1, count: 10).write(to: take.flac)
        try history.begin(draft(take.id, Date(timeIntervalSince1970: 1_780_000_000)))
        try history.finish(id: take.id, stoppedAt: Date(timeIntervalSince1970: 1_780_000_002), outcome: .cancelled, reason: "escape",
                           destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        try history.setAudio(id: take.id, path: take.flac, byteCount: 10, durationMs: 2_000)
        try history.finish(id: take.id, stoppedAt: nil, outcome: .failed, reason: "conversion failed",
                           destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        try history.finish(id: take.id, stoppedAt: nil, outcome: .finalizing, reason: nil,
                           destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        let record = try #require(try history.record(id: take.id))
        #expect(record.outcome == .cancelled)
        #expect(record.outcomeReason == "escape")
        #expect(record.audioBytes == 10)
        #expect(try raw().rows("SELECT outcome FROM attempts") == [["cancelled"]])
    }

    // MARK: 3–4. Reconcile

    @Test func reconcileAdoptsOrphanFilesOnceAndDeletesNothing() throws {
        let orphanFLAC = try newTake(1_780_000_000.5)
        let orphanCAF = try newTake(1_780_000_100)
        let known = try newTake(1_780_000_200)
        try Data(repeating: 1, count: 111).write(to: orphanFLAC.flac)
        try Data(repeating: 2, count: 222).write(to: orphanCAF.recording)
        try Data(repeating: 3, count: 333).write(to: known.flac)

        let history = try open()
        try history.begin(draft(known.id, Date(timeIntervalSince1970: 1_780_000_200)))
        try history.setAudio(id: known.id, path: known.flac, byteCount: 333, durationMs: 3_000)
        try history.finish(id: known.id, stoppedAt: nil, outcome: .pasted, reason: nil, destinationAtPaste: nil, pasteMethod: "cmd-v", pasteMs: 80)
        let knownBefore = try history.record(id: known.id)
        let knownRowBefore = try raw().rows("SELECT * FROM takes WHERE id = '\(known.id)'")

        try history.reconcileFiles()

        #expect(try history.recent(limit: 10).count == 3)
        for (take, url, bytes) in [(orphanFLAC, orphanFLAC.flac, Int64(111)), (orphanCAF, orphanCAF.recording, Int64(222))] {
            let record = try #require(try history.record(id: take.id))
            #expect(record.outcome == .failed)
            #expect(record.outcomeReason == "interrupted before delivery")
            #expect(record.modeID == "unknown")
            #expect(record.transcriberEngine == "unknown")
            #expect(record.transcriberModel == "unknown")
            #expect(record.audioPath?.path == url.standardizedFileURL.path)
            #expect(record.audioBytes == bytes)
        }
        #expect(try history.record(id: orphanFLAC.id)?.startedAt == Date(timeIntervalSince1970: 1_780_000_000.5))
        #expect(try history.record(id: orphanCAF.id)?.startedAt == Date(timeIntervalSince1970: 1_780_000_100))
        #expect(try history.record(id: known.id) == knownBefore)
        #expect(try raw().rows("SELECT * FROM takes WHERE id = '\(known.id)'") == knownRowBefore)
        #expect(try raw().rows("SELECT take_id, attempt_no, outcome FROM attempts ORDER BY take_id") ==
                [[orphanFLAC.id, "0", "failed"], [orphanCAF.id, "0", "failed"], [known.id, "0", "pasted"]])
        for url in [orphanFLAC.flac, orphanCAF.recording, known.flac] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        let takesAfterFirst = try dump("takes")
        let attemptsAfterFirst = try dump("attempts")
        try history.reconcileFiles()
        #expect(try dump("takes") == takesAfterFirst)
        #expect(try dump("attempts") == attemptsAfterFirst)
        // And so does a fresh launch reconciling the same folder.
        try open().reconcileFiles()
        #expect(try dump("takes") == takesAfterFirst)
        #expect(try dump("attempts") == attemptsAfterFirst)
    }

    @Test func whenBothRecordingAndFLACSurviveTheRowNamesTheRecording() throws {
        let take = try newTake(1_780_000_000)
        try Data(repeating: 1, count: 50).write(to: take.recording)
        try Data(repeating: 2, count: 20).write(to: take.flac)
        let history = try open()
        try history.reconcileFiles()
        #expect(try history.record(id: take.id)?.audioPath?.path == take.recording.standardizedFileURL.path)
    }

    @Test func aRowWithNoAudioIsPointedAtItsFileOnReconcile() throws {
        let take = try newTake(1_780_000_000)
        let history = try open()
        try history.begin(draft(take.id, Date(timeIntervalSince1970: 1_780_000_000)))
        try history.finish(id: take.id, stoppedAt: nil, outcome: .cancelled, reason: "escape", destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        try Data(repeating: 1, count: 44).write(to: take.flac)
        try history.reconcileFiles()
        let record = try #require(try history.record(id: take.id))
        #expect(record.audioPath?.path == take.flac.standardizedFileURL.path)
        #expect(record.audioBytes == 44)
        #expect(record.outcome == .cancelled)
    }

    @Test func takesLeftInFlightAtOpenFailOnReconcileButCancelledAndLiveTakesDoNot() throws {
        do {
            let crashed = try open()
            try crashed.begin(draft("2026-05-28T20-26-40.000Z", Date(timeIntervalSince1970: 1_780_000_000)))
            try crashed.setStages(id: "2026-05-28T20-26-40.000Z", stages: stages(raw: "words before the crash"))
            try crashed.begin(draft("2026-05-28T20-28-20.000Z", Date(timeIntervalSince1970: 1_780_000_100)))
            try crashed.finish(id: "2026-05-28T20-28-20.000Z", stoppedAt: nil, outcome: .finalizing, reason: nil,
                               destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
            try crashed.begin(draft("2026-05-28T20-30-00.000Z", Date(timeIntervalSince1970: 1_780_000_200)))
            try crashed.finish(id: "2026-05-28T20-30-00.000Z", stoppedAt: nil, outcome: .cancelled, reason: "escape",
                               destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        }

        let history = try open()
        // A take this process starts after opening is live: neither its row nor its file is touched.
        let live = try takes.newTake(startedAt: .now.addingTimeInterval(1))
        try Data(repeating: 1, count: 10).write(to: live.recording)
        try history.begin(draft("live", .now))
        try history.reconcileFiles()

        let recording = try #require(try history.record(id: "2026-05-28T20-26-40.000Z"))
        #expect(recording.outcome == .failed)
        #expect(recording.outcomeReason == "interrupted before delivery")
        #expect(recording.rawTranscript == "words before the crash")
        #expect(try history.record(id: "2026-05-28T20-28-20.000Z")?.outcome == .failed)
        #expect(try history.record(id: "2026-05-28T20-30-00.000Z")?.outcome == .cancelled)
        #expect(try history.record(id: "2026-05-28T20-30-00.000Z")?.outcomeReason == "escape")
        #expect(try history.record(id: "live")?.outcome == .recording)
        #expect(try history.record(id: live.id) == nil)
        #expect(try raw().rows("SELECT take_id, raw_transcript, outcome FROM attempts ORDER BY take_id") == [
            ["2026-05-28T20-26-40.000Z", "words before the crash", "failed"],
            ["2026-05-28T20-28-20.000Z", nil, "failed"],
            ["2026-05-28T20-30-00.000Z", nil, "cancelled"],
        ])
    }

    @Test func takeIDsParseOnlyInTakeStoresExactForm() throws {
        let take = try takes.newTake(startedAt: Date(timeIntervalSince1970: 1_790_000_000.123))
        #expect(HistoryStore.parseTakeID(take.id) == 1_790_000_000_123)
        for bad in ["", "notes", "2026-09-21T14-13-20.123", "2026-13-21T14-13-20.123Z", "2026-02-30T14-13-20.123Z",
                    "2026-09-21T14-13-20.12Z", "2026-09-21T14-13-2a.123Z", "2026-09-21T14-13-20.123Z.old"] {
            #expect(HistoryStore.parseTakeID(bad) == nil, "\(bad)")
        }
    }

    // MARK: 5. Paths

    @Test func aStoredPathOutsideTheTakesFolderResolvesToNoAudio() throws {
        let history = try open()
        try history.begin(draft("take", Date(timeIntervalSince1970: 1_780_000_000)))
        let db = try raw()
        for stored in ["../../etc/passwd", "2026-09/../../../etc/passwd", "/etc/passwd", "", "./2026-09/x.flac"] {
            try db.execute("UPDATE takes SET audio_path = '\(stored)' WHERE id = 'take'")
            #expect(try history.record(id: "take")?.audioPath == nil, "\(stored)")
        }
        try db.execute("UPDATE takes SET audio_path = '2026-09/x.flac' WHERE id = 'take'")
        #expect(try history.record(id: "take")?.audioPath?.path == takes.root.appending(path: "2026-09/x.flac").standardizedFileURL.path)

        // Plain components that are symlinks: a linked file in a real month folder, and a linked
        // month folder. Both land outside the takes folder once followed, so neither is audio.
        let fm = FileManager.default
        let elsewhere = root.appending(path: "elsewhere.flac")
        try Data([0]).write(to: elsewhere)
        try fm.createDirectory(at: takes.root.appending(path: "2026-09"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: takes.root.appending(path: "2026-09/link.flac"), withDestinationURL: elsewhere)
        let outsideDir = root.appending(path: "outside-dir")
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try Data([0]).write(to: outsideDir.appending(path: "x.flac"))
        try fm.createSymbolicLink(at: takes.root.appending(path: "2026-08"), withDestinationURL: outsideDir)
        for stored in ["2026-09/link.flac", "2026-08/x.flac"] {
            try db.execute("UPDATE takes SET audio_path = '\(stored)' WHERE id = 'take'")
            #expect(try history.record(id: "take")?.audioPath == nil, "\(stored)")
        }
    }

    // MARK: 6. Search

    @Test func searchMatchesAnyTextFiltersByOutcomeAndTreatsWildcardsLiterally() throws {
        let history = try open()
        func add(_ id: String, _ seconds: Double, _ stage: TakeStages, _ outcome: TakeOutcome) throws {
            try history.begin(draft(id, Date(timeIntervalSince1970: seconds)))
            try history.setStages(id: id, stages: stage)
            try history.finish(id: id, stoppedAt: nil, outcome: outcome, reason: nil, destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        }
        try add("raw-only", 1_780_000_000, stages(raw: "the purple otter"), .failed)
        try add("cleaned-only", 1_780_000_100, stages(cleaned: "Purple Otter notes"), .held)
        try add("final-percent", 1_780_000_200, stages(final: "100% done_now"), .pasted)
        try add("final-plain", 1_780_000_300, stages(final: "100x doneXnow back\\slash"), .pasted)

        #expect(try history.search("PURPLE", outcomes: nil, limit: 10, before: nil).map(\.id) == ["cleaned-only", "raw-only"])
        #expect(try history.search("purple", outcomes: [.held], limit: 10, before: nil).map(\.id) == ["cleaned-only"])
        #expect(try history.search("purple", outcomes: [.held, .failed], limit: 10, before: nil).map(\.id) == ["cleaned-only", "raw-only"])
        #expect(try history.search("purple", outcomes: [], limit: 10, before: nil).isEmpty)
        #expect(try history.search("100%", outcomes: nil, limit: 10, before: nil).map(\.id) == ["final-percent"])
        #expect(try history.search("done_now", outcomes: nil, limit: 10, before: nil).map(\.id) == ["final-percent"])
        #expect(try history.search("k\\s", outcomes: nil, limit: 10, before: nil).map(\.id) == ["final-plain"])
        #expect(try history.search("", outcomes: [.pasted], limit: 10, before: nil).map(\.id) == ["final-plain", "final-percent"])
        #expect(try history.search("", outcomes: nil, limit: 1, before: nil).map(\.id) == ["final-plain"])
        #expect(try history.search("", outcomes: nil, limit: -1, before: nil).isEmpty)
        #expect(try history.search("", outcomes: nil, limit: 10, before: Date(timeIntervalSince1970: 1_780_000_200)).map(\.id)
                == ["cleaned-only", "raw-only"])
    }

    @Test func searchNeedsEveryWordInAnyOrder() throws {
        let history = try open()
        func add(_ id: String, _ seconds: Double, _ stage: TakeStages) throws {
            try history.begin(draft(id, Date(timeIntervalSince1970: seconds)))
            try history.setStages(id: id, stages: stage)
            try history.finish(id: id, stoppedAt: nil, outcome: .pasted, reason: nil, destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        }
        try add("both", 1_780_000_000, stages(final: "Tell Robin the report needs a budget line"))
        try add("robin-only", 1_780_000_100, stages(final: "Robin called about lunch"))
        try add("budget-only", 1_780_000_200, stages(final: "the budget line"))

        // Not adjacent, and in the other order: still a match. One word missing: no match.
        #expect(try history.search("budget robin", outcomes: nil, limit: 10, before: nil).map(\.id) == ["both"])
        #expect(try history.search("  robin \t report  line ", outcomes: nil, limit: 10, before: nil).map(\.id) == ["both"])
        #expect(try history.search("robin parking", outcomes: nil, limit: 10, before: nil).isEmpty)
        // Whitespace alone is an empty query: every take.
        #expect(try history.search("   ", outcomes: nil, limit: 10, before: nil).count == 3)
    }

    @Test func reRunsNumberAfterTheOriginalAndNeverChangeTheTake() throws {
        let history = try open()
        try history.begin(draft("take", Date(timeIntervalSince1970: 1_780_000_000)))
        try history.finish(id: "take", stoppedAt: nil, outcome: .failed, reason: "No speech came through.", destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        let before = try history.record(id: "take")
        let originalAttempt = try dump("attempts")

        let older = try history.addRerun(takeID: "take", RerunDraft(modeID: "scribe", transcriberEngine: "gemini-batch", transcriberModel: "g",
                                                                    finalText: "An older otter.", succeeded: true))
        let failed = try history.addRerun(takeID: "take", RerunDraft(modeID: "scribe", transcriberEngine: "gemini-batch", transcriberModel: "g",
                                                                     succeeded: false, reason: "The transcription failed."))
        let worked = try history.addRerun(takeID: "take", RerunDraft(modeID: "gemini-clean", transcriberEngine: "gemini-batch", transcriberModel: "g",
                                                                     cleanerEngine: "gemini-generate", cleanerModel: "lite",
                                                                     rawTranscript: "the otter memo", cleanedText: "The otter memo.",
                                                                     finalText: "The otter memo.", transcriptionMs: 900, succeeded: true))
        let failedAgain = try history.addRerun(takeID: "take", RerunDraft(modeID: "scribe", transcriberEngine: "gemini-batch", transcriberModel: "g",
                                                                          rawTranscript: "   ", succeeded: false, reason: "No speech came through."))
        #expect(older.number == 1 && failed.number == 2 && worked.number == 3 && failedAgain.number == 4)
        #expect(failed.outcome == TakeAttempt.failed && failed.finalText == nil && failedAgain.rawTranscript == nil)
        #expect(worked.outcome == TakeAttempt.transcribed && worked.finalText == "The otter memo." && worked.cleanerModel == "lite")
        #expect(try history.reruns(takeID: "take") == [older, failed, worked, failedAgain])

        // The take's row and attempt 0 are exactly as they were. The row carries the text of the
        // newest re-run that produced any, skipping the failed one after it.
        let after = try history.record(id: "take")
        #expect(after?.outcome == .failed && after?.finalText == nil && after?.rawTranscript == nil)
        #expect(after?.rerunText == "The otter memo." && before?.rerunText == nil)
        #expect(try dump("attempts").filter { $0[1] == "0" } == originalAttempt)

        // A re-run's text is searchable, and still needs every word.
        #expect(try history.search("memo otter", outcomes: nil, limit: 10, before: nil).map(\.id) == ["take"])
        #expect(try history.search("memo parking", outcomes: nil, limit: 10, before: nil).isEmpty)

        // A take still in flight, or unknown, cannot be re-run.
        try history.begin(draft("live", Date(timeIntervalSince1970: 1_780_000_100)))
        let run = RerunDraft(modeID: "scribe", transcriberEngine: "e", transcriberModel: "m", succeeded: false)
        #expect(throws: HistoryError.takeInFlight("live")) { try history.addRerun(takeID: "live", run) }
        #expect(throws: HistoryError.unknownTake("nope")) { try history.addRerun(takeID: "nope", run) }
        #expect(try history.reruns(takeID: "live").isEmpty)
    }

    @Test func anEmptySearchListsTakesThatHaveNoTextAndAudioBytesAddUp() throws {
        let history = try open()
        let first = try newTake(1_780_000_000), second = try newTake(1_780_000_100)
        for take in [first, second] { try Data([1]).write(to: take.flac) }
        try history.begin(draft(first.id, Date(timeIntervalSince1970: 1_780_000_000)))
        try history.setAudio(id: first.id, path: first.flac, byteCount: 1_000, durationMs: 900)
        try history.finish(id: first.id, stoppedAt: nil, outcome: .failed, reason: "no speech", destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        try history.begin(draft(second.id, Date(timeIntervalSince1970: 1_780_000_100)))
        try history.setAudio(id: second.id, path: second.flac, byteCount: 2_500, durationMs: 2_000)
        try history.setStages(id: second.id, stages: stages(final: "words"))
        try history.finish(id: second.id, stoppedAt: nil, outcome: .pasted, reason: nil, destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)

        #expect(try history.search("", outcomes: nil, limit: 10, before: nil).map(\.id) == [second.id, first.id])
        #expect(try history.search("", outcomes: [.failed], limit: 10, before: nil).map(\.id) == [first.id])
        // A real query still needs text to match.
        #expect(try history.search("words", outcomes: nil, limit: 10, before: nil).map(\.id) == [second.id])
        #expect(try history.totalAudioBytes() == 3_500)
        #expect(try history.count() == 2)
    }

    /// Each change is announced once, on the main thread, and never inside the write's own call:
    /// a writer holding a lock the main thread wants must not wait for an observer (the
    /// app wedged on this). The test runs on the main actor, so nothing announced can arrive
    /// before it next suspends.
    @Test @MainActor func theStoreAnnouncesEachTakeChangeOnTheMainThreadAfterTheWrite() async throws {
        let history = try open()
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(forName: HistoryStore.didChange, object: history, queue: nil) { _ in
            counter.bump(onMain: Thread.isMainThread)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let take = try newTake(1_780_000_000)
        try Data([1]).write(to: take.flac)
        try history.begin(draft(take.id, Date(timeIntervalSince1970: 1_780_000_000)))
        #expect(counter.value == 0)
        try await counter.reach(1)
        try history.setAudio(id: take.id, path: take.flac, byteCount: 1, durationMs: 1)
        #expect(counter.value == 1)
        try await counter.reach(2)
        try history.finish(id: take.id, stoppedAt: nil, outcome: .pasted, reason: nil, destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
        try await counter.reach(3)
        try history.reconcileFiles()
        try await counter.reach(4)
        #expect(counter.offMain == 0)
    }

    // MARK: 7–8. Schema and durability

    @Test func aDatabaseFromAnotherSchemaVersionIsRefusedUntouched() throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let db = try raw()
            try db.execute("CREATE TABLE takes (id TEXT); PRAGMA user_version = 2;")
        }
        #expect(throws: HistoryError.schemaVersion(found: 2)) { try open() }
        #expect(try raw().value("PRAGMA journal_mode") == "delete")
        #expect(try raw().value("PRAGMA user_version") == "2")
    }

    @Test func tablesWithoutAVersionAreRefused() throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try raw().execute("CREATE TABLE takes (id TEXT)")
        #expect(throws: HistoryError.schemaVersion(found: 0)) { try open() }
    }

    @Test func historySurvivesReopeningTheFile() throws {
        let take = try newTake(1_780_000_000)
        try Data(repeating: 1, count: 9).write(to: take.flac)
        var written: TakeRecord?
        do {
            let first = try open()
            try first.begin(draft(take.id, Date(timeIntervalSince1970: 1_780_000_000)))
            try first.setAudio(id: take.id, path: take.flac, byteCount: 9, durationMs: 900)
            try first.setStages(id: take.id, stages: stages(raw: "kept words", final: "Kept words.", route: "batch"))
            try first.finish(id: take.id, stoppedAt: Date(timeIntervalSince1970: 1_780_000_001), outcome: .rerouted, reason: "focus moved",
                             destinationAtPaste: nil, pasteMethod: "clipboard", pasteMs: nil)
            written = try first.record(id: take.id)
        }
        let second = try open()
        #expect(written != nil)
        #expect(try second.record(id: take.id) == written)
        #expect(try raw().value("PRAGMA journal_mode") == "wal")
        #expect(try raw().value("PRAGMA user_version") == "1")
    }

    @Test func concurrentCallersDoNotCollide() throws {
        let history = try open()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            let id = "take-\(index)"
            do {
                try history.begin(draft(id, Date(timeIntervalSince1970: 1_780_000_000 + Double(index))))
                try history.setStages(id: id, stages: stages(raw: "words \(index)"))
                try history.finish(id: id, stoppedAt: nil, outcome: .pasted, reason: nil, destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
                _ = try history.recent(limit: 6)
            } catch {
                Issue.record("take \(index): \(error)")
            }
        }
        #expect(try history.recent(limit: 100).count == 24)
        #expect(try raw().value("SELECT count(*) FROM attempts") == "24")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var countOffMain = 0
    func bump(onMain: Bool) { lock.withLock { count += 1; if !onMain { countOffMain += 1 } } }
    var value: Int { lock.withLock { count } }
    var offMain: Int { lock.withLock { countOffMain } }

    /// Waits up to two seconds for exactly `expected` bumps, then checks the count.
    func reach(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while value < expected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(value == expected)
    }
}
