import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

/// Where a take stands. `recording` and `finalizing` are in flight; the rest are terminal.
public enum TakeOutcome: String, Codable, Sendable {
    case recording, finalizing, pasted, rerouted, held, failed, cancelled

    var isTerminal: Bool { self != .recording && self != .finalizing }
}

/// What is known about a take the moment capture starts.
public struct TakeDraft: Sendable {
    public let id: String
    public let startedAt: Date
    public let destinationAtStart: String?
    public let modeID: String
    public let transcriberEngine: String
    public let transcriberModel: String
    public let fallbackEngine: String?
    public let fallbackModel: String?
    public let cleanerEngine: String?
    public let cleanerModel: String?

    public init(id: String, startedAt: Date, destinationAtStart: String?, modeID: String,
                transcriberEngine: String, transcriberModel: String,
                fallbackEngine: String?, fallbackModel: String?,
                cleanerEngine: String?, cleanerModel: String?) {
        self.id = id
        self.startedAt = startedAt
        self.destinationAtStart = destinationAtStart
        self.modeID = modeID
        self.transcriberEngine = transcriberEngine
        self.transcriberModel = transcriberModel
        self.fallbackEngine = fallbackEngine
        self.fallbackModel = fallbackModel
        self.cleanerEngine = cleanerEngine
        self.cleanerModel = cleanerModel
    }
}

/// Text and timings as a take moves through transcription, cleanup, and replacement. A nil field
/// means "not known at this stage" and leaves whatever was stored before.
public struct TakeStages: Sendable {
    public let raw: String?
    public let cleaned: String?
    public let final: String?
    public let route: String?         // "live" or "batch"
    public let transcriptionMs: Int?
    public let cleanupMs: Int?
    public let replacementMs: Int?

    public init(raw: String?, cleaned: String?, final: String?, route: String?,
                transcriptionMs: Int?, cleanupMs: Int?, replacementMs: Int?) {
        self.raw = raw
        self.cleaned = cleaned
        self.final = final
        self.route = route
        self.transcriptionMs = transcriptionMs
        self.cleanupMs = cleanupMs
        self.replacementMs = replacementMs
    }
}

/// One row of history. `audioPath` is absolute and always inside the takes folder, or nil.
public struct TakeRecord: Sendable, Identifiable, Equatable {
    public let id: String
    public let startedAt: Date
    public let stoppedAt: Date?
    public let destinationAtStart: String?
    public let destinationAtPaste: String?
    public let audioPath: URL?
    public let audioBytes: Int64?
    public let durationMs: Int?
    public let modeID: String
    public let transcriberEngine: String
    public let transcriberModel: String
    public let fallbackEngine: String?
    public let fallbackModel: String?
    public let cleanerEngine: String?
    public let cleanerModel: String?
    public let rawTranscript: String?
    public let cleanedText: String?
    public let finalText: String?
    public let route: String?
    public let transcriptionMs: Int?
    public let cleanupMs: Int?
    public let replacementMs: Int?
    public let pasteMs: Int?
    public let outcome: TakeOutcome
    public let outcomeReason: String?
    public let pasteMethod: String?
    public let verbatimBaseline: String?
    public let verbatimBaselineModel: String?
    public let verbatimBaselineMs: Int?
    /// The final text of the newest re-run that produced text, or nil.
    public let rerunText: String?
}

/// A finished take from another app, for `HistoryStore.importTake`. Its outcome must be terminal.
public struct ImportedTake: Sendable, Equatable {
    public var id: String
    public var startedAt: Date
    public var stoppedAt: Date
    public var durationMs: Int
    public var modeID: String
    public var transcriberEngine: String
    public var transcriberModel: String
    public var cleanerEngine: String?
    public var cleanerModel: String?
    public var rawTranscript: String?
    public var cleanedText: String?
    public var finalText: String?
    public var transcriptionMs: Int?
    public var cleanupMs: Int?
    public var outcome: TakeOutcome
    public var outcomeReason: String?

    public init(id: String, startedAt: Date, stoppedAt: Date, durationMs: Int, modeID: String,
                transcriberEngine: String, transcriberModel: String, cleanerEngine: String?, cleanerModel: String?,
                rawTranscript: String?, cleanedText: String?, finalText: String?,
                transcriptionMs: Int?, cleanupMs: Int?, outcome: TakeOutcome, outcomeReason: String?) {
        self.id = id
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.durationMs = durationMs
        self.modeID = modeID
        self.transcriberEngine = transcriberEngine
        self.transcriberModel = transcriberModel
        self.cleanerEngine = cleanerEngine
        self.cleanerModel = cleanerModel
        self.rawTranscript = rawTranscript
        self.cleanedText = cleanedText
        self.finalText = finalText
        self.transcriptionMs = transcriptionMs
        self.cleanupMs = cleanupMs
        self.outcome = outcome
        self.outcomeReason = outcomeReason
    }
}

/// What a re-run produced, for `HistoryStore.addRerun`.
public struct RerunDraft: Sendable, Equatable {
    public var modeID: String
    public var transcriberEngine: String
    public var transcriberModel: String
    public var cleanerEngine: String?
    public var cleanerModel: String?
    public var rawTranscript: String?
    public var cleanedText: String?
    public var finalText: String?
    public var transcriptionMs: Int?
    public var cleanupMs: Int?
    public var replacementMs: Int?
    /// True when text came back to show.
    public var succeeded: Bool
    /// Why it failed, or a note on how it went.
    public var reason: String?

