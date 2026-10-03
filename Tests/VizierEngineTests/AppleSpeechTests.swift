#if canImport(Speech)
import AVFoundation
import Foundation
import Testing
@testable import VizierEngine

@Suite struct AppleSpeechTranscriptTests {
    private func events(_ results: [AppleSpeechResult]) async throws -> (events: [LiveTranscriberEvent], text: String) {
        let recorded = Recorded()
        let stream = AsyncStream<AppleSpeechResult> { continuation in
            for result in results { continuation.yield(result) }
            continuation.finish()
        }
        let text = try await AppleSpeechTranscriber.pump(stream) { recorded.add($0) }
        return (recorded.events, text)
    }

    @Test func finalsSettleAndVolatilesStayPending() async throws {
        let (events, text) = try await events([
            .init(text: "Zorblex the", isFinal: false),
            .init(text: "Zorblex the quaxil", isFinal: false),
            .init(text: "Zorblex the quaxil.", isFinal: true),
            .init(text: "Then ship", isFinal: false),
        ])
        #expect(events == [
            .transcript(settled: "", pending: "Zorblex the"),
            .transcript(settled: "", pending: "Zorblex the quaxil"),
            .transcript(settled: "Zorblex the quaxil.", pending: ""),
            .transcript(settled: "Zorblex the quaxil.", pending: "Then ship"),
        ])
        // The stream ended with words still in flux: a dictation keeps them.
        #expect(text == "Zorblex the quaxil. Then ship")
    }

    @Test func segmentsAreJoinedWithASpaceBecauseAppleReturnsNone() async throws {
        let (events, text) = try await events([
            .init(text: "First segment.", isFinal: true),
            .init(text: "  Second   segment. ", isFinal: true),
            .init(text: "", isFinal: true),
            .init(text: "Third.", isFinal: true),
        ])
        #expect(events.last == .transcript(settled: "First segment. Second segment. Third.", pending: ""))
        #expect(text == "First segment. Second segment. Third.")
    }

    @Test func aVolatileFinalizedWithoutARepeatedFinalSettlesAndIsNotOverwritten() async throws {
        let (events, text) = try await events([
            .init(text: "Zorblex the quaxil.", isFinal: false, range: 0...2),
            // The recognizer finalized through 2 s without publishing a final for it; the next volatile covers later audio.
            .init(text: "Then ship it", isFinal: false, range: 2...3, finalizedThrough: 2),
            .init(text: "Then ship it now", isFinal: false, range: 2...4, finalizedThrough: 2),
        ])
        #expect(events.last == .transcript(settled: "Zorblex the quaxil.", pending: "Then ship it now"))
        #expect(text == "Zorblex the quaxil. Then ship it now")
    }

    @Test func aVolatileReplacesOnlyTheVolatileRangesItOverlaps() {
        var transcript = AppleSpeechTranscript()
        _ = transcript.apply(.init(text: "first part", isFinal: false, range: 0...2))
        _ = transcript.apply(.init(text: "second part", isFinal: false, range: 2...4))
        let after = transcript.apply(.init(text: "second part again", isFinal: false, range: 3...5))
        #expect(after.pending == "first part second part again")
    }

    @Test func aFinalClearsTheVolatileItReplaces() {
        var transcript = AppleSpeechTranscript()
        _ = transcript.apply(.init(text: "hello wor", isFinal: false))
        let after = transcript.apply(.init(text: "Hello world.", isFinal: true))
        #expect(after.settled == "Hello world.")
        #expect(after.pending == "")
    }

    @Test func aFailedStreamThrowsAndTheFinalIsNotInvented() async {
        struct Boom: Error {}
        let stream = AsyncThrowingStream<AppleSpeechResult, any Error> { continuation in
            continuation.yield(.init(text: "kept.", isFinal: true))
            continuation.finish(throwing: Boom())
        }
        await #expect(throws: Boom.self) { try await AppleSpeechTranscriber.pump(stream) { _ in } }
    }
}

