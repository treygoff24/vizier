import Darwin
import Foundation
import SQLite3

/// One take from VoiceInk's history, as its Core Data store keeps it. The shape was read from
/// VoiceInk's `default.store`: a `ZTRANSCRIPTION` table whose `ZTIMESTAMP` is when
/// the recording ended (it matched the WAV's modification time, and its creation time was
/// `ZDURATION` earlier), in seconds since 2001.
public struct VoiceInkTake: Sendable, Equatable {
    public var endedAt: Date
    public var durationSeconds: Double
    public var text: String?
    public var enhancedText: String?
    public var transcriptionModel: String?
    public var enhancementModel: String?
    public var modeName: String?
    /// `completed`, `canceled`, `failed`, or `pending`.
    public var status: String?
    public var audioFile: URL?
    public var transcriptionSeconds: Double?
    public var enhancementSeconds: Double?

    public init(endedAt: Date, durationSeconds: Double, text: String?, enhancedText: String?, transcriptionModel: String?,
                enhancementModel: String?, modeName: String?, status: String?, audioFile: URL?,
                transcriptionSeconds: Double?, enhancementSeconds: Double?) {
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.text = text
        self.enhancedText = enhancedText
        self.transcriptionModel = transcriptionModel
        self.enhancementModel = enhancementModel
        self.modeName = modeName
        self.status = status
        self.audioFile = audioFile
        self.transcriptionSeconds = transcriptionSeconds
        self.enhancementSeconds = enhancementSeconds
    }
}

public enum VoiceInkImportError: Error, CustomStringConvertible {
    case open(String)
    case read(String)

    public var description: String {
        switch self {
        case .open(let message): "cannot open VoiceInk's history: \(message)"
        case .read(let message): "cannot read VoiceInk's history: \(message)"
        }
    }
}

/// Brings VoiceInk's history into Vizier's: each VoiceInk take becomes a finished Vizier take with
/// its text, times, and models, and its WAV becomes the take's FLAC so Re-run works on it.
/// VoiceInk's files are only read. A take already in Vizier's history (same id, from the same
/// start time) is skipped, so the import can run again and adds only what is new.
public enum VoiceInkImport {
    public static let standardFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/com.prakashjoshipax.VoiceInk", directoryHint: .isDirectory)
    /// The mode and engine every imported take carries, so History can name where it came from.
    public static let modeID = "voiceink"
    public static let engine = "voiceink"

    /// Seconds from 1970 to Core Data's reference date, 2001-01-01.
    static let coreDataEpoch = 978_307_200.0
    /// The timestamps a row may carry, in Core Data seconds: 2001 up to 2100. A row outside it, or
    /// not a finite number, is damaged and skipped like a row with no timestamp.
    static let timestampRange = 0.0...3_124_137_600.0
    /// Durations and stage times are kept from zero to a day. Anything else (negative, infinite,
    /// or absurd) is dropped before it reaches an integer conversion that would trap.
    static let secondsRange = 0.0...86_400.0

    static func seconds(_ value: Double?) -> Double? {
        value.flatMap { secondsRange.contains($0) ? $0 : nil }
    }

    static func milliseconds(_ value: Double?) -> Int? {
        seconds(value).map { Int(($0 * 1000).rounded()) }
    }

