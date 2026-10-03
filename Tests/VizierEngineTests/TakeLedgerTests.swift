import Foundation
import SQLite3
import Testing
@testable import VizierEngine

/// The ledger against a real `HistoryStore` on a temp folder. Every test reads the row back
/// through a fresh store on the same file, so it checks what is on disk, not what the ledger holds.
@Suite struct TakeLedgerTests {
    private let root: URL
    private let takes: TakeStore
    private let databaseURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "vizier-ledger-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        takes = TakeStore(root: root.appending(path: "Takes"))
        databaseURL = root.appending(path: "Vizier/history.sqlite")
    }

    private func open() throws -> HistoryStore {
        try HistoryStore(databaseURL: databaseURL, takesRoot: takes.root)
    }

    private func newLedger(_ store: HistoryStore?, cleaner: Bool = false) throws -> (TakeLedger, TakeFiles) {
        let files = try takes.newTake(startedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let draft = TakeDraft(
            id: files.id, startedAt: Date(timeIntervalSince1970: 1_790_000_000), destinationAtStart: "Terminal", modeID: cleaner ? "gemini-clean" : "scribe",
            transcriberEngine: cleaner ? "gemini-live" : "elevenlabs-scribe-realtime", transcriberModel: cleaner ? "gemini-3.5-transcribe-live" : "scribe_v2_realtime",
            fallbackEngine: "gemini-batch", fallbackModel: "gemini-3.5-transcribe",
            cleanerEngine: cleaner ? "gemini-generate" : nil, cleanerModel: cleaner ? "gemini-3.5-flash-lite" : nil)
        return (TakeLedger(store: store, draft: draft), files)
    }

    private func row(_ id: String) throws -> TakeRecord {
        try #require(try open().record(id: id))
    }

    @Test func aFullTakeRecordsEveryStageAndItsPaste() throws {
        let store = try open()
        let (ledger, files) = try newLedger(store, cleaner: true)
        ledger.stopped(at: Date(timeIntervalSince1970: 1_790_000_012))
        #expect(try row(files.id).outcome == .finalizing)
        ledger.audioSaved(path: files.flac, byteCount: 48_000, durationMs: 12_000)
        ledger.transcript(raw: "um so the the meeting is at noon", route: "live", transcriptionMs: 640)
        ledger.cleaned("So the meeting is at noon.", cleanupMs: 910)
        ledger.finalText("So the meeting is at 12:00.", replacementMs: 2)
        ledger.conclude(.pasted, reason: nil, destination: "Notes", pasteMethod: "keystroke", pasteMs: 1_720)

        let record = try row(files.id)
        #expect(record.outcome == .pasted)
        #expect(record.outcomeReason == nil)
        #expect(record.rawTranscript == "um so the the meeting is at noon")
        #expect(record.cleanedText == "So the meeting is at noon.")
        #expect(record.finalText == "So the meeting is at 12:00.")
        #expect(record.route == "live")
        #expect(record.transcriptionMs == 640)
        #expect(record.cleanupMs == 910)
        #expect(record.replacementMs == 2)
        #expect(record.pasteMs == 1_720)
        #expect(record.pasteMethod == "keystroke")
        #expect(record.destinationAtStart == "Terminal")
        #expect(record.destinationAtPaste == "Notes")
        #expect(record.stoppedAt == Date(timeIntervalSince1970: 1_790_000_012))
        #expect(record.audioPath?.lastPathComponent == files.flac.lastPathComponent)
        #expect(record.audioBytes == 48_000)
        #expect(record.durationMs == 12_000)
        #expect(record.cleanerModel == "gemini-3.5-flash-lite")
        #expect(ledger.isConcluded)
        #expect(ledger.writeFailures == 0)
    }

    @Test func aCancelWhileRecordingKeepsTheSettledLiveWordsWithNoTiming() throws {
        let store = try open()
        let (ledger, files) = try newLedger(store)
        // The controller writes the strip's settled words before it cancels; there is no final
        // and no stop-to-final timing for a take that never stopped.
        ledger.transcript(raw: "the words the strip had", route: "live", transcriptionMs: nil)
        ledger.cancel()

        let record = try row(files.id)
        #expect(record.outcome == .cancelled)
        #expect(record.rawTranscript == "the words the strip had")
        #expect(record.route == "live")
        #expect(record.transcriptionMs == nil)
        #expect(record.stoppedAt != nil)
    }

    @Test func aCancelKeepsAFinalThatArrivesAfterItAndALaterPasteDoesNotReplaceIt() throws {
        let store = try open()
        let (ledger, files) = try newLedger(store)
        ledger.stopped()
        ledger.transcript(raw: "keep this", route: "live", transcriptionMs: 500)
        ledger.cancel()
        ledger.finalText("Keep this.", replacementMs: 1)
        ledger.conclude(.pasted, reason: nil, destination: "Notes", pasteMethod: "keystroke", pasteMs: 800)

        let record = try row(files.id)
        #expect(record.outcome == .cancelled)
        #expect(record.outcomeReason == nil)
        #expect(record.rawTranscript == "keep this")
        #expect(record.finalText == "Keep this.")
        #expect(record.pasteMethod == nil)
        #expect(ledger.texts.final == "Keep this.")
    }

    @Test func theFirstTerminalCallWins() throws {
        let store = try open()
        let (ledger, files) = try newLedger(store)
        ledger.transcript(raw: "done", route: "live", transcriptionMs: 400)
        ledger.conclude(.pasted, reason: nil, destination: "Notes", pasteMethod: "keystroke", pasteMs: 700)
        ledger.cancel()
        ledger.conclude(.held, reason: "paste failed", destination: nil, pasteMethod: "clipboard", pasteMs: nil)
        // A stage call after the end still writes; it never moves the outcome.
        ledger.stopped(at: Date(timeIntervalSince1970: 1))

        let record = try row(files.id)
        #expect(record.outcome == .pasted)
        #expect(record.outcomeReason == nil)
        #expect(record.pasteMethod == "keystroke")
        #expect(record.stoppedAt != Date(timeIntervalSince1970: 1))
    }

    @Test func blankTextNeverClearsTextAlreadyHeld() throws {
        let store = try open()
        let (ledger, files) = try newLedger(store)
        ledger.transcript(raw: "first words", route: "live", transcriptionMs: 300)
        ledger.cleaned("First words.", cleanupMs: 200)
        ledger.finalText("First words.", replacementMs: 1)
        ledger.transcript(raw: "", route: "batch", transcriptionMs: 9_000)
        ledger.cleaned("   ", cleanupMs: nil)
        ledger.cleaned(nil, cleanupMs: 50)
        ledger.finalText("\n", replacementMs: nil)

        let record = try row(files.id)
        #expect(record.rawTranscript == "first words")
        #expect(record.cleanedText == "First words.")
        #expect(record.finalText == "First words.")
        #expect(record.route == "batch")
        #expect(ledger.texts.raw == "first words")
        #expect(ledger.texts.cleaned == "First words.")
        #expect(ledger.texts.final == "First words.")
    }

    @Test func withNoStoreEveryCallIsANoOpButTextAndConclusionAreTracked() throws {
        let (ledger, files) = try newLedger(nil)
        #expect(!ledger.isConcluded)
        ledger.stopped()
        ledger.audioSaved(path: files.flac, byteCount: 10, durationMs: 1_000)
        ledger.transcript(raw: "no history today", route: "live", transcriptionMs: 100)
        ledger.cleaned("No history today.", cleanupMs: 90)
        ledger.finalText("No history today.", replacementMs: nil)
        ledger.conclude(.failed, reason: "whatever", destination: nil, pasteMethod: nil, pasteMs: nil)

        #expect(ledger.texts.raw == "no history today")
        #expect(ledger.texts.cleaned == "No history today.")
        #expect(ledger.texts.final == "No history today.")
        #expect(ledger.isConcluded)
        #expect(ledger.writeFailures == 0)
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(!FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path))
    }

    @Test func rerouteReasonsAreRecordedVerbatim() throws {
        let store = try open()
        let viaBatch = ledger(store, id: "2026-09-25T20-00-00.001Z")
        viaBatch.transcript(raw: "from the saved audio", route: "batch", transcriptionMs: 4_200)
        viaBatch.finalText("from the saved audio", replacementMs: nil)
        viaBatch.conclude(.rerouted, reason: "batch", destination: "Notes", pasteMethod: "keystroke", pasteMs: 4_400)

        let rawText = ledger(store, id: "2026-09-25T20-00-00.002Z")
        rawText.transcript(raw: "the raw words", route: "live", transcriptionMs: 600)
        rawText.cleaned(nil, cleanupMs: 4_000)
        rawText.finalText("the raw words", replacementMs: nil)
        rawText.conclude(.rerouted, reason: "raw text", destination: "Notes", pasteMethod: "AppleScript", pasteMs: 4_700)

        let batch = try row("2026-09-25T20-00-00.001Z")
        #expect(batch.outcome == .rerouted)
        #expect(batch.outcomeReason == "batch")
        #expect(batch.route == "batch")
        let raw = try row("2026-09-25T20-00-00.002Z")
        #expect(raw.outcome == .rerouted)
        #expect(raw.outcomeReason == "raw text")
        #expect(raw.route == "live")
        #expect(raw.cleanedText == nil)
        #expect(raw.cleanupMs == 4_000)
        #expect(raw.pasteMethod == "AppleScript")
    }

    private func ledger(_ store: HistoryStore?, id: String) -> TakeLedger {
        TakeLedger(store: store, draft: TakeDraft(
            id: id, startedAt: .now, destinationAtStart: nil, modeID: "gemini-clean",
            transcriberEngine: "gemini-live", transcriberModel: "gemini-3.5-transcribe-live",
            fallbackEngine: nil, fallbackModel: nil, cleanerEngine: "gemini-generate", cleanerModel: "gemini-3.5-flash-lite"))
    }

    /// The store stops accepting writes mid-take. A second connection drops the tables, so
    /// every later write on the store's own connection fails at once with "no such table", with
    /// no timing involved. (`chmod` on the open file changes nothing, and moving the file away
    /// fails writes only when SQLite happens to notice: flaky in the full suite.)
    @Test func aStoreThatStopsWritingMidTakeNeverStopsTheTake() throws {
        let store = try open()
        let (ledger, files) = try newLedger(store)
        ledger.transcript(raw: "written before", route: "live", transcriptionMs: 300)
        #expect(ledger.writeFailures == 0)
        #expect(try store.record(id: files.id)?.rawTranscript == "written before")

        try dropTables()

        ledger.cleaned("Written after.", cleanupMs: 80)
        ledger.finalText("Written after.", replacementMs: 1)
        ledger.conclude(.pasted, reason: nil, destination: "Notes", pasteMethod: "keystroke", pasteMs: 900)
        ledger.audioSaved(path: files.flac, byteCount: 1, durationMs: 1)

        #expect(ledger.writeFailures == 4)
        #expect(ledger.texts.raw == "written before")
        #expect(ledger.texts.cleaned == "Written after.")
        #expect(ledger.texts.final == "Written after.")
        #expect(ledger.isConcluded)
        // The writes really failed rather than landing somewhere: the store can't read the row.
        #expect(throws: HistoryError.self) { try store.record(id: files.id) }
    }

    /// A past wedge: the audio-saving task held the ledger's lock through the store's
    /// change notification, which waited for a main-queue observer (the popover's), while the
    /// main thread, cancelling the take, waited for that lock. Here the main thread blocks as it
    /// did, with a deadline instead of the lock, so a regression fails in two seconds and then
    /// lets the parked write finish rather than hanging the suite.
    @Test @MainActor func aWriteOffTheMainThreadFinishesWhileTheMainThreadIsBlocked() throws {
        let store = try open()
        let observer = NotificationCenter.default.addObserver(forName: HistoryStore.didChange, object: store, queue: .main) { _ in }
        defer { NotificationCenter.default.removeObserver(observer) }
        let (ledger, files) = try newLedger(store)

        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            ledger.audioSaved(path: files.flac, byteCount: 48_000, durationMs: 1_000)
            written.signal()
        }
        let finished = written.wait(timeout: .now() + 2) == .success
        #expect(finished, "the write waited for the main thread while holding the ledger's lock")
        guard finished else { return }

        // The cancel that was stuck, now that the lock is free: it returns and records the cancel.
        ledger.cancel()
        let record = try row(files.id)
        #expect(record.outcome == .cancelled)
        #expect(record.durationMs == 1_000)
    }

    /// Drops both history tables through an independent connection to the same file.
    private func dropTables() throws {
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            throw HistoryError.open(path: databaseURL.path, code: 0, message: "second connection")
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 5_000)
        let code = sqlite3_exec(handle, "DROP TABLE attempts; DROP TABLE takes;", nil, nil, nil)
        guard code == SQLITE_OK else {
            throw HistoryError.sqlite(code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
    }
}