private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LiveTranscriberEvent] = []
    func add(_ event: LiveTranscriberEvent) { lock.withLock { stored.append(event) } }
    var events: [LiveTranscriberEvent] { lock.withLock { stored } }
}

@Suite struct AppleSpeechRoutingTests {
    @Test func bothAppleEnginesNeedNoKey() {
        #expect(Engines.keyAccount(for: "apple-speech") == nil)
        #expect(Engines.keyAccount(for: "apple-speech-batch") == nil)
        #expect(Engines.keyAccount(for: "elevenlabs-scribe-realtime") == .elevenLabs)
        #expect(Engines.keyAccount(for: "gemini-live") == .gemini)
    }

    @Test func aTakeInTheAppleModeStartsALiveTranscriberWithNoKey() {
        let live = Engines.live(VizierConfig.Mode.apple.transcriber, vocabulary: [], key: nil)
        #expect(live is AppleSpeechTranscriber)
        // A cloud engine still waits for its key.
        #expect(Engines.live(VizierConfig.Mode.scribe.transcriber, vocabulary: [], key: nil) == nil)
        #expect(Engines.live(VizierConfig.Mode.geminiClean.transcriber, vocabulary: [], key: nil) == nil)
        #expect(Engines.live(VizierConfig.Mode.scribe.transcriber, vocabulary: [], key: "k") is ScribeRealtimeTranscriber)
    }

    @Test func theKeylessStartPathAsksForALiveTranscriberWithNoKey() {
        // The path a take uses: the factory is asked, with no key, for the Apple mode, and the result starts.
        var asked: [(engine: String, key: String?)] = []
        let transcriber = Engines.liveTranscriber(for: .apple, vocabulary: [], key: nil) { spec, _, key in
            asked.append((spec.engine, key))
            return AppleSpeechTranscriber(locale: Locale(identifier: "en-US"), finalTimeoutMs: 100)
        }
        #expect(transcriber != nil)
        #expect(asked.count == 1 && asked[0].engine == "apple-speech" && asked[0].key == nil)
        // The real factory still refuses a cloud engine without its key, and a batch-only mode streams nothing.
        #expect(Engines.liveTranscriber(for: .scribe, vocabulary: [], key: nil) == nil)
        #expect(Engines.liveTranscriber(for: .local, vocabulary: [], key: "k") == nil)
    }

    @Test func theAppleBatchEngineIsBuiltWithNoKey() {
        let spec = VizierConfig.Mode.apple.fallback!
        #expect(Engines.batch(spec, languages: ["en-US"], vocabulary: [], key: nil) is AppleSpeechBatchTranscriber)
        #expect(Engines.batch(VizierConfig.Mode.scribe.fallback!, languages: ["en"], vocabulary: [], key: nil) == nil)
    }

    @Test func theAppleModeAnswersWithAppleWhenTheCloudModesHaveNoKeys() throws {
        // Re-run from history picks the first engine in the chain it can set up: for a cloud mode with no keys, Apple's.
        for mode in [VizierConfig.Mode.scribe, .geminiClean, .geminiSmart] {
            let plan = try Rerun.plan(mode: mode, config: VizierConfig(), key: { _ in nil })
            #expect(plan.transcriberEngine == "apple-speech-batch", "\(mode.id)")
        }
        let apple = try Rerun.plan(mode: .apple, config: VizierConfig(), key: { _ in nil })
        #expect(apple.transcriberEngine == "apple-speech-batch")
    }

    @Test func theAppleEnginesAreInTheEngineLists() {
        #expect(ConfigStore.liveEngines.contains("apple-speech"))
        #expect(ConfigStore.batchEngines.contains("apple-speech-batch"))
        #expect(ConfigStore.localEngines.contains("apple-speech-batch"))
        #expect(!ConfigStore.batchEngines.contains("apple-speech"))
    }

    @Test func aModeUsingTheAppleEnginesLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vizier-apple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(directory: dir)
        let apple = #"{ "engine": "apple-speech", "model": "m", "mode": "general", "languages": ["en-US"], "final_timeout_ms": 900 }"#
        let batch = #"{ "engine": "apple-speech-batch", "model": "m", "mode": "general" }"#
        try Data(#"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": \#(apple), "fallback": \#(batch), "offline_fallback": \#(batch) } ] }"#.utf8)
            .write(to: store.settingsURL)
        let load = store.load()
        #expect(load.errors == [])
        #expect(!load.config.activeMode.isBatchOnly)
        #expect(load.config.activeMode.batchChain.map(\.engine) == ["apple-speech-batch", "apple-speech-batch"])
    }

    @Test func theAppleModeIsTheDefaultSelection() throws {
        // The selection, not the array order: the active mode follows the "mode" field.
        let reordered = VizierConfig.Settings(mode: VizierConfig.Settings().mode, modes: VizierConfig.Settings().modes.reversed())
        #expect(reordered.mode == "apple")
        #expect(VizierConfig(settings: reordered).activeMode.id == "apple")
        #expect(VizierConfig().activeMode.id == "apple")
        #expect(VizierConfig().activeMode.transcriber.engine == "apple-speech")

        let starter = try ConfigStore.parseSettings(ConfigStore.starterSettings)
        #expect(starter.mode == "apple")
        #expect(VizierConfig(settings: starter).activeMode.id == "apple")
        #expect(starter.modes.first?.id == "apple", "Apple is listed first")
        #expect(!starter.modes.contains { $0.transcriber.engine == "local-whisper" }, "the starter has no local modes")
        #expect(!ConfigStore.starterSettings.contains("local-cleanup"))
    }

    @Test func cloudModesFallBackToAppleSpeechWhenOffline() throws {
        let starter = try ConfigStore.parseSettings(ConfigStore.starterSettings)
        for mode in starter.modes where mode.id != "apple" {
            #expect(mode.offlineFallback?.engine == "apple-speech-batch", "\(mode.id)")
        }
    }
}

@Suite struct AppleSpeechBatchDeadlineTests {
    private final class Stopped: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    @Test(.timeLimit(.minutes(1))) func analysisThatNeverEndsIsStoppedAtTheDeadline() async {
        let stopped = Stopped()
        let started = ContinuousClock.now
        // The call runs beside a 5 s watchdog, so a deadline that never fires fails here instead of hanging the run.
        let (answers, answer) = AsyncStream.makeStream(of: String.self)
        Task {
            do {
                // A non-terminating seam: it only ends when it is cancelled.
                _ = try await AppleSpeechBatchTranscriber.bounded(.milliseconds(300), stop: { stopped.set() }) {
                    try await Task.sleep(for: .seconds(3600))
                    return "never"
                }
                answer.yield("returned")
            } catch AppleSpeechError.timedOut {
                answer.yield("timed out")
            } catch {
                answer.yield("other: \(error)")
            }
        }
        Task { try? await Task.sleep(for: .seconds(5)); answer.yield("hung") }
        var first = ""
        for await next in answers { first = next; break }
        #expect(first == "timed out")
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(stopped.isSet, "the analyzer and collector are told to stop")
    }

    @Test(.timeLimit(.minutes(1))) func finishedWorkIsReturnedAndNeverStopped() async throws {
        let stopped = Stopped()
        let text = try await AppleSpeechBatchTranscriber.bounded(.seconds(30), stop: { stopped.set() }) { "done" }
        #expect(text == "done")
        #expect(!stopped.isSet)
    }
}

/// Real Apple recognition on synthetic `say` audio. Reported as skipped when the speech model is
/// not installed: the run proves nothing then, and a pass would claim it did.
@Suite struct AppleSpeechEndToEndTests {
    private static let sentence = "The quick brown fox jumps over the lazy dog."

