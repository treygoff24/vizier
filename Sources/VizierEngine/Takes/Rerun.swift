import Foundation

/// Runs a saved take's audio through a mode again, from History: the mode's batch transcriber,
/// then its cleanup pass, filler filter, and word replacements, in the order a live take uses.
/// Nothing is pasted and the take's own record is never changed; the result becomes a new attempt.
public enum Rerun {
    /// What one re-run needs, built from a mode and the keys it asks for.
    public struct Plan: Sendable {
        public let modeID: String
        public let transcriber: any BatchTranscriber
        public let transcriberEngine: String
        public let transcriberModel: String
        public let cleanup: Cleanup?
        public let removeFillers: Bool
        public let replacer: WordReplacer?
        /// Set up problems that did not stop the run (a cleanup pass skipped for want of its key).
        public let notes: [String]

        public struct Cleanup: Sendable {
            public let cleaner: any TextCleaner
            public let engine: String
            public let model: String
            public let timeout: Duration

            public init(cleaner: any TextCleaner, engine: String, model: String, timeout: Duration) {
                self.cleaner = cleaner
                self.engine = engine
                self.model = model
                self.timeout = timeout
            }
        }

        public init(modeID: String, transcriber: any BatchTranscriber, transcriberEngine: String, transcriberModel: String,
                    cleanup: Cleanup?, removeFillers: Bool, replacer: WordReplacer?, notes: [String] = []) {
            self.modeID = modeID
            self.transcriber = transcriber
            self.transcriberEngine = transcriberEngine
            self.transcriberModel = transcriberModel
            self.cleanup = cleanup
            self.removeFillers = removeFillers
            self.replacer = replacer
            self.notes = notes
        }
    }

    public enum SetupError: Error, Equatable, CustomStringConvertible {
        case noBatchEngine(mode: String)
        case noKey(provider: String)

        public var description: String {
            switch self {
            case .noBatchEngine(let mode): "\(mode) has no batch engine, so it cannot re-run saved audio."
            case .noKey(let provider): "There is no \(provider) key in the keychain, so nothing was sent."
            }
        }
    }

    public static let noSpeech = "No speech came through."
    public static let tooLong = "The take is longer than the batch model's one-hour limit, so nothing was sent."
    public static let needsFLAC = "Only a take saved as FLAC can be re-run."

    /// The Keychain account and provider name for a batch engine.
    public static func provider(forBatchEngine engine: String) -> (account: String, name: String) {
        let account = Engines.keyAccount(for: engine) ?? .gemini
        return (account.account, account.name)
    }

    /// The plan for re-running through `mode`: the first engine in its batch chain that can be
    /// set up (the transcriber of a batch-only mode, else its fallback, then its offline
    /// fallback), then its cleanup, filler filter, and the replacements. `key` reads a Keychain
    /// account. A missing cleanup key skips cleanup with a note, as a live take does; a chain
    /// with no engine that can run refuses.
    public static func plan(mode: VizierConfig.Mode, config: VizierConfig, key: (String) -> String?) throws(SetupError) -> Plan {
        let chain = mode.batchChain
        guard !chain.isEmpty else { throw .noBatchEngine(mode: mode.name) }
        let languages = mode.transcriber.languages
        var missing: String?
        var chosen: (spec: VizierConfig.Fallback, transcriber: any BatchTranscriber)?
        for spec in chain {
            let account = Engines.keyAccount(for: spec.engine)
            let apiKey = account.flatMap { key($0.account) }
            if let transcriber = Engines.batch(spec, languages: languages, vocabulary: config.vocabulary, key: apiKey) {
                chosen = (spec, transcriber)
                break
            }
            missing = missing ?? account?.name
        }
        guard let chosen else { throw .noKey(provider: missing ?? "Gemini") }
        var notes: [String] = []
        var cleanup: Plan.Cleanup?
        if let pass = mode.cleanup {
            let account = Engines.keyAccount(for: pass.engine)
            if let cleaner = Engines.cleaner(pass, languages: languages, config: config, key: account.flatMap { key($0.account) }) {
                cleanup = Plan.Cleanup(cleaner: cleaner, engine: pass.engine, model: pass.model, timeout: .milliseconds(pass.timeoutMs))
            } else {
                notes.append("There is no \(account?.name ?? "Gemini") key in the keychain, so the cleanup pass was skipped.")
            }
        }
        let replacer: WordReplacer?
        do {
            replacer = try WordReplacer(rules: config.replacements)
        } catch {
            replacer = nil
            notes.append("The word replacements could not be read, so none were applied.")
        }
        return Plan(modeID: mode.id, transcriber: chosen.transcriber, transcriberEngine: chosen.spec.engine, transcriberModel: chosen.spec.model,
                    cleanup: cleanup, removeFillers: FillerFilter.applies(to: mode), replacer: replacer, notes: notes)
    }

    /// Runs the plan on `audio` and returns what to record. Never throws: a failure is a draft
    /// that did not succeed, with the reason in plain words.
    public static func run(_ audio: URL, plan: Plan) async -> RerunDraft {
        var draft = RerunDraft(modeID: plan.modeID, transcriberEngine: plan.transcriberEngine, transcriberModel: plan.transcriberModel,
                               cleanerEngine: plan.cleanup?.engine, cleanerModel: plan.cleanup?.model, succeeded: false)
        var notes = plan.notes
        func finish(_ failure: String?) -> RerunDraft {
            draft.succeeded = failure == nil
            draft.reason = ([failure] + notes.map(Optional.some)).compactMap(\.self).joined(separator: " ").nilIfEmpty
            return draft
        }
        guard audio.pathExtension.lowercased() == "flac" else { return finish(needsFLAC) }

        let started = ContinuousClock.now
        let report: BatchReport
        do {
            report = try await plan.transcriber.transcribeReporting(audio)
        } catch BatchError.tooLong {
            return finish(tooLong)
        } catch {
            return finish("The transcription failed: \(String(describing: error)).")
        }
        draft.transcriptionMs = milliseconds(since: started)
        let text = report.transcript
        draft.rawTranscript = text
        if report.truncated { notes.append("The transcript hit the model's output limit and may be cut off.") }
        guard TextCleanup.wordCount(text) > 0 else { return finish(noSpeech) }

        var cleaned = text
        if let cleanup = plan.cleanup {
            let cleanupStarted = ContinuousClock.now
            let result = await TextCleanup.run(text, cleaner: cleanup.cleaner, timeout: cleanup.timeout)
            draft.cleanupMs = milliseconds(since: cleanupStarted)
            switch result {
            case .cleaned(let clean):
                cleaned = clean
                draft.cleanedText = clean
            case .raw(let fallback):
                notes.append("The cleanup pass \(fallback.description), so the raw transcript was kept.")
            }
        }
        if plan.removeFillers {
            cleaned = FillerFilter.apply(to: cleaned)
            draft.cleanedText = cleaned
        }
        let replaceStarted = ContinuousClock.now
        let output = plan.replacer?.apply(to: cleaned) ?? cleaned
        if plan.replacer != nil { draft.replacementMs = milliseconds(since: replaceStarted) }
        guard !output.allSatisfy(\.isWhitespace) else { return finish(noSpeech) }
        draft.finalText = output
        return finish(nil)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