/// The settled live words `TakeController` pastes when a take's live final never comes.
@Suite struct SettledTranscriptTests {
    @Test func interimWordsSettleOnceTheyHoldThroughARevisionAndAreNotAtTheTail() {
        var live = SettledTranscript()
        live.update(settled: "", pending: "the quick brown fox jumps")
        #expect(live.text == "")
        live.update(settled: "", pending: "the quick brown fox jumps over")
        #expect(live.text == "the quick brown fox")
    }

    @Test func finalsAreAlwaysSettled() {
        var live = SettledTranscript()
        live.update(settled: "hello there", pending: "gen")
        #expect(live.text == "hello there")
        live.update(settled: "hello there general", pending: "")
        #expect(live.text == "hello there general")
    }

    /// A deliberate difference from the strip, which would withhold the revised word.
    @Test func unlikeTheStripARevisedMiddleWordStaysAsTheCurrentGuess() {
        var live = SettledTranscript()
        live.update(settled: "", pending: "a b c d e f")
        live.update(settled: "", pending: "a X c d e f g")
        #expect(live.text == "a X c d e")
    }

    /// The strip's row trims to its newest words; the settled text must keep the whole take.
    @Test func aLongTakeKeepsEverySettledWordThatTheStripRowTrims() {
        let words = (0...100).map { "w\($0)" }
        var live = SettledTranscript()
        var row = WordLine()
        for count in [100, 101] {
            let pending = words.prefix(count).joined(separator: " ")
            live.update(settled: "", pending: pending)
            row.update(settled: "", pending: pending)
        }
        #expect(live.text == words.prefix(99).joined(separator: " "))
        #expect(row.plates.count < 99)
    }

    @Test func settledWordsStandInForAMissingOrBlankTranscriptOnly() {
        var live = SettledTranscript()
        live.update(settled: "hello there", pending: "gen")
        #expect(live.standIn(for: nil) == "hello there")
        #expect(live.standIn(for: "") == "hello there")
        #expect(live.standIn(for: " \n\t") == "hello there")
        #expect(live.standIn(for: "hello there general") == nil)
        let nothingSettled = SettledTranscript()
        #expect(nothingSettled.standIn(for: nil) == nil)
        #expect(nothingSettled.standIn(for: "") == nil)
    }
}
