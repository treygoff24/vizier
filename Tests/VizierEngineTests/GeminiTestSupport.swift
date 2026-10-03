#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import VizierEngine

/// Every request the transcriber sends, answered from a canned script. Fixtures follow the
/// shapes in ai.google.dev/gemini-api/docs/files and ai.google.dev/api/files.
actor StubServer {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)
    private(set) var requests: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    func answer(_ request: URLRequest) -> (Data, URLResponse) {
        requests.append(request)
        let (status, headers, body) = handler(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

enum Fixture {
    static let config = GeminiBatch.Config(model: "gemini-3.5-transcribe", mode: "smart", languages: ["en-US"], vocabulary: ["Zorblex"])
    static let uploadURL = "https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=zx81&upload_protocol=resumable"
    static let interaction = answer("completed", "Zorblex the quaxil.")

    static func answer(_ status: String, _ text: String) -> Data {
        Data(#"{"status": "\#(status)", "steps": [{"type": "model_output", "content": [{"type": "text", "text": "\#(text)"}]}]}"#.utf8)
    }

    static func file(state: String) -> String {
        #"{"name": "files/quaxil-7", "displayName": "t", "mimeType": "audio/flac", "uri": "https://generativelanguage.googleapis.com/v1beta/files/quaxil-7", "state": "\#(state)"}"#
    }

    #if canImport(AVFoundation)
    /// A take's FLAC as TakeStore writes it: 16 kHz mono, named by its take id. `seconds` of a
    /// tone with deterministic noise, or of silence (which FLAC shrinks to almost nothing).
    static func flac(seconds: Int, silent: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vizier-files-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "2026-09-25T12-00-00.000Z.flac")
        let file = try AVAudioFile(forWriting: url, settings: TakeStore.flacSettings, commonFormat: .pcmFormatInt16, interleaved: true)
        let minute = 16_000 * 60
        let buffer = AVAudioPCMBuffer(pcmFormat: HALCapture.outputFormat, frameCapacity: AVAudioFrameCount(minute))!
        if !silent {
            for i in 0..<minute {
                buffer.int16ChannelData![0][i] = Int16(8_000 * sin(Double(i) * 2 * .pi * 440 / 16_000)) &+ Int16(truncatingIfNeeded: (i &* 7919) % 97)
            }
        }
        var left = seconds * 16_000
        while left > 0 {
            buffer.frameLength = AVAudioFrameCount(min(left, minute))
            try file.write(from: buffer)
            left -= Int(buffer.frameLength)
        }
        file.close()
        return url
    }
    #endif

    #if !canImport(AVFoundation)
    /// A take's FLAC from the pure-Swift encoder: 16 kHz mono, named by its take id, `seconds` of the
    /// same tone and noise the macOS fixture writes. `silent` gives only the file's header with
    /// `seconds` of length in its STREAMINFO and no audio frames: silence an hour long would take the
    /// encoder minutes, and the over-an-hour check reads the header alone. Not decodable audio.
    static func flac(seconds: Int, silent: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vizier-files-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "2026-09-25T12-00-00.000Z.flac")
        if silent {
            try FLACEncoder.encode([], sampleRate: 16_000, to: url)
            var bytes = try Data(contentsOf: url)
            let total = UInt64(seconds * 16_000)
            // STREAMINFO bytes 18...25 hold rate (20 bits), channels (3), depth (5), total samples (36).
            var packed: UInt64 = 0
            for index in 18..<26 { packed = packed << 8 | UInt64(bytes[index]) }
            packed = (packed & ~0x0f_ffff_ffff) | total
            for index in 0..<8 { bytes[18 + index] = UInt8(truncatingIfNeeded: packed >> (8 * (7 - index))) }
            try bytes.write(to: url)
            return url
        }
        let samples = (0..<seconds * 16_000).map { i in
            Int16(8_000 * sin(Double(i) * 2 * .pi * 440 / 16_000)) &+ Int16(truncatingIfNeeded: (i &* 7919) % 97)
        }
        try FLACEncoder.encode(samples, sampleRate: 16_000, to: url)
        return url
    }
    #endif

    static func size(_ url: URL) throws -> Int { try Data(contentsOf: url).count }

    /// A server where every step succeeds, with overrides by step. `answers` scripts successive
    /// interaction replies as (HTTP status, body); once it runs out, replies are completed.
    static func server(
        start: Int = 200, uploadLocation: String = uploadURL, upload: Int = 200, uploadBody: Data? = nil, interact: Int = 200, delete: Int = 200,
        uploadedState: String = "ACTIVE", polledStates: [String] = [], pollsSettleOn: String = "ACTIVE", answers: [(Int, Data)] = []
    ) -> StubServer {
        let polls = Script(polledStates, otherwise: pollsSettleOn)
        let replies = Script(answers, otherwise: (interact, interaction))
        return StubServer { request in
            let url = request.url!.absoluteString
            let error = Data(#"{"error": {"code": 500, "message": "Synthetic failure.", "status": "INTERNAL"}}"#.utf8)
            switch (request.httpMethod, url) {
            case ("POST", GeminiFiles.uploadEndpoint.absoluteString):
                return start == 200 ? (200, ["X-Goog-Upload-URL": uploadLocation], Data()) : (start, [:], error)
            case ("POST", uploadURL):
                return upload == 200 ? (200, [:], uploadBody ?? Data(#"{"file": \#(file(state: uploadedState))}"#.utf8)) : (upload, [:], error)
            case ("GET", _):
                return (200, [:], Data(file(state: polls.next()).utf8))
            case ("POST", GeminiBatch.endpoint.absoluteString):
                let (status, body) = replies.next()
                return status == 200 ? (200, [:], body) : (status, [:], error)
            case ("DELETE", _):
                return delete == 200 ? (200, [:], Data("{}".utf8)) : (delete, [:], error)
            default:
                return (404, [:], Data())
            }
        }
    }

    final class Script<Item>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Item]
        private let otherwise: Item
        init(_ items: [Item], otherwise: Item) { self.items = items; self.otherwise = otherwise }
        func next() -> Item { lock.withLock { items.isEmpty ? otherwise : items.removeFirst() } }
    }

    static func transcriber(_ server: StubServer, maxInlineBytes: Int) -> GeminiBatchTranscriber {
        GeminiBatchTranscriber(
            config: config, apiKey: "test-key", perform: { await server.answer($0) }, maxInlineBytes: maxInlineBytes,
            pollInterval: .zero)
    }

    static func json(_ data: Data?) throws -> NSDictionary {
        let data = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}