    /// 16 kHz mono 16-bit WAV from `say`, or nil when the tools are missing.
    private func synthesize() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vizier-apple-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let aiff = dir.appending(path: "say.aiff"), wav = dir.appending(path: "say.wav")
        try run("/usr/bin/say", ["-o", aiff.path, Self.sentence])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        return wav
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppleSpeechError.unreadableAudio("\(tool) exited \(process.terminationStatus)") }
    }

    private func requireModel(_ locale: Locale) async throws {
        let status = await AppleSpeechModel.status(for: locale)
        if status != .installed {
            try Test.cancel("Apple speech model for \(locale.identifier) is \(status), so real recognition was not exercised")
        }
    }

    @Test(.timeLimit(.minutes(1))) func theBatchEngineTranscribesSyntheticSpeech() async throws {
        let locale = Locale(identifier: "en-US")
        try await requireModel(locale)
        let report = try await AppleSpeechBatchTranscriber(locale: locale).transcribeReporting(synthesize())
        let heard = report.transcript.lowercased()
        #expect(heard.contains("fox") && heard.contains("lazy dog"), "heard: \(report.wordCount) words")
        #expect(report.route == .local)
    }

    @Test(.timeLimit(.minutes(1))) func theLiveEngineTranscribesSyntheticSpeechFedInChunks() async throws {
        let locale = Locale(identifier: "en-US")
        try await requireModel(locale)
        let file = try AVAudioFile(forReading: synthesize())
        let frames = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        try file.read(into: buffer)
        // The capture path hands engines 16 kHz Int16 mono; the file's processing format is Float32.
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: AppleSpeechTranscriber.pcmFormat))
        let out = try #require(AVAudioPCMBuffer(pcmFormat: AppleSpeechTranscriber.pcmFormat, frameCapacity: frames))
        try converter.convert(to: out, from: buffer)
        let samples = Data(bytes: out.int16ChannelData![0], count: Int(out.frameLength) * 2)

        let transcriber = AppleSpeechTranscriber(locale: locale, finalTimeoutMs: 10_000)
        let recorded = Recorded()
        transcriber.start { recorded.add($0) }
        // 100 ms chunks, as capture delivers them.
        let chunk = 3_200
        for offset in stride(from: 0, to: samples.count, by: chunk) {
            transcriber.send(samples.subdata(in: offset..<min(offset + chunk, samples.count)))
        }
        // Words must stream before the input ends, not only at the final.
        for _ in 0..<100 where !recorded.events.contains(where: { if case .transcript = $0 { true } else { false } }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(recorded.events.contains { if case .transcript = $0 { true } else { false } }, "no transcript event before finish")
        let text = try await transcriber.finish().lowercased()
        #expect(text.contains("fox") && text.contains("lazy dog"), "live final had \(text.split(separator: " ").count) words")
        #expect(recorded.events.contains { if case .transcript = $0 { true } else { false } }, "words streamed before the final")
    }

    @Test(.timeLimit(.minutes(1))) func aTakeThatNeverHeardAudioAnswersWithinItsTimeout() async throws {
        let locale = Locale(identifier: "en-US")
        try await requireModel(locale)
        let transcriber = AppleSpeechTranscriber(locale: locale, finalTimeoutMs: 1_500)
        transcriber.start { _ in }
        let started = ContinuousClock.now
        // Either an empty final or a timeout is an answer; hanging is not.
        do { _ = try await transcriber.finish() } catch TranscriberError.timedOut {}
        #expect(ContinuousClock.now - started < .seconds(8))
    }

    @Test(.timeLimit(.minutes(1))) func aLanguageAppleCannotHearFailsLoudlyInsteadOfSilently() async throws {
        // Apple has no model for this language, so the take must say so rather than hear nothing.
        // The unsupported-locale answer must beat the final timeout; under a full parallel suite the
        // system's locale lookup has taken over 2 s, and a timeout cancels the stream before it reports.
        let transcriber = AppleSpeechTranscriber(locale: Locale(identifier: "tlh"), finalTimeoutMs: 20_000)
        let recorded = Recorded()
        transcriber.start { recorded.add($0) }
        transcriber.send(Data(count: 3_200))
        await #expect(throws: TranscriberError.self) { try await transcriber.finish() }
        #expect(recorded.events.contains { if case .streamLost = $0 { true } else { false } })
    }
}
#endif