    public init(modeID: String, transcriberEngine: String, transcriberModel: String, cleanerEngine: String? = nil, cleanerModel: String? = nil,
                rawTranscript: String? = nil, cleanedText: String? = nil, finalText: String? = nil,
                transcriptionMs: Int? = nil, cleanupMs: Int? = nil, replacementMs: Int? = nil, succeeded: Bool, reason: String? = nil) {
        self.modeID = modeID
        self.transcriberEngine = transcriberEngine
        self.transcriberModel = transcriberModel
        self.cleanerEngine = cleanerEngine
        self.cleanerModel = cleanerModel
        self.rawTranscript = rawTranscript
        self.cleanedText = cleanedText
        self.finalText = finalText
        self.transcriptionMs = transcriptionMs
        self.cleanupMs = cleanupMs
        self.replacementMs = replacementMs
        self.succeeded = succeeded
        self.reason = reason
    }
}

/// One run of a take's audio: attempt 0 is the original take as it ended; later numbers are
/// re-runs from History, which never change the take's own row.
public struct TakeAttempt: Sendable, Equatable, Identifiable {
    /// A re-run's outcome: text came back, or it did not.
    public static let transcribed = "transcribed"
    public static let failed = "failed"

    public let takeID: String
    public let number: Int
    public let createdAt: Date
    public let modeID: String
    public let transcriberEngine: String
    public let transcriberModel: String
    public let cleanerEngine: String?
    public let cleanerModel: String?
    public let rawTranscript: String?
    public let cleanedText: String?
    public let finalText: String?
    public let transcriptionMs: Int?
    public let cleanupMs: Int?
    public let replacementMs: Int?
    /// A `TakeOutcome` raw value for attempt 0; `transcribed` or `failed` for a re-run.
    public let outcome: String
    /// For a failed re-run, why; for one that transcribed, a note on how (or nil).
    public let outcomeReason: String?

    public var id: String { "\(takeID)#\(number)" }

    public init(takeID: String, number: Int, createdAt: Date, modeID: String, transcriberEngine: String, transcriberModel: String,
                cleanerEngine: String?, cleanerModel: String?, rawTranscript: String?, cleanedText: String?, finalText: String?,
                transcriptionMs: Int?, cleanupMs: Int?, replacementMs: Int?, outcome: String, outcomeReason: String?) {
        self.takeID = takeID
        self.number = number
        self.createdAt = createdAt
        self.modeID = modeID
        self.transcriberEngine = transcriberEngine
        self.transcriberModel = transcriberModel
        self.cleanerEngine = cleanerEngine
        self.cleanerModel = cleanerModel
        self.rawTranscript = rawTranscript
        self.cleanedText = cleanedText
        self.finalText = finalText
        self.transcriptionMs = transcriptionMs
        self.cleanupMs = cleanupMs
        self.replacementMs = replacementMs
        self.outcome = outcome
        self.outcomeReason = outcomeReason
    }
}

public enum HistoryError: Error, Equatable, CustomStringConvertible {
    case open(path: String, code: Int32, message: String)
    /// The file's `user_version` is not one this build understands (or is 0 with tables present).
    case schemaVersion(found: Int32)
    case sqlite(code: Int32, message: String)
    case unknownTake(String)
    /// `setAudio` was given a file outside the takes folder; history only indexes files inside it.
    case audioOutsideTakesRoot(String)
    /// A re-run was recorded against a take still recording or finalizing.
    case takeInFlight(String)

    public var description: String {
        switch self {
        case .open(let path, let code, let message): "cannot open history at \(path): \(message) (\(code))"
        case .schemaVersion(let found): "history database has schema version \(found); this build reads version \(HistoryStore.schemaVersion) only"
        case .sqlite(let code, let message): "history database error \(code): \(message)"
        case .unknownTake(let id): "no history row for take \(id)"
        case .audioOutsideTakesRoot(let path): "audio file \(path) is outside the takes folder"
        case .takeInFlight(let id): "take \(id) has not finished, so it cannot be re-run"
        }
    }
}

/// A SQLite record of every take, one row per take plus an `attempts` table whose attempt 0 is the
/// original run. One connection; every call holds `lock` for its whole duration, so the class is
/// safe to share across threads. The store logs nothing: rows hold transcripts.
public final class HistoryStore: @unchecked Sendable {
    static let schemaVersion: Int32 = 1
    static let interruptedReason = "interrupted before delivery"

    /// Posted after a take is begun, gets its audio, or reaches an outcome, and after a repair, so
    /// an open History window or popover can refresh. The object is the store; it carries no text.
    /// It arrives on the main queue, after the write that caused it has returned.
    public static let didChange = Notification.Name("VizierHistoryDidChange")

