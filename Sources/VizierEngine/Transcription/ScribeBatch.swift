import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

/// The wire format of ElevenLabs Scribe batch speech-to-text (`POST /v1/speech-to-text`), checked
/// against the API reference: a multipart form with the file and settings, answered
/// with JSON whose `text` is the transcript. Files up to 5 GB; no duration limit is documented.
/// A 26-minute file of joined takes came back in 24 to 32 s with 99 to 100% of the words
/// its parts had, three runs of three, with no doubled passages.
public enum ScribeBatch {
    public static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    /// The API takes up to 1,000 keyterms, but past 100 each request bills at least 20 s.
    public static let maxKeyterms = 100
    /// Each keyterm must be under 50 characters and at most five words.
    public static let maxKeytermLength = 49
    public static let maxKeytermWords = 5

    public struct Config: Equatable, Sendable {
        public var model: String
        /// An ISO 639 code without a region, as the realtime setup keeps it.
        public var language: String?
        public var vocabulary: [String]

        public init(model: String, languages: [String], vocabulary: [String]) {
            self.model = model
            self.language = ScribeLanguage.code(from: languages.first)
            self.vocabulary = vocabulary
        }
    }

    /// The vocabulary terms the batch model accepts, in order. Terms that don't fit are left out
    /// rather than truncated into something else.
    public static func keyterms(_ vocabulary: [String]) -> [String] {
        Array(vocabulary.lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= maxKeytermLength && $0.split(whereSeparator: \.isWhitespace).count <= maxKeytermWords }
            .prefix(maxKeyterms))
    }

    /// The form fields in order, then the file. Keyterms repeat the field, one term each.
    public static func formFields(_ config: Config) -> [(String, String)] {
        var fields: [(String, String)] = [("model_id", config.model), ("tag_audio_events", "false")]
        if let language = config.language { fields.append(("language_code", language)) }
        fields += keyterms(config.vocabulary).map { ("keyterms", $0) }
        return fields
    }

    public static func multipartBody(audio: Data, filename: String, config: Config, boundary: String) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for (name, value) in formFields(config) {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(name)\"")
            line("")
            line(value)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"")
        line("Content-Type: audio/flac")
        line("")
        body.append(audio)
        line("")
        line("--\(boundary)--")
        return body
    }

    public static func transcript(from body: Data) throws -> String {
        try JSONDecoder().decode(Wire.Response.self, from: body).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The error's message from either shape the API uses (`detail` as an object or a string),
    /// or the start of the body.
    public static func errorMessage(from body: Data) -> String {
        if let error = try? JSONDecoder().decode(Wire.ObjectError.self, from: body) {
            return [error.detail.status, error.detail.message].compactMap { $0 }.joined(separator: ": ")
        }
        if let error = try? JSONDecoder().decode(Wire.StringError.self, from: body) { return error.detail }
        return String(decoding: body.prefix(300), as: UTF8.self)
    }

    private enum Wire {
        struct Response: Decodable { var text: String }
        struct ObjectError: Decodable {
            struct Detail: Decodable { var status: String?; var message: String? }
            var detail: Detail
        }
        struct StringError: Decodable { var detail: String }
    }
}

/// Sends a saved FLAC take to Scribe batch in one request, whatever its length.
public struct ScribeBatchTranscriber: BatchTranscriber {
    public typealias Perform = GeminiBatchTranscriber.Perform

    private let config: ScribeBatch.Config
    private let apiKey: String
    private let perform: Perform
    private let log = Logger(subsystem: "net.praxient.dictum", category: "scribe-batch")

    public init(config: ScribeBatch.Config, apiKey: String) {
        // The shared session refuses redirects, so the key header never follows one off the API host.
        self.init(config: config, apiKey: apiKey, perform: { try await GeminiBatchTranscriber.urlSession.data(for: $0) })
    }

    public init(config: ScribeBatch.Config, apiKey: String, perform: @escaping Perform) {
        self.config = config
        self.apiKey = apiKey
        self.perform = perform
    }

    public func transcribeReporting(_ audio: URL) async throws -> BatchReport {
        let bytes = try Data(contentsOf: audio)
        let clock = ContinuousClock()
        let started = clock.now
        let boundary = "vizier-\(UUID().uuidString)"
        // A 26-minute take took 32 s; the interval is the longest silence while the server works.
        var request = URLRequest(url: ScribeBatch.endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = ScribeBatch.multipartBody(audio: bytes, filename: audio.lastPathComponent, config: config, boundary: boundary)
        let (body, response) = try await perform(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BatchError.http(status: status, message: ScribeBatch.errorMessage(from: body)) }
        let text = try ScribeBatch.transcript(from: body)
        let report = BatchReport(
            route: .scribe, bytes: bytes.count, uploadSeconds: 0, transcriptionSeconds: (clock.now - started).seconds,
            remoteDeleted: nil, result: BatchTranscript(text: text, truncated: false), retried: false)
        log.notice("scribe batch: \(report.bytes) bytes, \(report.transcriptionSeconds, format: .fixed(precision: 1)) s, \(report.wordCount) words")
        return report
    }
}
