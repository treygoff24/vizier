#if canImport(Speech)
import AVFoundation
import Foundation
import Speech
import os

/// Transcribes a saved take through Apple's on-device `SpeechTranscriber`. The Apple mode's
/// fallback when its live stream fails, the engine behind Re-run for that mode, and the offline
/// fallback of the cloud modes. It runs on this Mac, so a report from it has the `local` route.
public struct AppleSpeechBatchTranscriber: BatchTranscriber {
    private let locale: Locale
    /// Past this the analysis is stopped and the next link of the chain gets the audio. Nil scales
    /// with the audio: twice its length, at least 15 s.
    private let timeout: Duration?
    private let log = Logger(subsystem: "net.praxient.dictum", category: "apple-speech-batch")

    public init(locale: Locale, timeout: Duration? = nil) {
        self.locale = locale
        self.timeout = timeout
    }

    public func transcribeReporting(_ audio: URL) async throws -> BatchReport {
        guard let supported = await AppleSpeechModel.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechError.unsupportedLocale(locale.identifier)
        }
        guard await AppleSpeechModel.status(for: supported) == .installed else {
            throw AppleSpeechError.modelNotInstalled(supported.identifier)
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: audio) } catch { throw AppleSpeechError.unreadableAudio(String(describing: error)) }
        let bytes = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let clock = ContinuousClock()
        let started = clock.now

        let audioSeconds = Double(file.length) / max(file.processingFormat.sampleRate, 1)
        let deadline = timeout ?? .seconds(max(15, 2 * audioSeconds))
        let analysis = Analysis()
        let text = try await Self.bounded(deadline, stop: { await analysis.stop() }) {
            let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
            let collector = Task {
                var finals: [String] = []
                for try await result in transcriber.results where result.isFinal {
                    let text = String(result.text.characters).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if !text.isEmpty { finals.append(text) }
                }
                return finals.joined(separator: " ")
            }
            analysis.collector = collector
            do {
                let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
                analysis.analyzer = analyzer
                // finishAfterFile ends the input; this waits for the last results and closes the stream.
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await collector.value
            } catch {
                collector.cancel()
                throw error
            }
        }
        let report = BatchReport(
            route: .local, bytes: bytes, uploadSeconds: 0, transcriptionSeconds: (clock.now - started).seconds,
            remoteDeleted: nil, result: BatchTranscript(text: text, truncated: false), retried: false)
        log.notice("apple speech batch: \(report.bytes) bytes, \(report.transcriptionSeconds, format: .fixed(precision: 1)) s, \(report.wordCount) words")
        return report
    }

    /// Runs `work`, and if it has not finished by `deadline` calls `stop` (which must end the
    /// analysis and its collector), cancels it, and throws `AppleSpeechError.timedOut`. The work is
    /// not awaited after the deadline, so a recognizer that never finishes cannot hold the chain.
    static func bounded(_ deadline: Duration, stop: @escaping @Sendable () async -> Void,
                        work: @escaping @Sendable () async throws -> String) async throws -> String {
        let outcome: Result<String, any Error> = await withCheckedContinuation { continuation in
            let once = FirstResult(continuation)
            let job = Task { once.resume(await Task { try await work() }.result) }
            Task {
                try? await Task.sleep(for: deadline)
                if once.resume(.failure(AppleSpeechError.timedOut(seconds: Int(deadline.components.seconds)))) {
                    job.cancel()
                    await stop()
                }
            }
        }
        return try outcome.get()
    }

    /// What `stop` has to end: the analyzer and the results collector.
    final class Analysis: @unchecked Sendable {
        private let lock = NSLock()
        private var storedAnalyzer: SpeechAnalyzer?
        private var storedCollector: Task<String, any Error>?
        var analyzer: SpeechAnalyzer? {
            get { lock.withLock { storedAnalyzer } }
            set { lock.withLock { storedAnalyzer = newValue } }
        }
        var collector: Task<String, any Error>? {
            get { lock.withLock { storedCollector } }
            set { lock.withLock { storedCollector = newValue } }
        }
        func stop() async {
            collector?.cancel()
            await analyzer?.cancelAndFinishNow()
        }
    }

    private final class FirstResult: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<String, any Error>, Never>?
        init(_ continuation: CheckedContinuation<Result<String, any Error>, Never>) { self.continuation = continuation }
        /// True when this call was the one that resumed it.
        @discardableResult
        func resume(_ value: Result<String, any Error>) -> Bool {
            let taken = lock.withLock { () -> CheckedContinuation<Result<String, any Error>, Never>? in
                defer { continuation = nil }
                return continuation
            }
            taken?.resume(returning: value)
            return taken != nil
        }
    }
}
#endif