    /// Never posts in the caller's thread. `post` runs every observer before it returns, and for
    /// an observer on the main queue a background poster waits for the main thread. A caller that
    /// holds a lock the main thread wants (`TakeLedger`) then deadlocks and wedges the
    /// app. Posting from a main-queue block runs main-queue observers in place, so no write
    /// ever waits on another thread.
    private func announce() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    private let connection: Connection
    private let lock = NSLock()
    private let takesRoot: URL
    /// Rows still `recording` or `finalizing` when this store opened. Only one Vizier runs, so
    /// their process is gone. Takes begun after open are live and reconcile leaves them alone.
    private let strandedAtOpen: [String]
    private let openedAtMs: Int64

    public static let standardDatabaseURL = VizierPaths.data.appending(path: "history.sqlite")

    public static func openStandard() throws -> HistoryStore {
        try HistoryStore(databaseURL: standardDatabaseURL, takesRoot: TakeStore.standard.root)
    }

    /// Opens an existing history for reading only: nothing is created, migrated, or tightened, a
    /// missing file throws, and every write throws. As any SQLite reader of a WAL database does,
    /// it may create the SHM index beside the file when that is missing.
    public init(readingOnly databaseURL: URL, takesRoot: URL) throws {
        let connection = try Connection(path: databaseURL.path, readOnly: true)
        let version = try connection.int("PRAGMA user_version") ?? 0
        guard version == Int64(Self.schemaVersion) else { throw HistoryError.schemaVersion(found: Int32(clamping: version)) }
        self.connection = connection
        self.takesRoot = takesRoot.standardizedFileURL
        // Nothing to reconcile: this store cannot write.
        self.strandedAtOpen = []
        self.openedAtMs = Self.milliseconds(.now)
    }

    public init(databaseURL: URL, takesRoot: URL) throws {
        // The folder is 0700 and the database 0600; SQLite gives the WAL and SHM files the main
        // file's mode. An install from an older build has all of them tightened here.
        try PrivateFiles.makeDirectory(databaseURL.deletingLastPathComponent())
        PrivateFiles.createFileIfMissing(databaseURL)
        Self.tightenFiles(databaseURL)
        Self.tightenTakes(takesRoot)
        let connection = try Connection(path: databaseURL.path)
        try connection.run("PRAGMA foreign_keys = ON")
        // NORMAL with WAL: every commit is in the log before the call returns, so an app crash
        // loses nothing; only a power loss mid-commit can. FULL would fsync on each of the four or
        // five commits between the stop tap and the paste.
        try connection.run("PRAGMA synchronous = NORMAL")

        // Check the version before anything persistent (WAL is persistent), so a file from a
        // newer or foreign build is refused untouched.
        let version = try connection.int("PRAGMA user_version") ?? 0
        if version == 0 {
            let tables = try connection.int("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('takes', 'attempts')") ?? 0
            guard tables == 0 else { throw HistoryError.schemaVersion(found: 0) }
            try connection.transaction {
                for statement in Self.schema { try connection.run(statement) }
                try connection.run("PRAGMA user_version = 1")
            }
        } else if version != Int64(Self.schemaVersion) {
            throw HistoryError.schemaVersion(found: Int32(clamping: version))
        }

        let mode = try connection.rows("PRAGMA journal_mode = WAL") { $0.text(0) }.first ?? nil
        guard mode?.lowercased() == "wal" else {
            throw HistoryError.open(path: databaseURL.path, code: SQLITE_ERROR, message: "journal mode is \(mode ?? "unknown"), not wal")
        }

        self.connection = connection
        self.takesRoot = takesRoot.standardizedFileURL
        self.strandedAtOpen = try connection.rows("SELECT id FROM takes WHERE outcome IN ('recording', 'finalizing') ORDER BY id") { $0.text(0) ?? "" }
        self.openedAtMs = Self.milliseconds(.now)
    }

    /// The database and its WAL and SHM files, where they exist.
    private static func tightenFiles(_ databaseURL: URL) {
        for suffix in ["", "-wal", "-shm"] { PrivateFiles.tighten(URL(filePath: databaseURL.path + suffix)) }
    }

    /// The takes folder and its month folders, where they exist. Their files are left alone: the
    /// folders above them already keep other users out.
    private static func tightenTakes(_ root: URL) {
        PrivateFiles.tighten(root)
        let months = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for month in months {
            let values = try? month.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true { PrivateFiles.tighten(month) }
        }
    }

    // MARK: Writes

    public func begin(_ draft: TakeDraft) throws {
        try lock.withLock {
            let now = Self.milliseconds(.now)
            try connection.run("""
                INSERT INTO takes (id, started_at_ms, destination_at_start, mode_id,
                    transcriber_engine, transcriber_model, fallback_engine, fallback_model,
                    cleaner_engine, cleaner_model, outcome, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'recording', ?, ?)
                """,
                [.text(draft.id), .integer(Self.milliseconds(draft.startedAt)), .text(draft.destinationAtStart), .text(draft.modeID),
                 .text(draft.transcriberEngine), .text(draft.transcriberModel), .text(draft.fallbackEngine), .text(draft.fallbackModel),
                 .text(draft.cleanerEngine), .text(draft.cleanerModel), .integer(now), .integer(now)])
        }
        announce()
    }

