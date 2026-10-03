import Foundation
import Testing
@testable import VizierEngine

/// A batch transcriber that answers from a script and remembers the file it was given.
private final class ScriptedBatch: BatchTranscriber, @unchecked Sendable {
    let answer: Result<BatchTranscript, BatchError>
    private(set) var asked: [URL] = []

    init(_ answer: Result<BatchTranscript, BatchError>) { self.answer = answer }

    func transcribeReporting(_ audio: URL) async throws -> BatchReport {
        asked.append(audio)
        let result = try answer.get()
        return BatchReport(route: .scribe, bytes: 0, uploadSeconds: 0, transcriptionSeconds: 0, remoteDeleted: nil, result: result, retried: false)
    }
}

private struct ScriptedCleaner: TextCleaner {
    let answer: Result<String, CleanupError>
    func clean(_ transcript: String) async throws -> String { try answer.get() }
}

@Suite struct RerunTests {
    private let flac = URL(fileURLWithPath: "/tmp/take.flac")

    private func plan(_ batch: ScriptedBatch, cleaner: ScriptedCleaner? = nil, fillers: Bool = false,
                      rules: [ReplacementRule] = []) throws -> Rerun.Plan {
        Rerun.Plan(modeID: "m", transcriber: batch, transcriberEngine: "elevenlabs-scribe-batch", transcriberModel: "scribe_v2",
                   cleanup: cleaner.map { .init(cleaner: $0, engine: "gemini-generate", model: "flash-lite", timeout: .seconds(5)) },
                   removeFillers: fillers, replacer: try WordReplacer(rules: rules))
    }

    @Test func aRerunTranscribesCleansDropsFillersAndReplacesInOrder() async throws {
        let batch = ScriptedBatch(.success(BatchTranscript(text: "um so the shipping list is due", truncated: false)))
        let cleaner = ScriptedCleaner(answer: .success("Um, so the shipping list is due."))
        let rules = [ReplacementRule(variants: ["shipping list"], replacement: "Shipping List")]
        let draft = await Rerun.run(flac, plan: try plan(batch, cleaner: cleaner, fillers: true, rules: rules))

        #expect(batch.asked == [flac])
        #expect(draft.succeeded)
        #expect(draft.reason == nil)
        #expect(draft.rawTranscript == "um so the shipping list is due")
        // Cleanup first, then the filler filter, then replacements: the final has all three.
        #expect(draft.cleanedText == FillerFilter.apply(to: "Um, so the shipping list is due."))
        #expect(draft.finalText == draft.cleanedText?.replacingOccurrences(of: "shipping list", with: "Shipping List"))
        #expect(draft.finalText?.contains("Shipping List") == true)
        #expect(draft.finalText?.lowercased().contains("um") == false)
        #expect(draft.cleanerModel == "flash-lite" && draft.transcriberModel == "scribe_v2" && draft.modeID == "m")
        #expect(draft.transcriptionMs != nil && draft.cleanupMs != nil)
    }

    @Test func aFailedCleanupKeepsTheRawTranscriptWithANote() async throws {
        let batch = ScriptedBatch(.success(BatchTranscript(text: "ship it", truncated: false)))
        let cleaner = ScriptedCleaner(answer: .failure(.http(status: 500, message: "down")))
        let draft = await Rerun.run(flac, plan: try plan(batch, cleaner: cleaner))
        #expect(draft.succeeded)
        #expect(draft.finalText == "ship it")
        #expect(draft.cleanedText == nil)
        #expect(draft.reason?.contains("raw transcript was kept") == true)
    }

    @Test func failuresComeBackAsPlainReasonsAndNeverThrow() async throws {
        let refused = await Rerun.run(flac, plan: try plan(ScriptedBatch(.failure(.http(status: 401, message: "bad key")))))
        #expect(!refused.succeeded && refused.finalText == nil)
        #expect(refused.reason?.hasPrefix("The transcription failed") == true)

        let long = await Rerun.run(flac, plan: try plan(ScriptedBatch(.failure(.tooLong(seconds: 4_000)))))
        #expect(!long.succeeded && long.reason == Rerun.tooLong)

        let silent = await Rerun.run(flac, plan: try plan(ScriptedBatch(.success(BatchTranscript(text: "  ...  ", truncated: false)))))
        #expect(!silent.succeeded && silent.reason == Rerun.noSpeech && silent.finalText == nil)

        let batch = ScriptedBatch(.success(BatchTranscript(text: "words", truncated: false)))
        let caf = await Rerun.run(URL(fileURLWithPath: "/tmp/take.caf"), plan: try plan(batch))
        #expect(!caf.succeeded && caf.reason == Rerun.needsFLAC)
        #expect(batch.asked.isEmpty)

        let cut = await Rerun.run(flac, plan: try plan(ScriptedBatch(.success(BatchTranscript(text: "words and", truncated: true)))))
        #expect(cut.succeeded && cut.reason?.contains("output limit") == true)
    }

    @Test func thePlanUsesTheModesBatchEngineAndItsKey() throws {
        var asked: [String] = []
        let config = VizierConfig()
        let scribe = VizierConfig.Mode(id: "s", name: "Scribe Batch", transcriber: VizierConfig.Mode.scribe.transcriber,
                                       fallback: .init(engine: "elevenlabs-scribe-batch", model: "scribe_v2", mode: "verbatim"))
        let plan = try Rerun.plan(mode: scribe, config: config) { asked.append($0); return "k" }
        #expect(asked == ["elevenlabs"])
        #expect(plan.transcriber is ScribeBatchTranscriber && plan.transcriberModel == "scribe_v2" && plan.cleanup == nil)

        asked = []
        let clean = try Rerun.plan(mode: .geminiClean, config: config) { asked.append($0); return "k" }
        #expect(asked == ["gemini", "gemini"])
        #expect(clean.transcriber is GeminiBatchTranscriber && clean.cleanup?.model == VizierConfig.Mode.geminiClean.cleanup?.model)

        // No Gemini key for cleanup: the run goes ahead without it, and says so.
        let skipped = try Rerun.plan(mode: .geminiClean.withFallback(scribe.fallback), config: config) { $0 == "gemini" ? nil : "k" }
        #expect(skipped.cleanup == nil && skipped.notes.first?.contains("cleanup pass was skipped") == true)

        var cloudOnly = VizierConfig.Mode.scribe
        cloudOnly.offlineFallback = nil
        #expect(throws: Rerun.SetupError.noKey(provider: "Gemini")) { try Rerun.plan(mode: cloudOnly, config: config) { _ in nil } }
        let noBatch = VizierConfig.Mode(id: "x", name: "Live Only", transcriber: VizierConfig.Mode.scribe.transcriber)
        #expect(throws: Rerun.SetupError.noBatchEngine(mode: "Live Only")) { try Rerun.plan(mode: noBatch, config: config) { _ in "k" } }
    }
}

private extension VizierConfig.Mode {
    func withFallback(_ fallback: VizierConfig.Fallback?) -> Self {
        var copy = self
        copy.fallback = fallback
        return copy
    }
}