    /// Every take in VoiceInk's store, oldest first. Opens the file read-only.
    public static func read(store: URL) throws -> [VoiceInkTake] {
        var handle: OpaquePointer?
        let uri = "file:\(store.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? store.path)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            sqlite3_close(handle)
            throw VoiceInkImportError.open(message)
        }
        defer { sqlite3_close(handle) }
        let sql = """
            SELECT ZTIMESTAMP, ZDURATION, ZTEXT, ZENHANCEDTEXT, ZTRANSCRIPTIONMODELNAME, ZAIENHANCEMENTMODELNAME,
                   ZMODENAME, ZTRANSCRIPTIONSTATUS, ZAUDIOFILEURL, ZTRANSCRIPTIONDURATION, ZENHANCEMENTDURATION
            FROM ZTRANSCRIPTION WHERE ZTIMESTAMP IS NOT NULL ORDER BY ZTIMESTAMP
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VoiceInkImportError.read(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        func number(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }
        var takes: [VoiceInkTake] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw VoiceInkImportError.read(String(cString: sqlite3_errmsg(handle))) }
            guard let timestamp = number(0), timestampRange.contains(timestamp) else { continue }
            takes.append(VoiceInkTake(
                endedAt: Date(timeIntervalSince1970: timestamp + coreDataEpoch),
                durationSeconds: seconds(number(1)) ?? 0,
                text: text(2), enhancedText: text(3), transcriptionModel: text(4), enhancementModel: text(5),
                modeName: text(6), status: text(7), audioFile: text(8).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil },
                transcriptionSeconds: seconds(number(9)), enhancementSeconds: seconds(number(10))))
        }
        return takes
    }

    /// The Vizier history row for a VoiceInk take. The id is the start time, in `TakeStore`'s
    /// form. The final text is VoiceInk's enhanced text when it has one, else its transcript.
    public static func record(_ take: VoiceInkTake) -> ImportedTake {
        let startedAt = take.endedAt.addingTimeInterval(-(seconds(take.durationSeconds) ?? 0))
        let raw = HistoryStore.someText(take.text)
        let enhanced = HistoryStore.someText(take.enhancedText)
        let outcome: TakeOutcome
        var reason = "Imported from VoiceInk"
        switch take.status {
        case "completed": outcome = .pasted
        case "canceled": outcome = .cancelled
        case "failed": outcome = .failed
        default:
            outcome = .failed
            reason += "; it never finished there (\(take.status ?? "no status"))"
        }
        if let mode = HistoryStore.someText(take.modeName) { reason += " (mode: \(mode))" }
        return ImportedTake(
            id: TakeStore.takeID(startedAt), startedAt: startedAt, stoppedAt: take.endedAt,
            durationMs: milliseconds(take.durationSeconds) ?? 0, modeID: modeID,
            transcriberEngine: engine, transcriberModel: HistoryStore.someText(take.transcriptionModel) ?? "unknown",
            cleanerEngine: enhanced == nil ? nil : engine, cleanerModel: enhanced == nil ? nil : HistoryStore.someText(take.enhancementModel),
            rawTranscript: raw, cleanedText: enhanced, finalText: enhanced ?? raw,
            transcriptionMs: milliseconds(take.transcriptionSeconds),
            cleanupMs: enhanced == nil ? nil : milliseconds(take.enhancementSeconds),
            outcome: outcome, outcomeReason: reason)
    }

    /// The take's recording, when it is a regular file inside the `Recordings` folder beside
    /// `store` once every symlink is resolved; nil otherwise. The store's rows name the file, so
    /// without this a damaged or crafted store could make the import read any file, a device, or
    /// a pipe that never ends. Returns the resolved path, which is the one to open.
    public static func recording(_ take: VoiceInkTake, store: URL) -> URL? {
        guard let audio = take.audioFile, audio.isFileURL else { return nil }
        let folder = store.deletingLastPathComponent().appending(path: "Recordings").standardizedFileURL.resolvingSymlinksInPath()
        let resolved = audio.standardizedFileURL.resolvingSymlinksInPath()
        let inside = folder.pathComponents
        guard resolved.pathComponents.count > inside.count, Array(resolved.pathComponents.prefix(inside.count)) == inside else { return nil }
        var info = stat()
        guard lstat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return resolved
    }

    /// What `run` would import, counted without writing anything.
    public struct DryRun: Sendable, Equatable {
        public var found = 0
        /// Takes not yet in Vizier's history.
        public var new = 0
        /// Of those, the ones with a recording `run` would read, and its total size.
        public var audioFiles = 0
        public var audioBytes: Int64 = 0
    }

    /// Counts what `run` would import. Vizier's history is opened read-only, and a history that
    /// does not exist yet counts as empty: the dry run never creates it.
    public static func dryRun(store: URL, historyURL: URL, takesRoot: URL) throws -> DryRun {
        let found = try read(store: store)
        let history = FileManager.default.fileExists(atPath: historyURL.path)
            ? try HistoryStore(readingOnly: historyURL, takesRoot: takesRoot) : nil
        var result = DryRun(found: found.count)
        for take in found where try history?.record(id: record(take).id) == nil {
            result.new += 1
            if let wav = recording(take, store: store), let size = try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? NSNumber {
                result.audioFiles += 1
                result.audioBytes += size.int64Value
            }
        }
        return result
    }

    public struct Summary: Sendable, Equatable {
        public var found = 0
        public var imported = 0
        public var alreadyThere = 0
        public var withAudio = 0
        /// Imported with text only: VoiceInk's WAV was missing or would not convert.
        public var audioFailed = 0
        public var audioSkipped = 0
    }

    /// Imports every VoiceInk take not already in history. With `copyAudio`, each imported take's
    /// WAV is encoded to FLAC in the takes folder after its row is written, so a crash between
    /// the two leaves a row the next launch's reconcile can point at the file. Writes no text to
    /// any log; `progress` gets counts only.
    public static func run(store: URL, history: HistoryStore, takes: TakeStore, copyAudio: Bool,
                           progress: (Summary) -> Void = { _ in }) throws -> Summary {
        var summary = Summary()
        let found = try read(store: store)
        summary.found = found.count
        for (index, take) in found.enumerated() {
            let record = record(take)
            if try history.importTake(record) {
                summary.imported += 1
                if copyAudio {
                    if let wav = recording(take, store: store), let files = try? takes.files(forID: record.id) {
                        do {
                            try takes.importAudio(from: wav, to: files)
                            let bytes = (try FileManager.default.attributesOfItem(atPath: files.flac.path)[.size] as? NSNumber)?.int64Value ?? 0
                            try history.setAudio(id: record.id, path: files.flac, byteCount: bytes, durationMs: record.durationMs)
                            summary.withAudio += 1
                        } catch {
                            // A half-written FLAC would be adopted by the next launch's reconcile.
                            try? FileManager.default.removeItem(at: files.flac)
                            summary.audioFailed += 1
                        }
                    } else {
                        summary.audioFailed += 1
                    }
                } else {
                    summary.audioSkipped += 1
                }
            } else {
                summary.alreadyThere += 1
            }
            if index % 100 == 99 { progress(summary) }
        }
        return summary
    }
}