    /// Points the row at its audio. Never touches the outcome, so a cancelled take stays
    /// cancelled when its FLAC finishes later.
    public func setAudio(id: String, path: URL, byteCount: Int64, durationMs: Int) throws {
        guard let relative = relativeAudioPath(path) else { throw HistoryError.audioOutsideTakesRoot(path.path) }
        try lock.withLock {
            let changed = try connection.run(
                "UPDATE takes SET audio_path = ?, audio_bytes = ?, duration_ms = ?, updated_at_ms = ? WHERE id = ?",
                [.text(relative), .integer(byteCount), .integer(Int64(durationMs)), .integer(Self.milliseconds(.now)), .text(id)])
            guard changed == 1 else { throw HistoryError.unknownTake(id) }
        }
        announce()
    }

    /// Merges the non-nil fields into the row; a nil never clears a field. Empty or
    /// whitespace-only text counts as "no text", the same as nil, so it never replaces stored
    /// text (the raw transcript is the take's evidence) and a column with no text stays NULL.
    public func setStages(id: String, stages: TakeStages) throws {
        try lock.withLock {
            let changed = try connection.run("""
                UPDATE takes SET
                    raw_transcript = COALESCE(?1, raw_transcript),
                    cleaned_text = COALESCE(?2, cleaned_text),
                    final_text = COALESCE(?3, final_text),
                    route = COALESCE(?4, route),
                    transcription_ms = COALESCE(?5, transcription_ms),
                    cleanup_ms = COALESCE(?6, cleanup_ms),
                    replacement_ms = COALESCE(?7, replacement_ms),
                    updated_at_ms = ?8
                WHERE id = ?9
                """,
                [.text(Self.someText(stages.raw)), .text(Self.someText(stages.cleaned)), .text(Self.someText(stages.final)), .text(stages.route),
                 .int(stages.transcriptionMs), .int(stages.cleanupMs), .int(stages.replacementMs),
                 .integer(Self.milliseconds(.now)), .text(id)])
            guard changed == 1 else { throw HistoryError.unknownTake(id) }
        }
    }

    /// Records where the take ended up. A terminal outcome also writes attempt 0, a copy of the
    /// take as it stands, in the same transaction; attempt 0 is written once and never updated.
    /// A cancelled take stays cancelled, and a terminal take never moves back to in-flight;
    /// such calls change nothing. Other terminal-to-terminal changes (held to pasted, pasted to
    /// failed) are allowed: ordering them is the caller's job, and the take ledger enforces
    /// first-terminal-wins. Attempt 0 still records only the first terminal outcome.
    /// Nil paste fields and `stoppedAt` leave earlier values.
    public func finish(id: String, stoppedAt: Date?, outcome: TakeOutcome, reason: String?,
                       destinationAtPaste: String?, pasteMethod: String?, pasteMs: Int?) throws {
        try lock.withLock {
            try connection.transaction {
                guard let current = try currentOutcome(id) else { throw HistoryError.unknownTake(id) }
                if current == .cancelled || (current.isTerminal && !outcome.isTerminal) { return }
                let now = Self.milliseconds(.now)
                try connection.run("""
                    UPDATE takes SET
                        stopped_at_ms = COALESCE(?1, stopped_at_ms),
                        destination_at_paste = COALESCE(?2, destination_at_paste),
                        paste_method = COALESCE(?3, paste_method),
                        paste_ms = COALESCE(?4, paste_ms),
                        outcome = ?5, outcome_reason = ?6, updated_at_ms = ?7
                    WHERE id = ?8
                    """,
                    [.integer(stoppedAt.map(Self.milliseconds)), .text(destinationAtPaste), .text(pasteMethod), .int(pasteMs),
                     .text(outcome.rawValue), .text(reason), .integer(now), .text(id)])
                if outcome.isTerminal { try writeAttemptZero(id, now: now) }
            }
        }
        announce()
    }

    /// Repairs the index from the files on disk. Rows stranded in flight at open become failed.
    /// Every CAF or FLAC under the takes folder with no row gets a failed row. A row whose audio
    /// path is missing or gone is pointed at the file found for its id. Deletes nothing, and a
    /// second run changes nothing.
    public func reconcileFiles() throws {
        try lock.withLock {
            let now = Self.milliseconds(.now)
            try connection.transaction {
                for id in strandedAtOpen {
                    let changed = try connection.run("""
                        UPDATE takes SET outcome = 'failed', outcome_reason = ?, updated_at_ms = ?
                        WHERE id = ? AND outcome IN ('recording', 'finalizing')
                          AND NOT EXISTS (SELECT 1 FROM attempts WHERE take_id = takes.id AND attempt_no = 0)
                        """,
                        [.text(Self.interruptedReason), .integer(now), .text(id)])
                    if changed == 1 { try writeAttemptZero(id, now: now) }
                }
            }

            for file in scanTakeFiles() {
                // A take started after this store opened belongs to this process, even if its
                // row failed to write; the next launch indexes it.
                guard let startedMs = Self.parseTakeID(file.id), startedMs < openedAtMs else { continue }
                try connection.transaction {
                    let rows = try connection.rows("SELECT audio_path FROM takes WHERE id = ?", [.text(file.id)]) { $0.text(0) }
                    if let stored = rows.first {
                        if let stored, let url = resolveAudioPath(stored), FileManager.default.fileExists(atPath: url.path) { return }
                        try connection.run("UPDATE takes SET audio_path = ?, audio_bytes = ?, updated_at_ms = ? WHERE id = ?",
                                           [.text(file.relativePath), .integer(file.bytes), .integer(now), .text(file.id)])
                    } else {
                        try connection.run("""
                            INSERT INTO takes (id, started_at_ms, audio_path, audio_bytes, mode_id,
                                transcriber_engine, transcriber_model, outcome, outcome_reason, created_at_ms, updated_at_ms)
                            VALUES (?, ?, ?, ?, 'unknown', 'unknown', 'unknown', 'failed', ?, ?, ?)
                            """,
                            [.text(file.id), .integer(startedMs), .text(file.relativePath), .integer(file.bytes),
                             .text(Self.interruptedReason), .integer(now), .integer(now)])
                        try writeAttemptZero(file.id, now: now)
                    }
                }
            }
        }
        announce()
    }

