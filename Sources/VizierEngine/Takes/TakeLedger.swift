import Foundation
#if canImport(os)
import os
#endif

/// One take's history row and the text the take has so far. `TakeController` calls it at every
/// stage; each call writes through to the store before it returns, so text that exists is on disk
/// before the take can be cancelled, crash, or fail past it.
///
/// Rules:
/// - A store error is logged (never with transcript text) and swallowed. History failing never
///   fails the take.
/// - The first terminal call (`cancel()` or `conclude`) wins. Later `conclude` calls are ignored;
///   later stage calls still write, so a final that arrives after a cancel is kept.
/// - Text is never cleared. Blank text counts as no text and never replaces what is held.
/// - With a nil store every call still tracks `texts` and `isConcluded`, and writes nothing.
///
/// Called from the main actor and from the audio-saving task, so every call holds `lock`, store
/// write included; that also keeps the terminal check and its write in one step. The main thread
/// can wait on `lock`, so nothing done under it may wait on the main thread: store writes only
/// touch SQLite, and the store posts its change notification asynchronously for that reason.
public final class TakeLedger: @unchecked Sendable {
    public let id: String
    private let store: HistoryStore?
    private let lock = NSLock()
    private var raw: String?
    private var cleanedText: String?
    private var final: String?
    private var concluded = false
    private var stoppedRecorded = false
    /// Store calls that threw. Guarded by `lock`; read through `writeFailures`.
    private var failures = 0

    private static let log = Logger(subsystem: "net.praxient.dictum", category: "history")

    /// A nil store means history is unavailable; every call is then a no-op and the take proceeds.
    public init(store: HistoryStore?, draft: TakeDraft) {
        id = draft.id
        self.store = store
        write("begin") { try $0.begin(draft) }
    }

    /// The take stopped recording; the row moves to `finalizing` with its stop time. Ignored once
    /// the take has concluded.
    public func stopped(at date: Date = .now) {
        lock.withLock {
            guard !concluded, !stoppedRecorded else { return }
            stoppedRecorded = true
            writeLocked("stop") {
                try $0.finish(id: self.id, stoppedAt: date, outcome: .finalizing, reason: nil,
                              destinationAtPaste: nil, pasteMethod: nil, pasteMs: nil)
            }
        }
    }

    public func audioSaved(path: URL, byteCount: Int64, durationMs: Int) {
        write("audio") { try $0.setAudio(id: self.id, path: path, byteCount: byteCount, durationMs: durationMs) }
    }

    /// The transcript as the engine gave it. `route` is "live" or "batch".
    public func transcript(raw text: String, route: String, transcriptionMs: Int?) {
        stages("transcript", raw: text, route: route, transcriptionMs: transcriptionMs)
    }

    /// The text after the cleanup pass or the filler filter. A nil text records only the timing,
    /// for a cleanup pass that ran and did not hold.
    public func cleaned(_ text: String?, cleanupMs: Int?) {
        stages("cleaned", cleaned: text, cleanupMs: cleanupMs)
    }

    /// The text after word replacements: what is pasted.
    public func finalText(_ text: String, replacementMs: Int?) {
        stages("final", final: text, replacementMs: replacementMs)
    }

    /// Records where the take ended up, unless it already concluded. `outcome` must be terminal.
    public func conclude(_ outcome: TakeOutcome, reason: String?, destination: String?, pasteMethod: String?, pasteMs: Int?) {
        guard outcome.isTerminal else {
            Self.log.error("take \(self.id, privacy: .public) history: conclude ignored a non-terminal outcome \(outcome.rawValue, privacy: .public)")
            return
        }
        terminal(outcome, reason: reason, destination: destination, pasteMethod: pasteMethod, pasteMs: pasteMs)
    }

    /// Terminal: records `cancelled` with no reason and keeps every text already written.
    public func cancel() {
        terminal(.cancelled, reason: nil, destination: nil, pasteMethod: nil, pasteMs: nil)
    }

