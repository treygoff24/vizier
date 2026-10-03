#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

/// Transcribes a saved take in one request. The fallback when the live stream fails.
public protocol BatchTranscriber: Sendable {
    /// The transcript alone. A truncated transcript (the model stopped at its output ceiling) comes
    /// back here like a whole one; callers that need to know read `BatchReport.truncated` from
    /// `transcribeReporting(_:)`.
    func transcribe(_ audio: URL) async throws -> String
    /// The transcript with what the request did: route, truncation, retry, word count.
    func transcribeReporting(_ audio: URL) async throws -> BatchReport
}

extension BatchTranscriber {
    public func transcribe(_ audio: URL) async throws -> String {
        try await transcribeReporting(audio).transcript
    }
}

/// The text of one interaction. `truncated` means the interaction ended `incomplete`: the model hit
/// its 32,768-token output ceiling, usually after falling into a repetition loop, so the text is
/// the real transcript followed by repeated junk. The prefix is kept because dictations are never
/// lost.
public struct BatchTranscript: Sendable, Equatable {
    public var text: String
    public var truncated: Bool

    public init(text: String, truncated: Bool) {
        self.text = text
        self.truncated = truncated
    }

    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

public enum BatchError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Past the model's one-hour limit. Nothing was sent; the audio stays on disk.
    case tooLong(seconds: Int)
    /// The transcription request failed.
    case http(status: Int, message: String)
    /// Sending the audio to the Files API failed. Nothing was transcribed.
    case upload(status: Int, message: String)
    /// The uploaded file never became usable (it failed processing, or was still processing).
    case fileNotReady(state: String)
    case incomplete(status: String)

    public var description: String {
        switch self {
        case .tooLong(let seconds): "the take's audio (\(seconds) s) is past the model's one-hour limit"
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .upload(let status, let message): "upload failed, HTTP \(status): \(message)"
        case .fileNotReady(let state): "the uploaded audio is \(state), not ACTIVE"
        case .incomplete(let status): "the interaction ended with status \(status)"
        }
    }
}

/// The wire format of `gemini-3.5-transcribe` through the Interactions API, checked against
/// ai.google.dev/gemini-api/docs/transcribe and the Interactions API reference.
/// Unlike the live API, this one is snake_case and spells the mode in lowercase.
public enum GeminiBatch {
    public static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

    /// A request may be at most 20 MB, and base64 grows the audio by a third. This leaves room
    /// for a full vocabulary and the JSON around it. How many minutes it holds depends on how
    /// well a take compresses (synthetic speech ran 13.8 KB/s, about 17 minutes); longer takes
    /// go through the Files API (`GeminiFiles`).
    public static let maxInlineAudioBytes = 14_500_000

    /// "Standard unary requests support audio files up to 1 hour" (docs/transcribe, Limitations).
    public static let maxAudioSeconds: Double = 3_600

    public struct Config: Equatable, Sendable {
        public var model: String
        /// "smart", lowercase on this API. Leaving it out means verbatim.
        public var mode: String
        public var languages: [String]
        public var vocabulary: [String]

        public init(model: String, mode: String, languages: [String], vocabulary: [String]) {
            self.model = model
            self.mode = mode
            self.languages = languages
            self.vocabulary = vocabulary
        }
    }

    /// The request body. `store` is false: by default Google keeps every interaction for 55 days.
    public static func requestBody(audio: Data, mimeType: String, config: Config) throws -> Data {
        try requestBody(input: .init(type: "audio", data: audio.base64EncodedString(), mimeType: mimeType), config: config)
    }

    /// The same request with a Files API reference (`File.uri`) in place of the inline audio.
    public static func requestBody(fileURI: String, mimeType: String, config: Config) throws -> Data {
        try requestBody(input: .init(type: "audio", mimeType: mimeType, uri: fileURI), config: config)
    }