    /// Adds a finished take from another app, with attempt 0, in one transaction, and returns
    /// true. A take whose id is already in history is left as it is and returns false, so an
    /// import can run again. The row starts without audio; `setAudio` adds it.
    @discardableResult
    public func importTake(_ take: ImportedTake) throws -> Bool {
        guard take.outcome.isTerminal else { throw HistoryError.takeInFlight(take.id) }
        let inserted = try lock.withLock { () throws -> Bool in
            var inserted = false
            try connection.transaction {
                let now = Self.milliseconds(.now)
                let changed = try connection.run("""
                    INSERT OR IGNORE INTO takes (id, started_at_ms, stopped_at_ms, duration_ms, mode_id,
                        transcriber_engine, transcriber_model, cleaner_engine, cleaner_model,
                        raw_transcript, cleaned_text, final_text, transcription_ms, cleanup_ms,
                        outcome, outcome_reason, created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(take.id), .integer(Self.milliseconds(take.startedAt)), .integer(Self.milliseconds(take.stoppedAt)),
                     .integer(Int64(take.durationMs)), .text(take.modeID),
                     .text(take.transcriberEngine), .text(take.transcriberModel), .text(take.cleanerEngine), .text(take.cleanerModel),
                     .text(Self.someText(take.rawTranscript)), .text(Self.someText(take.cleanedText)), .text(Self.someText(take.finalText)),
                     .int(take.transcriptionMs), .int(take.cleanupMs),
                     .text(take.outcome.rawValue), .text(take.outcomeReason), .integer(now), .integer(now)])
                guard changed == 1 else { return }
                try writeAttemptZero(take.id, now: now)
                inserted = true
            }
            return inserted
        }
        if inserted { announce() }
        return inserted
    }

    /// Records a re-run of a finished take as its next attempt and returns it. The take's own row,
    /// and attempt 0, are left as they were. Refuses a take still in flight.
    @discardableResult
    public func addRerun(takeID: String, _ run: RerunDraft, at date: Date = .now) throws -> TakeAttempt {
        let attempt = try lock.withLock { () throws -> TakeAttempt in
            var attempt: TakeAttempt?
            try connection.transaction {
                guard let current = try currentOutcome(takeID) else { throw HistoryError.unknownTake(takeID) }
                guard current.isTerminal else { throw HistoryError.takeInFlight(takeID) }
                // Attempt 0 is the take as it ended; make sure it exists before numbering after it.
                try writeAttemptZero(takeID, now: Self.milliseconds(date))
                let found: [Int64?] = try connection.rows("SELECT COALESCE(MAX(attempt_no), 0) + 1 FROM attempts WHERE take_id = ?",
                                                          [.text(takeID)]) { $0.integer(0) }
                let next: Int = found.first.flatMap { $0 }.map { Int($0) } ?? 1
                try connection.run("""
                    INSERT INTO attempts (take_id, attempt_no, created_at_ms, mode_id,
                        transcriber_engine, transcriber_model, cleaner_engine, cleaner_model,
                        raw_transcript, cleaned_text, final_text, transcription_ms, cleanup_ms, replacement_ms,
                        outcome, outcome_reason)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(takeID), .integer(Int64(next)), .integer(Self.milliseconds(date)), .text(run.modeID),
                     .text(run.transcriberEngine), .text(run.transcriberModel), .text(run.cleanerEngine), .text(run.cleanerModel),
                     .text(Self.someText(run.rawTranscript)), .text(Self.someText(run.cleanedText)), .text(Self.someText(run.finalText)),
                     .int(run.transcriptionMs), .int(run.cleanupMs), .int(run.replacementMs),
                     .text(run.succeeded ? TakeAttempt.transcribed : TakeAttempt.failed), .text(run.reason)])
                attempt = try connection.rows("SELECT \(Self.attemptColumns) FROM attempts WHERE take_id = ? AND attempt_no = ?",
                                              [.text(takeID), .integer(Int64(next))], Self.makeAttempt).first
            }
            guard let attempt else { throw HistoryError.unknownTake(takeID) }
            return attempt
        }
        announce()
        return attempt
    }

    // MARK: Reads

    /// The take's re-runs, oldest first; attempt 0 (the original) is not among them.
    public func reruns(takeID: String) throws -> [TakeAttempt] {
        try lock.withLock {
            try connection.rows("SELECT \(Self.attemptColumns) FROM attempts WHERE take_id = ? AND attempt_no > 0 ORDER BY attempt_no",
                                [.text(takeID)], Self.makeAttempt)
        }
    }

    public func recent(limit: Int) throws -> [TakeRecord] {
        try lock.withLock {
            try connection.rows("SELECT \(Self.columns) FROM takes ORDER BY started_at_ms DESC, id DESC LIMIT ?",
                                [.integer(Int64(max(0, limit)))], makeRecord)
        }
    }

    /// Every word of the query (split on whitespace) must appear somewhere in the take's final,
    /// cleaned, or raw text, or in a re-run's, in any order; each word is a case-insensitive (ASCII) substring, and
    /// `%`, `_`, and `\` in it are literal. An empty query matches every take, including one with
    /// no text at all (a take that failed before any words arrived). Newest first; `before` pages
    /// by start time. An empty outcome set matches nothing; nil matches every outcome.
    public func search(_ query: String, outcomes: Set<TakeOutcome>?,
                       limit: Int, before: Date?, cursor: String? = nil) throws -> [TakeRecord] {
        if let outcomes, outcomes.isEmpty { return [] }
        var values: [SQLValue] = []
        // Placeholders only; every value is bound.
        func bind(_ value: SQLValue) -> String {
            values.append(value)
            return "?\(values.count)"
        }
        var clauses: [String] = []
        for word in Self.searchWords(query) {
            let p = bind(.text("%" + Self.escapeLike(word) + "%"))
            clauses.append("""
                (final_text LIKE \(p) ESCAPE '\\' OR cleaned_text LIKE \(p) ESCAPE '\\' OR raw_transcript LIKE \(p) ESCAPE '\\'
                 OR EXISTS (SELECT 1 FROM attempts a WHERE a.take_id = takes.id AND a.attempt_no > 0
                            AND (a.final_text LIKE \(p) ESCAPE '\\' OR a.cleaned_text LIKE \(p) ESCAPE '\\' OR a.raw_transcript LIKE \(p) ESCAPE '\\')))
                """)
        }
        if let cursor {
            let parts = cursor.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let ms = Int64(parts[0]), !parts[1].isEmpty else {
                throw HistoryError.sqlite(code: 21, message: "invalid history cursor")
            }
            let time = bind(.integer(ms)), id = bind(.text(String(parts[1])))
            clauses.append("(started_at_ms < \(time) OR (started_at_ms = \(time) AND id < \(id)))")
        }
        if let before { clauses.append("started_at_ms < \(bind(.integer(Self.milliseconds(before))))") }
        if let outcomes {
            let placeholders = outcomes.map(\.rawValue).sorted().map { bind(.text($0)) }
            clauses.append("outcome IN (\(placeholders.joined(separator: ", ")))")
        }
        var sql = "SELECT \(Self.columns) FROM takes"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY started_at_ms DESC, id DESC LIMIT \(bind(.integer(Int64(max(0, limit)))))"
        return try lock.withLock { try connection.rows(sql, values, makeRecord) }
    }

    /// The query's words: split on whitespace, empties dropped.
    static func searchWords(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Every take, whatever its outcome.
    public func count() throws -> Int {
        try lock.withLock { Int(try connection.int("SELECT count(*) FROM takes") ?? 0) }
    }

    /// The bytes of saved audio across every take, as recorded on the rows.
    public func totalAudioBytes() throws -> Int64 {
        try lock.withLock { try connection.int("SELECT COALESCE(SUM(audio_bytes), 0) FROM takes") ?? 0 }
    }

    public func record(id: String) throws -> TakeRecord? {
        try lock.withLock {
            try connection.rows("SELECT \(Self.columns) FROM takes WHERE id = ?", [.text(id)], makeRecord).first
        }
    }

    // MARK: Internals (callers hold `lock`)

    private func currentOutcome(_ id: String) throws -> TakeOutcome? {
        try connection.rows("SELECT outcome FROM takes WHERE id = ?", [.text(id)]) { $0.text(0).flatMap(TakeOutcome.init(rawValue:)) }.first ?? nil
    }

    /// Copies the take as it stands into attempt 0, unless attempt 0 already exists.
    private func writeAttemptZero(_ id: String, now: Int64) throws {
        try connection.run("""
            INSERT OR IGNORE INTO attempts (take_id, attempt_no, created_at_ms, mode_id,
                transcriber_engine, transcriber_model, cleaner_engine, cleaner_model,
                raw_transcript, cleaned_text, final_text, transcription_ms, cleanup_ms, replacement_ms,
                outcome, outcome_reason)
            SELECT id, 0, ?, mode_id, transcriber_engine, transcriber_model, cleaner_engine, cleaner_model,
                raw_transcript, cleaned_text, final_text, transcription_ms, cleanup_ms, replacement_ms,
                outcome, outcome_reason
            FROM takes WHERE id = ?
            """,
            [.integer(now), .text(id)])
    }

    private static let columns = """
        id, started_at_ms, stopped_at_ms, destination_at_start, destination_at_paste,
        audio_path, audio_bytes, duration_ms, mode_id, transcriber_engine, transcriber_model,
        fallback_engine, fallback_model, cleaner_engine, cleaner_model,
        raw_transcript, cleaned_text, final_text, route, transcription_ms, cleanup_ms, replacement_ms, paste_ms,
        outcome, outcome_reason, paste_method, verbatim_baseline, verbatim_baseline_model, verbatim_baseline_ms,
        (SELECT final_text FROM attempts WHERE take_id = takes.id AND attempt_no > 0 AND final_text IS NOT NULL
         ORDER BY attempt_no DESC LIMIT 1)
        """

    private static let attemptColumns = """
        take_id, attempt_no, created_at_ms, mode_id, transcriber_engine, transcriber_model, cleaner_engine, cleaner_model,
        raw_transcript, cleaned_text, final_text, transcription_ms, cleanup_ms, replacement_ms, outcome, outcome_reason
        """

    private static func makeAttempt(_ row: Row) -> TakeAttempt {
        TakeAttempt(
            takeID: row.text(0) ?? "", number: row.int(1) ?? 0, createdAt: date(row.integer(2) ?? 0), modeID: row.text(3) ?? "",
            transcriberEngine: row.text(4) ?? "", transcriberModel: row.text(5) ?? "", cleanerEngine: row.text(6), cleanerModel: row.text(7),
            rawTranscript: row.text(8), cleanedText: row.text(9), finalText: row.text(10),
            transcriptionMs: row.int(11), cleanupMs: row.int(12), replacementMs: row.int(13),
            outcome: row.text(14) ?? "", outcomeReason: row.text(15))
    }

    private func makeRecord(_ row: Row) -> TakeRecord {
        TakeRecord(
            id: row.text(0) ?? "",
            startedAt: Self.date(row.integer(1) ?? 0),
            stoppedAt: row.integer(2).map(Self.date),
            destinationAtStart: row.text(3),
            destinationAtPaste: row.text(4),
            audioPath: row.text(5).flatMap(resolveAudioPath),
            audioBytes: row.integer(6),
            durationMs: row.int(7),
            modeID: row.text(8) ?? "",
            transcriberEngine: row.text(9) ?? "",
            transcriberModel: row.text(10) ?? "",
            fallbackEngine: row.text(11),
            fallbackModel: row.text(12),
            cleanerEngine: row.text(13),
            cleanerModel: row.text(14),
            rawTranscript: row.text(15),
            cleanedText: row.text(16),
            finalText: row.text(17),
            route: row.text(18),
            transcriptionMs: row.int(19),
            cleanupMs: row.int(20),
            replacementMs: row.int(21),
            pasteMs: row.int(22),
            outcome: row.text(23).flatMap(TakeOutcome.init(rawValue:)) ?? .failed,
            outcomeReason: row.text(24),
            pasteMethod: row.text(25),
            verbatimBaseline: row.text(26),
            verbatimBaselineModel: row.text(27),
            verbatimBaselineMs: row.int(28),
            rerunText: row.text(29))
    }

    // MARK: Paths

    /// The path of `url` relative to the takes folder, or nil if it is not strictly inside it.
    /// Both sides are symlink-resolved (the temp folder is `/var` → `/private/var`).
    func relativeAudioPath(_ url: URL) -> String? {
        let root = takesRoot.resolvingSymlinksInPath().pathComponents
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
        let name = url.standardizedFileURL.lastPathComponent
        guard parent.starts(with: root), !name.isEmpty, name != "/", name != ".", name != ".." else { return nil }
        return (Array(parent.dropFirst(root.count)) + [name]).joined(separator: "/")
    }

    /// The absolute URL for a stored relative path, or nil if the path is absolute, empty, has an
    /// empty, `.`, or `..` component, or once symlinks are followed lands outside the takes folder
    /// (a linked file or a linked month folder). The store only ever writes paths to files
    /// `TakeStore` created, so nil here means the folder was tampered with; the row keeps its text
    /// and only playback is withheld.
    func resolveAudioPath(_ stored: String) -> URL? {
        let parts = stored.split(separator: "/", omittingEmptySubsequences: false)
        guard !stored.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let url = takesRoot.appending(path: stored)
        let root = takesRoot.resolvingSymlinksInPath().pathComponents
        let resolved = url.resolvingSymlinksInPath().pathComponents
        guard resolved.count > root.count, resolved.starts(with: root) else { return nil }
        return url
    }

    private struct FoundFile {
        let id: String
        let relativePath: String
        let bytes: Int64
    }

    /// Recording (CAF on macOS, WAV elsewhere) and FLAC files one level under each month folder, the
    /// layout `TakeStore` writes. When both exist for an id the recording wins: `TakeStore.finishAudio`
    /// removes it only after the FLAC verifies, so a surviving recording is the copy known to be whole.
    private func scanTakeFiles() -> [FoundFile] {
        let fm = FileManager.default
        guard let months = try? fm.contentsOfDirectory(at: takesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { return [] }
        var byID: [String: FoundFile] = [:]
        for month in months where (try? month.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let files = (try? fm.contentsOfDirectory(at: month, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles)) ?? []
            for file in files where file.pathExtension == TakeFiles.recordingExtension || file.pathExtension == "flac" {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
                let id = file.deletingPathExtension().lastPathComponent
                let found = FoundFile(id: id, relativePath: month.lastPathComponent + "/" + file.lastPathComponent, bytes: Int64(values.fileSize ?? 0))
                if byID[id] == nil || file.pathExtension == TakeFiles.recordingExtension { byID[id] = found }
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    // MARK: Values

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// Milliseconds since 1970 for a take id in `TakeStore.newTake`'s form
    /// (`2026-09-25T22-35-49.202Z`), or nil if the id is not exactly that form.
    static func parseTakeID(_ id: String) -> Int64? {
        guard id.hasSuffix("Z") else { return nil }
        let numbers = id.dropLast().split(whereSeparator: { "-T.".contains($0) })
            .compactMap { field in field.allSatisfy { $0.isASCII && $0.isNumber } ? Int(field) : nil }
        guard numbers.count == 7 else { return nil }
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2],
                                        hour: numbers[3], minute: numbers[4], second: numbers[5])
        guard let date = calendar.date(from: components) else { return nil }
        let milliseconds = Int64(date.timeIntervalSince1970) * 1000 + Int64(numbers[6])
        // Reformat the way TakeStore does and require an exact match, which rejects out-of-range
        // fields that Calendar would silently roll over.
        let c = calendar.dateComponents(in: utc, from: date)
        let canonical = String(format: "%04d-%02d-%02dT%02d-%02d-%02d.%03dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, numbers[6])
        return canonical == id ? milliseconds : nil
    }

    /// Nil for nil, empty, or whitespace-only text; the text unchanged otherwise.
    static func someText(_ text: String?) -> String? {
        guard let text, !text.allSatisfy(\.isWhitespace) else { return nil }
        return text
    }

    static func escapeLike(_ query: String) -> String {
        var escaped = ""
        for character in query {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    static let schema = [
        """
        CREATE TABLE takes (
          id TEXT PRIMARY KEY, started_at_ms INTEGER NOT NULL, stopped_at_ms INTEGER,
          destination_at_start TEXT, destination_at_paste TEXT,
          audio_path TEXT, audio_bytes INTEGER, duration_ms INTEGER,
          mode_id TEXT NOT NULL, transcriber_engine TEXT NOT NULL, transcriber_model TEXT NOT NULL,
          fallback_engine TEXT, fallback_model TEXT, cleaner_engine TEXT, cleaner_model TEXT,
          raw_transcript TEXT, cleaned_text TEXT, final_text TEXT,
          route TEXT CHECK(route IN ('live','batch') OR route IS NULL),
          transcription_ms INTEGER, cleanup_ms INTEGER, replacement_ms INTEGER, paste_ms INTEGER,
          outcome TEXT NOT NULL CHECK(outcome IN
            ('recording','finalizing','pasted','rerouted','held','failed','cancelled')),
          outcome_reason TEXT, paste_method TEXT,
          verbatim_baseline TEXT, verbatim_baseline_model TEXT, verbatim_baseline_ms INTEGER,
          created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL
        )
        """,
        "CREATE INDEX takes_recent ON takes(started_at_ms DESC, id DESC)",
        "CREATE INDEX takes_outcome_recent ON takes(outcome, started_at_ms DESC)",
        """
        CREATE TABLE attempts (
          take_id TEXT NOT NULL REFERENCES takes(id) ON DELETE RESTRICT,
          attempt_no INTEGER NOT NULL,
          created_at_ms INTEGER NOT NULL, mode_id TEXT NOT NULL,
          transcriber_engine TEXT NOT NULL, transcriber_model TEXT NOT NULL,
          cleaner_engine TEXT, cleaner_model TEXT,
          raw_transcript TEXT, cleaned_text TEXT, final_text TEXT,
          transcription_ms INTEGER, cleanup_ms INTEGER, replacement_ms INTEGER,
          outcome TEXT NOT NULL, outcome_reason TEXT,
          PRIMARY KEY(take_id, attempt_no)
        )
        """,
    ]
}

// MARK: - SQLite

private enum SQLValue {
    case text(String?)
    case integer(Int64?)

    static func int(_ value: Int?) -> SQLValue { .integer(value.map(Int64.init)) }
}

private struct Row {
    let statement: OpaquePointer

    func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let bytes = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    func integer(_ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    func int(_ column: Int32) -> Int? { integer(column).map { Int(clamping: $0) } }
}

/// One SQLite connection. Not thread-safe by itself; `HistoryStore` serializes every use.
private final class Connection {
    let handle: OpaquePointer

    init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let access = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let code = sqlite3_open_v2(path, &handle, access | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(handle)
            throw HistoryError.open(path: path, code: code, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    private func error(_ code: Int32) -> HistoryError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw error(code) }
        // SQLITE_TRANSIENT: SQLite copies the bytes before the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32 = switch value {
            case .text(let text?): sqlite3_bind_text(statement, index, text, Int32(text.utf8.count), transient)
            case .integer(let number?): sqlite3_bind_int64(statement, index, number)
            case .text(nil), .integer(nil): sqlite3_bind_null(statement, index)
            }
            guard bound == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw error(bound)
            }
        }
        return statement
    }

    /// Runs a statement to completion and returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error(code) }
        }
        return Int(sqlite3_changes(handle))
    }

    func rows<T>(_ sql: String, _ values: [SQLValue] = [], _ read: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw error(code) }
            result.append(try read(Row(statement: statement)))
        }
    }

    func int(_ sql: String) throws -> Int64? {
        try rows(sql) { $0.integer(0) }.first ?? nil
    }

    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            _ = try? run("ROLLBACK")
            throw error
        }
    }
}
