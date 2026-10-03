import Foundation

/// Builds a mode's batch transcribers and cleanup pass, shared by live takes and Re-run, and says
/// which Keychain account each engine needs. Local engines and Apple's speech engines need none.
public enum Engines {
    public struct KeyAccount: Sendable, Equatable {
        public let account: String
        public let name: String

        public static let gemini = KeyAccount(account: "gemini", name: "Gemini")
        public static let elevenLabs = KeyAccount(account: "elevenlabs", name: "ElevenLabs")
    }

    /// The key an engine needs, or nil for an engine on this Mac.
    public static func keyAccount(for engine: String) -> KeyAccount? {
        if ConfigStore.localEngines.contains(engine) || ConfigStore.appleEngines.contains(engine) { return nil }
        return engine.hasPrefix("elevenlabs-") ? .elevenLabs : .gemini
    }

    /// A batch transcriber for one link of a mode's chain. `key` is nil only for a local engine;
    /// a cloud engine with no key gets no transcriber.
    public static func batch(_ spec: VizierConfig.Fallback, languages: [String], vocabulary: [String], key: String?) -> (any BatchTranscriber)? {
        switch spec.engine {
        case "apple-speech-batch":
            return AppleSpeechBatchTranscriber(locale: appleLocale(languages))
        case "local-whisper":
            return LocalWhisperTranscriber(url: spec.url.flatMap(URL.init(string:)) ?? LocalWhisper.defaultURL)
        case "elevenlabs-scribe-batch":
            guard let key else { return nil }
            return ScribeBatchTranscriber(config: ScribeBatch.Config(model: spec.model, languages: languages, vocabulary: vocabulary), apiKey: key)
        default:
            guard let key else { return nil }
            return GeminiBatchTranscriber(config: GeminiBatch.Config(model: spec.model, mode: spec.mode, languages: languages, vocabulary: vocabulary), apiKey: key)
        }
    }

    /// The locale an Apple engine runs in: the mode's first language, else the system's.
    public static func appleLocale(_ languages: [String]) -> Locale {
        languages.first.map(Locale.init(identifier:)) ?? AppleSpeechModel.preferredLocale()
    }

    /// The locale whose Apple speech model the active mode needs: its first language, whether Apple
    /// is the live engine or only the offline fallback, else the system's. Settings and onboarding
    /// show and download this model.
    public static func speechModelLocale(_ config: VizierConfig) -> Locale {
        appleLocale(config.activeMode.transcriber.languages)
    }

    /// A live transcriber for a mode's streaming engine, or nil when the engine needs a key and
    /// `key` is nil. Apple's engine needs none, so it is made either way.
    public static func live(_ transcriber: VizierConfig.Transcriber, vocabulary: [String], key: String?) -> (any LiveTranscriber)? {
        switch transcriber.engine {
        case "apple-speech":
            return AppleSpeechTranscriber(locale: appleLocale(transcriber.languages), finalTimeoutMs: transcriber.finalTimeoutMs)
        case "elevenlabs-scribe-realtime":
            guard let key else { return nil }
            let setup = ScribeRealtime.Setup(
                model: transcriber.model, languages: transcriber.languages, vocabulary: vocabulary, noVerbatim: transcriber.mode == "no_verbatim")
            return ScribeRealtimeTranscriber(setup: setup, apiKey: key, finalTimeoutMs: transcriber.finalTimeoutMs)
        default:
            guard let key else { return nil }
            let setup = GeminiLive.Setup(model: transcriber.model, mode: transcriber.mode, languages: transcriber.languages, vocabulary: vocabulary)
            return GeminiLiveTranscriber(setup: setup, apiKey: key, finalTimeoutMs: transcriber.finalTimeoutMs)
        }
    }

    /// The live transcriber a take in `mode` starts: none for a batch-only mode, and for a cloud
    /// engine none until its key was found. `make` is the factory, injectable so a test can watch
    /// what a take with no key asks for.
    public static func liveTranscriber(
        for mode: VizierConfig.Mode, vocabulary: [String], key: String?,
        make: (VizierConfig.Transcriber, [String], String?) -> (any LiveTranscriber)? = { live($0, vocabulary: $1, key: $2) }
    ) -> (any LiveTranscriber)? {
        mode.isBatchOnly ? nil : make(mode.transcriber, vocabulary, key)
    }

    /// A mode's cleanup pass. `key` is nil only for a local engine.
    public static func cleaner(_ cleanup: VizierConfig.Cleanup, languages: [String], config: VizierConfig, key: String?) -> (any TextCleaner)? {
        if cleanup.engine == "local-cleanup" {
            return LocalCleaner(url: cleanup.url.flatMap(URL.init(string:)) ?? LocalCleanup.defaultURL, model: cleanup.model)
        }
        guard let key else { return nil }
        let setup = GeminiCleanup.Config(model: cleanup.model, thinkingLevel: cleanup.thinkingLevel, languages: languages,
                                         vocabulary: config.vocabulary, replacements: config.replacements)
        return GeminiCleaner(config: setup, apiKey: key)
    }
}

/// Tries a take's batch transcribers in order until one answers. A link that cannot help
/// (`tooLong`, a failed request, an unreachable server) passes the audio to the next.
public enum BatchChain {
    public struct Link: Sendable {
        public let engine: String
        public let transcriber: any BatchTranscriber

        public init(engine: String, transcriber: any BatchTranscriber) {
            self.engine = engine
            self.transcriber = transcriber
        }
    }

    public struct Answer: Sendable {
        public let report: BatchReport
        /// Which link answered, counting from 0.
        public let index: Int
        public let engine: String
    }

    public struct Failure: Error, Sendable {
        /// Each link's error, in order.
        public let errors: [(engine: String, error: any Error)]

        public var tooLong: Bool {
            errors.contains { if case BatchError.tooLong = $0.error { true } else { false } }
        }
    }

    public static func run(_ links: [Link], audio: URL) async -> Result<Answer, Failure> {
        var errors: [(engine: String, error: any Error)] = []
        for (index, link) in links.enumerated() {
            do {
                let report = try await link.transcriber.transcribeReporting(audio)
                return .success(Answer(report: report, index: index, engine: link.engine))
            } catch {
                errors.append((link.engine, error))
            }
        }
        return .failure(Failure(errors: errors))
    }
}
