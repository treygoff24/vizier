import Foundation
import os

/// Local transcription: whisper.cpp's `whisper-server` on this Mac, serving large-v3-turbo behind
/// the OpenAI-style `POST /v1/audio/transcriptions` path (started with `--inference-path`). A
/// multipart form with the file, answered with JSON whose `text` is the transcript. It reads the
/// take's FLAC directly. On an M4 Max, takes of 13 to 43 s took 0.8 to 2.0 s.
///
/// Local means local: every URL is checked to be loopback before a request is made, so a mode
/// chosen for privacy can never send audio or text off the machine.
public enum LocalWhisper {
    public static let defaultURL = URL(string: "http://127.0.0.1:8738/v1/audio/transcriptions")!

    public static func multipartBody(audio: Data, filename: String, boundary: String) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for (name, value) in [("response_format", "json"), ("temperature", "0")] {
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

    /// The transcript on one line: the server ends each speech segment with a newline.
    public static func transcript(from body: Data) throws -> String {
        let text = try JSONDecoder().decode(Wire.self, from: body).text
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private struct Wire: Decodable { var text: String }
}

/// Where a local engine may send anything: plain HTTP to this Mac's loopback address, written as
/// a numeric literal (127.0.0.1 or [::1]). `localhost` is refused: it goes through name resolution,
/// which /etc/hosts or a resolver profile can point off the machine.
public enum Loopback {
    public static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host()?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

public enum LocalEngineError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The configured URL is not on this Mac. Nothing was sent.
    case notLoopback(String)

    public var description: String {
        switch self {
        case .notLoopback(let url): "\(url) is not on this Mac, so nothing was sent"
        }
    }
}

/// Sends a saved FLAC take to the local whisper server in one request.
public struct LocalWhisperTranscriber: BatchTranscriber {
    public typealias Perform = GeminiBatchTranscriber.Perform

    private let url: URL
    private let perform: Perform
    private let log = Logger(subsystem: "net.praxient.dictum", category: "local-whisper")

    public init(url: URL = LocalWhisper.defaultURL) {
        self.init(url: url, perform: { try await GeminiBatchTranscriber.urlSession.data(for: $0) })
    }

    public init(url: URL, perform: @escaping Perform) {
        self.url = url
        self.perform = perform
    }

    public func transcribeReporting(_ audio: URL) async throws -> BatchReport {
        guard Loopback.allows(url) else { throw LocalEngineError.notLoopback(url.absoluteString) }
        let bytes = try Data(contentsOf: audio)
        let clock = ContinuousClock()
        let started = clock.now
        let boundary = "vizier-\(UUID().uuidString)"
        // Whisper runs about 25 times faster than speech here, so a 12-minute take takes about 30 s.
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = LocalWhisper.multipartBody(audio: bytes, filename: audio.lastPathComponent, boundary: boundary)
        let (body, response) = try await perform(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BatchError.http(status: status, message: String(decoding: body.prefix(300), as: UTF8.self)) }
        let text = try LocalWhisper.transcript(from: body)
        let report = BatchReport(
            route: .local, bytes: bytes.count, uploadSeconds: 0, transcriptionSeconds: (clock.now - started).seconds,
            remoteDeleted: nil, result: BatchTranscript(text: text, truncated: false), retried: false)
        log.notice("local whisper: \(report.bytes) bytes, \(report.transcriptionSeconds, format: .fixed(precision: 1)) s, \(report.wordCount) words")
        return report
    }
}