    private static func requestBody(input: Wire.Audio, config: Config) throws -> Data {
        let body = Wire.Request(
            model: config.model,
            input: [input],
            generationConfig: .init(transcriptionConfig: .init(
                mode: config.mode,
                languageCodes: config.languages.isEmpty ? nil : config.languages,
                customVocabulary: config.vocabulary.isEmpty ? nil : config.vocabulary)),
            store: false)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(body)
    }

    /// The text of an interaction's `model_output` steps. A completed interaction is whole; an
    /// `incomplete` one with text is kept and marked truncated. Any other status, or an incomplete
    /// one with no text, throws `BatchError.incomplete`.
    public static func transcript(from response: Data) throws -> BatchTranscript {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let interaction = try decoder.decode(Wire.Interaction.self, from: response)
        let text = (interaction.steps ?? [])
            .filter { $0.type == "model_output" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch interaction.status {
        case nil, "completed": return BatchTranscript(text: text, truncated: false)
        case "incomplete" where !text.isEmpty: return BatchTranscript(text: text, truncated: true)
        case let status?: throw BatchError.incomplete(status: status)
        }
    }

    /// The message in a Google API error body, or the raw body when it has another shape.
    public static func errorMessage(from body: Data) -> String {
        if let error = try? JSONDecoder().decode(Wire.ErrorBody.self, from: body) {
            return [error.error.status, error.error.message].compactMap { $0 }.joined(separator: ": ")
        }
        return String(decoding: body.prefix(300), as: UTF8.self)
    }

    private enum Wire {
        struct Request: Encodable {
            var model: String
            var input: [Audio]
            var generationConfig: GenerationConfig
            var store: Bool
        }
        /// `AudioContent`: exactly one of `data` (base64) or `uri` (a Files API file) is set.
        struct Audio: Encodable {
            var type: String
            var data: String? = nil
            var mimeType: String
            var uri: String? = nil
        }
        struct GenerationConfig: Encodable { var transcriptionConfig: TranscriptionConfig }
        struct TranscriptionConfig: Encodable {
            var mode: String
            var languageCodes: [String]?
            var customVocabulary: [String]?
        }

        struct Interaction: Decodable {
            var status: String?
            var steps: [Step]?
        }
        struct Step: Decodable {
            var type: String
            var content: [Content]?
        }
        struct Content: Decodable {
            var type: String
            var text: String?
        }
        struct ErrorBody: Decodable {
            struct Detail: Decodable {
                var message: String?
                var status: String?
            }
            var error: Detail
        }
    }
}

/// What one batch transcription did, for logs and the files probe. Never logged: `transcript`.
public struct BatchReport: Sendable {
    /// Gemini inline or through the Files API, or one Scribe batch request.
    public enum Route: String, Sendable { case inline, files, scribe, local }
    public var route: Route
    public var bytes: Int
    /// Upload plus waiting for the file to become ACTIVE; zero on the inline route.
    public var uploadSeconds: Double
    public var transcriptionSeconds: Double
    /// Whether the remote file was deleted; nil on the inline route, which stores nothing.
    public var remoteDeleted: Bool?
    public var transcript: String
    /// The interaction ended `incomplete` and `transcript` is its prefix (see `BatchTranscript`).
    public var truncated: Bool
    /// The Files route asked a second time after a truncated first answer. The inline route never does.
    public var retried: Bool
    /// Whitespace-separated words in `transcript`.
    public var wordCount: Int

    init(route: Route, bytes: Int, uploadSeconds: Double, transcriptionSeconds: Double, remoteDeleted: Bool?, result: BatchTranscript, retried: Bool) {
        self.route = route
        self.bytes = bytes
        self.uploadSeconds = uploadSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.remoteDeleted = remoteDeleted
        self.transcript = result.text
        self.truncated = result.truncated
        self.retried = retried
        self.wordCount = result.wordCount
    }
}

/// Refuses every HTTP redirect. URLSession copies custom headers such as `x-goog-api-key` onto a
/// redirected request (it strips only `Authorization` across hosts), and a 307 or 308 resends the
/// body, so following one could hand the key and the audio to whatever `Location` names. The API
/// answers these requests directly; a refused redirect comes back as its 3xx response, which the
/// status checks turn into an error.
public final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    override public init() { super.init() }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Sends a saved FLAC take to `gemini-3.5-transcribe`: inline when it fits in one request,
/// otherwise through the Files API. Anything past the model's one-hour limit is refused before
/// any network call.
public struct GeminiBatchTranscriber: BatchTranscriber {
    /// Sends one request. The default is the shared ephemeral session; tests pass a stub.
    public typealias Perform = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// No cookies, no cache, no redirects: every request carries the API key.
    static let urlSession = URLSession(configuration: .ephemeral, delegate: RefuseRedirects(), delegateQueue: nil)