    /// What the take has, whether or not history is writing.
    public var texts: (raw: String?, cleaned: String?, final: String?) {
        lock.withLock { (raw, cleanedText, final) }
    }

    public var isConcluded: Bool { lock.withLock { concluded } }

    /// Store calls that threw. For tests: a failure is otherwise visible only in the log.
    var writeFailures: Int { lock.withLock { failures } }

    // MARK: Internals

    private func terminal(_ outcome: TakeOutcome, reason: String?, destination: String?, pasteMethod: String?, pasteMs: Int?) {
        lock.withLock {
            guard !concluded else { return }
            concluded = true
            // A take concluded before it stopped (a cancel while recording, a mic failure) ends now.
            let stoppedAt: Date? = stoppedRecorded ? nil : .now
            stoppedRecorded = true
            writeLocked(outcome.rawValue) {
                try $0.finish(id: self.id, stoppedAt: stoppedAt, outcome: outcome, reason: reason,
                              destinationAtPaste: destination, pasteMethod: pasteMethod, pasteMs: pasteMs)
            }
        }
    }

    private func stages(_ stage: String, raw: String? = nil, cleaned: String? = nil, final: String? = nil, route: String? = nil,
                        transcriptionMs: Int? = nil, cleanupMs: Int? = nil, replacementMs: Int? = nil) {
        let raw = HistoryStore.someText(raw)
        let cleaned = HistoryStore.someText(cleaned)
        let final = HistoryStore.someText(final)
        lock.withLock {
            if let raw { self.raw = raw }
            if let cleaned { self.cleanedText = cleaned }
            if let final { self.final = final }
            writeLocked(stage) {
                try $0.setStages(id: self.id, stages: TakeStages(
                    raw: raw, cleaned: cleaned, final: final, route: route,
                    transcriptionMs: transcriptionMs, cleanupMs: cleanupMs, replacementMs: replacementMs))
            }
        }
    }

    private func write(_ stage: String, _ body: (HistoryStore) throws -> Void) {
        lock.withLock { writeLocked(stage, body) }
    }

    /// Caller holds `lock`. HistoryError descriptions carry ids, paths, and SQLite messages, never
    /// row values, so the error is safe to log.
    private func writeLocked(_ stage: String, _ body: (HistoryStore) throws -> Void) {
        guard let store else { return }
        do {
            try body(store)
        } catch {
            failures += 1
            Self.log.error("take \(self.id, privacy: .public) history \(stage, privacy: .public) write failed: \(String(describing: error), privacy: .private)")
        }
    }
}

/// The settled part of a live transcript across the whole take, for pasting when the live final
/// and batch both fail. `WordLine` judges settledness for the strip but trims its row on a long
/// take, so this works on the full text: every final, then the interim words up to the last one
/// that has held its place through one revision and is not among the last `WordLine.turningWords`.
///
/// One deliberate difference from the strip: the strip withholds an interim word that just
/// changed, while this keeps it, as the engine's current guess, when a settled word follows it.
/// The pasted sentence then has no gap.
public struct SettledTranscript: Sendable, Equatable {
    private var finals: [String] = []
    private var interim: [String] = []
    private var settledInterim = 0

    public init() {}

    public mutating func update(settled: String, pending: String) {
        let next = Self.words(pending)
        var count = 0
        for (index, word) in next.enumerated() where index < interim.count && interim[index] == word && index < next.count - WordLine.turningWords {
            count = index + 1
        }
        finals = Self.words(settled)
        interim = next
        settledInterim = count
    }

    /// Empty when nothing has settled.
    public var text: String {
        (finals + interim.prefix(settledInterim)).joined(separator: " ")
    }

    /// The settled words to paste in place of `transcript` when it is missing or blank (a live
    /// final that failed or came back empty, a batch answer with no words). Nil when the
    /// transcript has words or nothing has settled.
    public func standIn(for transcript: String?) -> String? {
        guard transcript?.allSatisfy(\.isWhitespace) ?? true else { return nil }
        let text = text
        return text.isEmpty ? nil : text
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
