#if canImport(Speech)
import AVFoundation
import Foundation
import Speech
import os

/// One result from Apple's recognizer, reduced to what Vizier reads: its text, whether it is
/// final, the audio span it covers (seconds), and how far the recognizer has finalized the take.
/// Apple returns segments with no separating space, so joining happens here.
public struct AppleSpeechResult: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    /// The audio this result covers; nil when unknown (it then replaces every volatile segment).
    public var range: ClosedRange<Double>?
    /// Audio before this time is final, whether or not a final result was published for it.
    public var finalizedThrough: Double?

    public init(text: String, isFinal: Bool, range: ClosedRange<Double>? = nil, finalizedThrough: Double? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.range = range
        self.finalizedThrough = finalizedThrough
    }
}

/// The take's transcript as Apple's results build it. Finals settle and never change; a volatile
/// result replaces only the volatile segments its range overlaps, and a volatile segment settles
/// once the recognizer's finalization time passes it, because Apple can finalize an unchanged
/// volatile result without publishing a repeat final.
public struct AppleSpeechTranscript: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    private(set) var finals: [Segment] = []
    private(set) var volatiles: [Segment] = []

    public init() {}

    /// The settled text and the pending words after one more result.
    public mutating func apply(_ result: AppleSpeechResult) -> (settled: String, pending: String) {
        let text = result.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let range = result.range ?? (-.infinity)...(.infinity)
        let segment = Segment(start: range.lowerBound, end: range.upperBound, text: text)
        // A result replaces the volatile segments it overlaps (an unknown range overlaps all).
        volatiles.removeAll { $0.start < segment.end && $0.end > segment.start || result.range == nil }
        if result.isFinal {
            if !text.isEmpty { finals.append(segment) }
        } else if !text.isEmpty {
            volatiles.append(segment)
            volatiles.sort { $0.start < $1.start }
        }
        if let through = result.finalizedThrough {
            let done = volatiles.filter { $0.end <= through }
            finals += done
            finals.sort { $0.start < $1.start }
            volatiles.removeAll { $0.end <= through }
        }
        return (settled, pending)
    }

    public var settled: String { finals.map(\.text).joined(separator: " ") }
    public var pending: String { volatiles.map(\.text).joined(separator: " ") }

    /// Everything heard, for a take whose stream has ended: any words still pending are kept, since
    /// a dictation is never thrown away.
    public var complete: String { [settled, pending].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// Streams one take through Apple's on-device `SpeechTranscriber` (the general model, with
/// progressive results). Takes the same 16 kHz mono PCM the capture path hands every engine.
public final class AppleSpeechTranscriber: LiveTranscriber, @unchecked Sendable {
    /// What the strip and log say when the take started with no model installed.
    public static let modelMissingReason = "the Apple speech model is not installed"

    private let locale: Locale
    private let finalTimeout: Duration
    private let log = Logger(subsystem: "net.praxient.dictum", category: "apple-speech")

    private let audio: AsyncStream<Data>
    private let audioIn: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    // Guarded by `lock`.
    private var run: Task<String, any Error>?
    private var analyzer: SpeechAnalyzer?
    private var cancelled = false

    public init(locale: Locale, finalTimeoutMs: Int) {
        self.locale = locale
        self.finalTimeout = .milliseconds(finalTimeoutMs)
        (audio, audioIn) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    public func start(onEvent: @escaping @Sendable (LiveTranscriberEvent) -> Void) {
        lock.withLock {
            guard run == nil, !cancelled else { return }
            run = Task { [self] in
                do {
                    return try await execute(onEvent: onEvent)
                } catch is CancellationError {
                    throw TranscriberError.cancelled
                } catch let error as TranscriberError {
                    onEvent(.streamLost(error.reason))
                    throw error
                } catch {
                    onEvent(.streamLost(String(describing: error)))
                    throw TranscriberError.streamLost(String(describing: error))
                }
            }
        }
    }

    public func send(_ pcm: Data) {
        audioIn.yield(pcm)
    }

    public func finish() async throws -> String {
        audioIn.finish()
        let run = lock.withLock { self.run }
        guard let run else { throw TranscriberError.cancelled }
        let timeout = finalTimeout
        // First of the take's result and the timeout wins. Neither waits for the other: a recognizer
        // that never finishes must not hold the paste past the timeout.
        let race = Race()
        let outcome: Result<String, any Error> = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            race.waiter = Task { once.resume(await run.result) }
            race.timer = Task {
                try? await Task.sleep(for: timeout)
                once.resume(.failure(TranscriberError.timedOut))
            }
        }
        // Nothing outlives finish: the loser of the race is cancelled.
        race.timer?.cancel()
        race.waiter?.cancel()
        switch outcome {
        case .success(let text): return text
        case .failure(let error):
            if case TranscriberError.timedOut = error { cancel() }
            throw error as? TranscriberError ?? TranscriberError.streamLost(String(describing: error))
        }
    }

    public func cancel() {
        audioIn.finish()
        let (run, analyzer) = lock.withLock { () -> (Task<String, any Error>?, SpeechAnalyzer?) in
            cancelled = true
            return (self.run, self.analyzer)
        }
        run?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    private func execute(onEvent: @escaping @Sendable (LiveTranscriberEvent) -> Void) async throws -> String {
        guard let supported = await AppleSpeechModel.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.streamLost(AppleSpeechError.unsupportedLocale(locale.identifier).description)
        }
        guard await AppleSpeechModel.status(for: supported) == .installed else {
            throw TranscriberError.streamLost(Self.modelMissingReason)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        lock.withLock { self.analyzer = analyzer }
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        let (inputs, inputsIn) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        try await analyzer.start(inputSequence: inputs)

        let results = Task {
            try await Self.pump(transcriber.results.map { AppleSpeechResult(apple: $0) },
                                onEvent: onEvent)
        }
        do {
            let format = Self.pcmFormat
            for await chunk in audio {
                try Task.checkCancellation()
                guard let buffer = Self.buffer(from: chunk, format: format) else { continue }
                for input in try converter.convert(buffer, at: nil) { inputsIn.yield(input) }
            }
            for input in try converter.flush() { inputsIn.yield(input) }
            inputsIn.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await results.value
        } catch {
            inputsIn.finish()
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// Reads results until the stream ends and returns the take's text; sends an event for each
    /// one. The seam a test feeds with a fake source.
    static func pump<Results: AsyncSequence>(
        _ results: Results, onEvent: @Sendable (LiveTranscriberEvent) -> Void
    ) async throws -> String where Results.Element == AppleSpeechResult {
        var transcript = AppleSpeechTranscript()
        for try await result in results {
            let (settled, pending) = transcript.apply(result)
            onEvent(.transcript(settled: settled, pending: pending))
        }
        return transcript.complete
    }

    static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    static func buffer(from pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.int16ChannelData else { return nil }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(channel[0], base, Int(frames) * MemoryLayout<Int16>.size) }
        }
        return buffer
    }
}

/// The two tasks of `finish()`'s race, kept so both can be cancelled when it ends.
private final class Race: @unchecked Sendable {
    var waiter: Task<Void, Never>?
    var timer: Task<Void, Never>?
}

/// Resumes a continuation once; later calls do nothing.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<String, any Error>, Never>?

    init(_ continuation: CheckedContinuation<Result<String, any Error>, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Result<String, any Error>) {
        let taken = lock.withLock { () -> CheckedContinuation<Result<String, any Error>, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}

extension AppleSpeechResult {
    init(apple result: SpeechTranscriber.Result) {
        let start = result.range.start.seconds, end = result.range.end.seconds
        let through = result.resultsFinalizationTime.seconds
        self.init(
            text: String(result.text.characters), isFinal: result.isFinal,
            range: start.isFinite && end.isFinite && start <= end ? start...end : nil,
            finalizedThrough: through.isFinite ? through : nil)
    }
}

extension TranscriberError {
    var reason: String {
        switch self {
        case .streamLost(let reason): reason
        case .timedOut: "no final before the timeout"
        case .cancelled: "cancelled"
        }
    }
}
#endif
