import AVFoundation
import Foundation
import SQLite3
import Testing
@testable import VizierEngine

/// A synthetic VoiceInk store in the shape of the real one (its `ZTRANSCRIPTION` columns), with made-up words; nothing here comes from a real history.
@Suite struct VoiceInkImportTests {
    private let root: URL
    private let takes: TakeStore
    private let voiceInk: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "vizier-voiceink-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "VoiceInk/Recordings"), withIntermediateDirectories: true)
        takes = TakeStore(root: root.appending(path: "Takes"))
        voiceInk = root.appending(path: "VoiceInk")
    }

    private var storeURL: URL { voiceInk.appending(path: "default.store") }

    private func history() throws -> HistoryStore {
        try HistoryStore(databaseURL: root.appending(path: "Vizier/history.sqlite"), takesRoot: takes.root)
    }

    private struct Row {
        var endedAt: Double  // seconds since 1970
        var duration: Double
        var text: String?
        var enhanced: String?
        var status: String?
        var audio: String?   // a file name under Recordings
        var model = "Scribe V2"
        var cleaner: String? = "cleanup-model-y"
        var mode: String? = "Scribe V2 + Cleanup"
    }

    private func makeStore(_ rows: [Row], extraNullTimestamp: Bool = false) throws {
        var handle: OpaquePointer?
        #expect(sqlite3_open(storeURL.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        func exec(_ sql: String) { #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK, "\(sql)") }
        exec("""
            CREATE TABLE ZTRANSCRIPTION ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDURATION FLOAT, ZENHANCEMENTDURATION FLOAT,
              ZTIMESTAMP TIMESTAMP, ZTRANSCRIPTIONDURATION FLOAT, ZAIENHANCEMENTMODELNAME VARCHAR, ZAIREQUESTSYSTEMMESSAGE VARCHAR,
              ZAIREQUESTUSERMESSAGE VARCHAR, ZAUDIOFILEURL VARCHAR, ZENHANCEDTEXT VARCHAR, ZMODEEMOJI VARCHAR, ZMODENAME VARCHAR,
              ZPROMPTNAME VARCHAR, ZTEXT VARCHAR, ZTRANSCRIPTIONMODELNAME VARCHAR, ZTRANSCRIPTIONSTATUS VARCHAR, ZID BLOB )
            """)
        func quote(_ s: String?) -> String { s.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
        // Inserted newest first, so the reader's ordering is what puts them oldest first.
        for row in rows.reversed() {
            let url = row.audio.map { voiceInk.appending(path: "Recordings/\($0)").absoluteString }
            exec("""
                INSERT INTO ZTRANSCRIPTION (ZDURATION, ZENHANCEMENTDURATION, ZTIMESTAMP, ZTRANSCRIPTIONDURATION, ZAIENHANCEMENTMODELNAME,
                  ZAIREQUESTSYSTEMMESSAGE, ZAUDIOFILEURL, ZENHANCEDTEXT, ZMODENAME, ZTEXT, ZTRANSCRIPTIONMODELNAME, ZTRANSCRIPTIONSTATUS)
                VALUES (\(row.duration), 1.5, \(row.endedAt - VoiceInkImport.coreDataEpoch), 0.25, \(quote(row.cleaner)),
                  'a prompt that must not be imported', \(quote(url)), \(quote(row.enhanced)), \(quote(row.mode)), \(quote(row.text)),
                  \(quote(row.model)), \(quote(row.status)))
                """)
        }
        if extraNullTimestamp { exec("INSERT INTO ZTRANSCRIPTION (ZDURATION, ZTEXT) VALUES (1, 'no time')") }
    }

    /// A WAV in VoiceInk's format, 16 kHz Int16 mono, with a tone; returns its samples.
    @discardableResult
    private func wav(_ name: String, frames: Int) throws -> [Int16] {
        let url = voiceInk.appending(path: "Recordings/\(name)")
        let file = try AVAudioFile(forWriting: url, settings: TakeStore.recordingSettings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        var samples: [Int16] = []
        for i in 0..<frames {
            let value = Int16(6_000 * sin(Double(i) * 2 * .pi * 330 / 16_000)) &+ Int16(truncatingIfNeeded: (i &* 7919) % 89)
            buffer.int16ChannelData![0][i] = value
            samples.append(value)
        }
        try file.write(from: buffer)
        file.close()
        return samples
    }

    private func samples(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    }

    // 2026-09-20 15:00:10 UTC, and so on.
    private static let t0 = 1_789_916_410.0

    @Test func readsEveryTimedTakeOldestFirstWithItsFields() throws {
        try makeStore([
            Row(endedAt: Self.t0, duration: 4.5, text: "zorblex one", enhanced: "Zorblex one.", status: "completed", audio: "A.wav"),
            Row(endedAt: Self.t0 + 60, duration: 2, text: nil, enhanced: nil, status: "canceled", audio: "B.wav", cleaner: nil, mode: nil),
        ], extraNullTimestamp: true)
        let read = try VoiceInkImport.read(store: storeURL)
        #expect(read.count == 2, "a row with no timestamp is skipped")
        #expect(abs(read[0].endedAt.timeIntervalSince1970 - Self.t0) < 0.001)
        #expect(read[0].durationSeconds == 4.5)
        #expect(read[0].text == "zorblex one" && read[0].enhancedText == "Zorblex one.")
        #expect(read[0].transcriptionModel == "Scribe V2" && read[0].enhancementModel == "cleanup-model-y")
        #expect(read[0].modeName == "Scribe V2 + Cleanup" && read[0].status == "completed")
        #expect(read[0].audioFile == voiceInk.appending(path: "Recordings/A.wav"))
        #expect(read[0].transcriptionSeconds == 0.25 && read[0].enhancementSeconds == 1.5)
        #expect(read[1].status == "canceled" && read[1].text == nil && read[1].modeName == nil)
    }

    @Test func aTakeBecomesAFinishedRowThatStartedItsDurationBeforeItEnded() {
        let take = VoiceInkTake(endedAt: Date(timeIntervalSince1970: Self.t0), durationSeconds: 4.5, text: "zorblex one", enhancedText: "Zorblex one.",
                                transcriptionModel: "Scribe V2", enhancementModel: "cleanup-model-y", modeName: "Scribe V2 + Cleanup",
                                status: "completed", audioFile: nil, transcriptionSeconds: 0.25, enhancementSeconds: 1.5)
        let record = VoiceInkImport.record(take)
        #expect(record.id == "2026-09-20T15-00-05.500Z")
        #expect(record.startedAt == Date(timeIntervalSince1970: Self.t0 - 4.5) && record.stoppedAt == take.endedAt)
        #expect(record.durationMs == 4_500)
        #expect(record.modeID == "voiceink" && record.transcriberEngine == "voiceink" && record.transcriberModel == "Scribe V2")
        #expect(record.cleanerEngine == "voiceink" && record.cleanerModel == "cleanup-model-y")
        #expect(record.rawTranscript == "zorblex one" && record.cleanedText == "Zorblex one." && record.finalText == "Zorblex one.")
        #expect(record.transcriptionMs == 250 && record.cleanupMs == 1_500)
        #expect(record.outcome == .pasted)
        #expect(record.outcomeReason == "Imported from VoiceInk (mode: Scribe V2 + Cleanup)")
    }

    @Test func withoutEnhancedTextTheTranscriptIsFinalAndThereIsNoCleaner() {
        var take = VoiceInkTake(endedAt: Date(timeIntervalSince1970: Self.t0), durationSeconds: 1, text: "quaxil", enhancedText: "  \n",
                                transcriptionModel: nil, enhancementModel: "gemma", modeName: "", status: "completed", audioFile: nil,
                                transcriptionSeconds: nil, enhancementSeconds: 2)
        var record = VoiceInkImport.record(take)
        #expect(record.finalText == "quaxil" && record.cleanedText == nil)
        #expect(record.cleanerEngine == nil && record.cleanerModel == nil && record.cleanupMs == nil)
        #expect(record.transcriberModel == "unknown" && record.transcriptionMs == nil)
        #expect(record.outcomeReason == "Imported from VoiceInk")
        take.text = " "
        record = VoiceInkImport.record(take)
        #expect(record.finalText == nil && record.rawTranscript == nil)
    }

    @Test func statusesMapToOutcomes() {
        func outcome(_ status: String?) -> (TakeOutcome, String?) {
            let record = VoiceInkImport.record(VoiceInkTake(endedAt: .now, durationSeconds: 1, text: nil, enhancedText: nil, transcriptionModel: nil,
                                                            enhancementModel: nil, modeName: nil, status: status, audioFile: nil,
                                                            transcriptionSeconds: nil, enhancementSeconds: nil))
            return (record.outcome, record.outcomeReason)
        }
        #expect(outcome("completed").0 == .pasted)
        #expect(outcome("canceled").0 == .cancelled)
        #expect(outcome("failed").0 == .failed)
        #expect(outcome("pending") == (.failed, "Imported from VoiceInk; it never finished there (pending)"))
        #expect(outcome(nil) == (.failed, "Imported from VoiceInk; it never finished there (no status)"))
    }

    @Test func anImportedTakeGetsAttemptZeroAndASecondImportChangesNothing() throws {
        let store = try history()
        let take = VoiceInkImport.record(VoiceInkTake(endedAt: Date(timeIntervalSince1970: Self.t0), durationSeconds: 3, text: "zorblex",
                                                      enhancedText: "Zorblex.", transcriptionModel: "Scribe V2", enhancementModel: "gemma",
                                                      modeName: nil, status: "completed", audioFile: nil, transcriptionSeconds: 0.5, enhancementSeconds: 1))
        #expect(try store.importTake(take))
        var changed = take
        changed.finalText = "something else"
        #expect(try store.importTake(changed) == false)
        let row = try #require(try store.record(id: take.id))
        #expect(row.finalText == "Zorblex." && row.outcome == .pasted && row.modeID == "voiceink" && row.audioPath == nil)
        #expect(row.stoppedAt == take.stoppedAt && row.durationMs == 3_000 && row.cleanupMs == 1_000)
        #expect(try store.search("zorblex", outcomes: nil, limit: 10, before: nil).map(\.id) == [take.id])
        // Attempt 0 is written with the row, a copy of it.
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appending(path: "Vizier/history.sqlite").path, &handle) == SQLITE_OK)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT final_text, outcome FROM attempts WHERE take_id = '\(take.id)' AND attempt_no = 0", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(statement, 0)) == "Zorblex." && String(cString: sqlite3_column_text(statement, 1)) == "pasted")

        var inFlight = take
        inFlight.id = "2026-09-20T15-00-00.000Z"
        inFlight.outcome = .finalizing
        #expect(throws: HistoryError.takeInFlight(inFlight.id)) { try store.importTake(inFlight) }
    }

    @Test func runImportsTextAndLosslessAudioAndLeavesVoiceInksFilesAlone() throws {
        let tone = try wav("A.wav", frames: 24_000)
        let before = try Data(contentsOf: voiceInk.appending(path: "Recordings/A.wav"))
        try Data("not audio".utf8).write(to: voiceInk.appending(path: "Recordings/C.wav"))
        // A format VoiceInk never wrote here, which opens but will not go into a 16 kHz mono FLAC.
        let stereo = try AVAudioFile(forWriting: voiceInk.appending(path: "Recordings/D.wav"),
                                     settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2,
                                                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
                                     commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: stereo.processingFormat, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        try stereo.write(from: buffer)
        stereo.close()
        try makeStore([
            Row(endedAt: Self.t0, duration: 1.5, text: "zorblex one", enhanced: "Zorblex one.", status: "completed", audio: "A.wav"),
            Row(endedAt: Self.t0 + 60, duration: 2, text: "quaxil", enhanced: nil, status: "completed", audio: "missing.wav"),
            Row(endedAt: Self.t0 + 120, duration: 2, text: "gantry", enhanced: nil, status: "completed", audio: "C.wav"),
            Row(endedAt: Self.t0 + 180, duration: 1, text: "stereo", enhanced: nil, status: "completed", audio: "D.wav"),
        ])
        let store = try history()
        let summary = try VoiceInkImport.run(store: storeURL, history: store, takes: takes, copyAudio: true)
        #expect(summary == VoiceInkImport.Summary(found: 4, imported: 4, alreadyThere: 0, withAudio: 1, audioFailed: 3, audioSkipped: 0))

        let first = try #require(try store.record(id: "2026-09-20T15-00-08.500Z"))
        let flac = try #require(first.audioPath)
        #expect(flac == takes.root.appending(path: "2026-09/2026-09-20T15-00-08.500Z.flac"))
        #expect(try samples(flac) == tone, "every sample survives")
        #expect(try Data(contentsOf: voiceInk.appending(path: "Recordings/A.wav")) == before, "VoiceInk's file is untouched")
        #expect(first.durationMs == 1_500 && (first.audioBytes ?? 0) > 0)

        let unconvertible = try #require(try store.record(id: "2026-09-20T15-02-08.000Z"))
        #expect(unconvertible.audioPath == nil && unconvertible.finalText == "gantry")
        #expect(!FileManager.default.fileExists(atPath: takes.root.appending(path: "2026-09/2026-09-20T15-02-08.000Z.flac").path),
                "no half-written FLAC is left for reconcile to adopt")
        #expect(try store.record(id: "2026-09-20T15-01-08.000Z")?.audioPath == nil)
        #expect(try store.record(id: "2026-09-20T15-03-09.000Z")?.audioPath == nil)
        #expect(!FileManager.default.fileExists(atPath: takes.root.appending(path: "2026-09/2026-09-20T15-03-09.000Z.flac").path),
                "a FLAC that failed partway is removed")

        let again = try VoiceInkImport.run(store: storeURL, history: store, takes: takes, copyAudio: true)
        #expect(again == VoiceInkImport.Summary(found: 4, imported: 0, alreadyThere: 4, withAudio: 0, audioFailed: 0, audioSkipped: 0))
        #expect(try store.count() == 4)
    }

    @Test func damagedNumbersAreSkippedOrDroppedWithoutTrapping() throws {
        try makeStore([])
        var handle: OpaquePointer?
        try #require(sqlite3_open(storeURL.path, &handle) == SQLITE_OK)
        let stamp = Self.t0 - VoiceInkImport.coreDataEpoch
        // 9e999 is stored as infinity. Each bad value, in a conversion to Int or to a take id, traps.
        for (timestamp, duration, stage) in [("9e999", "1", "1"), ("-9e999", "1", "1"), ("1e300", "1", "1"), ("-1e9", "1", "1"),
                                             ("\(stamp)", "9e999", "-9e999"), ("\(stamp + 60)", "-3", "1e300")] {
            let sql = """
                INSERT INTO ZTRANSCRIPTION (ZTIMESTAMP, ZDURATION, ZTRANSCRIPTIONDURATION, ZENHANCEMENTDURATION, ZTEXT, ZENHANCEDTEXT, ZTRANSCRIPTIONSTATUS)
                VALUES (\(timestamp), \(duration), \(stage), \(stage), 'zorblex', 'Zorblex.', 'completed')
                """
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(handle)

        let read = try VoiceInkImport.read(store: storeURL)
        try #require(read.count == 2, "the four rows with an impossible timestamp are skipped")
        #expect(read.allSatisfy { $0.durationSeconds == 0 && $0.transcriptionSeconds == nil && $0.enhancementSeconds == nil })
        let records = read.map(VoiceInkImport.record)
        #expect(records.map(\.durationMs) == [0, 0])
        #expect(records.allSatisfy { $0.transcriptionMs == nil && $0.cleanupMs == nil })
    }

    @Test func audioIsReadOnlyFromARegularFileInsideVoiceInksRecordings() throws {
        try wav("A.wav", frames: 8_000)
        let outside = root.appending(path: "Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: voiceInk.appending(path: "Recordings/A.wav"), to: outside.appending(path: "B.wav"))
        let recordings = voiceInk.appending(path: "Recordings")
        try FileManager.default.createSymbolicLink(at: recordings.appending(path: "link.wav"), withDestinationURL: outside.appending(path: "B.wav"))
        try FileManager.default.createDirectory(at: recordings.appending(path: "folder.wav"), withIntermediateDirectories: true)

        func recording(_ url: URL) -> URL? {
            VoiceInkImport.recording(VoiceInkTake(endedAt: .now, durationSeconds: 1, text: nil, enhancedText: nil, transcriptionModel: nil,
                                                  enhancementModel: nil, modeName: nil, status: "completed", audioFile: url,
                                                  transcriptionSeconds: nil, enhancementSeconds: nil), store: storeURL)
        }
        #expect(recording(recordings.appending(path: "A.wav"))?.lastPathComponent == "A.wav")
        #expect(recording(recordings.appending(path: "link.wav")) == nil, "a symlink out of Recordings")
        #expect(recording(URL(filePath: recordings.path + "/../../Outside/B.wav")) == nil, "a path that climbs out")
        #expect(recording(outside.appending(path: "B.wav")) == nil, "a file elsewhere")
        #expect(recording(URL(filePath: "/dev/zero")) == nil, "a device")
        #expect(recording(recordings.appending(path: "folder.wav")) == nil, "a folder")
        #expect(recording(recordings.appending(path: "missing.wav")) == nil)

        // The import itself goes through the check: the symlinked row gets no audio.
        try makeStore([
            Row(endedAt: Self.t0, duration: 0.5, text: "zorblex", enhanced: nil, status: "completed", audio: "A.wav"),
            Row(endedAt: Self.t0 + 60, duration: 0.5, text: "quaxil", enhanced: nil, status: "completed", audio: "link.wav"),
        ])
        let store = try history()
        let summary = try VoiceInkImport.run(store: storeURL, history: store, takes: takes, copyAudio: true)
        #expect(summary.withAudio == 1 && summary.audioFailed == 1)
        #expect(try store.record(id: "2026-09-20T15-01-09.500Z")?.audioPath == nil)
    }

    @Test func aDryRunWithNoHistoryCountsEverythingAsNewAndCreatesNothing() throws {
        try wav("A.wav", frames: 8_000)
        try makeStore([
            Row(endedAt: Self.t0, duration: 0.5, text: "zorblex", enhanced: nil, status: "completed", audio: "A.wav"),
            Row(endedAt: Self.t0 + 60, duration: 0.5, text: "quaxil", enhanced: nil, status: "completed", audio: nil),
        ])
        let historyURL = root.appending(path: "Vizier/history.sqlite")
        let counts = try VoiceInkImport.dryRun(store: storeURL, historyURL: historyURL, takesRoot: takes.root)
        #expect(counts.found == 2 && counts.new == 2 && counts.audioFiles == 1 && counts.audioBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: historyURL.deletingLastPathComponent().path), "no history folder or file is created")
        #expect(!FileManager.default.fileExists(atPath: takes.root.path))
    }

    @Test func aDryRunReadsAnExistingHistoryThroughAStoreThatCannotWrite() throws {
        try makeStore([
            Row(endedAt: Self.t0, duration: 0.5, text: "zorblex", enhanced: nil, status: "completed", audio: nil),
            Row(endedAt: Self.t0 + 60, duration: 0.5, text: "quaxil", enhanced: nil, status: "completed", audio: nil),
        ])
        let historyURL = root.appending(path: "Vizier/history.sqlite")
        let live = try history()
        #expect(try live.importTake(VoiceInkImport.record(try VoiceInkImport.read(store: storeURL)[0])))
        let counts = try VoiceInkImport.dryRun(store: storeURL, historyURL: historyURL, takesRoot: takes.root)
        #expect(counts.found == 2 && counts.new == 1)

        let reader = try HistoryStore(readingOnly: historyURL, takesRoot: takes.root)
        #expect(try reader.count() == 1)
        #expect(throws: HistoryError.self) { try reader.importTake(VoiceInkImport.record(try VoiceInkImport.read(store: self.storeURL)[1])) }
        #expect(try live.count() == 1)
        #expect(throws: HistoryError.self) { try HistoryStore(readingOnly: root.appending(path: "Vizier/none.sqlite"), takesRoot: takes.root) }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Vizier/none.sqlite").path))
    }

    @Test func runWithoutAudioWritesNoFiles() throws {
        try wav("A.wav", frames: 8_000)
        try makeStore([Row(endedAt: Self.t0, duration: 0.5, text: "zorblex", enhanced: nil, status: "completed", audio: "A.wav")])
        let store = try history()
        let summary = try VoiceInkImport.run(store: storeURL, history: store, takes: takes, copyAudio: false)
        #expect(summary == VoiceInkImport.Summary(found: 1, imported: 1, alreadyThere: 0, withAudio: 0, audioFailed: 0, audioSkipped: 1))
        #expect(!FileManager.default.fileExists(atPath: takes.root.path))
    }
}