    private let config: GeminiBatch.Config
    private let apiKey: String
    private let perform: Perform
    private let maxInlineBytes: Int
    private let maxSeconds: Double
    private let pollInterval: Duration
    private let log = Logger(subsystem: "net.praxient.dictum", category: "gemini-batch")

    public init(config: GeminiBatch.Config, apiKey: String) {
        self.init(config: config, apiKey: apiKey, perform: { try await Self.urlSession.data(for: $0) })
    }

    /// Tests pass a stub `perform`; the files probe passes `maxInlineBytes: 0` to force the Files
    /// route on a short take.
    public init(
        config: GeminiBatch.Config, apiKey: String, perform: @escaping Perform,
        maxInlineBytes: Int = GeminiBatch.maxInlineAudioBytes, maxSeconds: Double = GeminiBatch.maxAudioSeconds,
        pollInterval: Duration = .seconds(1)
    ) {
        self.config = config
        self.apiKey = apiKey
        self.perform = perform
        self.maxInlineBytes = maxInlineBytes
        self.maxSeconds = maxSeconds
        self.pollInterval = pollInterval
    }

    public func transcribe(_ audio: URL) async throws -> String {
        try await transcribeReporting(audio).transcript
    }

    public func transcribeReporting(_ audio: URL) async throws -> BatchReport {
        if let seconds = Self.duration(of: audio), seconds > maxSeconds {
            throw BatchError.tooLong(seconds: Int(seconds.rounded(.up)))
        }
        let bytes = try Data(contentsOf: audio)
        let report: BatchReport
        if bytes.count <= maxInlineBytes {
            report = try await inline(bytes)
        } else {
            let route = GeminiFiles.Route(config: config, apiKey: apiKey, perform: perform, pollInterval: pollInterval, log: log)
            report = try await route.transcribe(bytes, displayName: audio.deletingPathExtension().lastPathComponent)
        }
        log.notice("batch \(report.route.rawValue, privacy: .public): \(report.bytes) bytes, upload \(report.uploadSeconds, format: .fixed(precision: 1)) s, transcription \(report.transcriptionSeconds, format: .fixed(precision: 1)) s, \(report.wordCount) words")
        if report.truncated {
            log.error("batch: interaction incomplete, kept \(report.wordCount) words (truncated)")
        }
        return report
    }

    private func inline(_ bytes: Data) async throws -> BatchReport {
        let clock = ContinuousClock()
        let started = clock.now
        var request = URLRequest(url: GeminiBatch.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try GeminiBatch.requestBody(audio: bytes, mimeType: "audio/flac", config: config)
        let (body, response) = try await perform(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BatchError.http(status: status, message: GeminiBatch.errorMessage(from: body)) }
        let result = try GeminiBatch.transcript(from: body)
        return BatchReport(
            route: .inline, bytes: bytes.count, uploadSeconds: 0, transcriptionSeconds: (clock.now - started).seconds,
            remoteDeleted: nil, result: result, retried: false)
    }

    /// The audio's length from its header, or nil when the header can't be read. An unreadable
    /// header doesn't stop the take: the API is the judge of a file it can't parse either.
    static func duration(of audio: URL) -> Double? {
        #if canImport(AVFoundation)
        guard let file = try? AVAudioFile(forReading: audio), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
        #else
        TakeStore.duration(of: audio)
        #endif
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
