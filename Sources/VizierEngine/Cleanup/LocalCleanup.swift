import Foundation

/// Local cleanup: a bring-your-own cleanup model server on this Mac, behind the
/// OpenAI-style `POST /v1/chat/completions`. The server builds its own prompt and glossary and
/// takes the transcript as the last user message, alone; it returns the raw transcript whenever
/// its own checks fail, and logs no text. In testing it took 0.6 s on short takes and
/// 3 to 5 s past about 100 words.
public enum LocalCleanup {
    public static let defaultURL = URL(string: "http://127.0.0.1:8747/v1/chat/completions")!

    public static func requestBody(transcript: String, model: String) throws -> Data {
        let body = Wire.Request(model: model, messages: [.init(role: "user", content: transcript)], temperature: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(body)
    }

    public static func text(from response: Data) throws -> String {
        let decoded = try JSONDecoder().decode(Wire.Response.self, from: response)
        guard let choice = decoded.choices.first, let content = choice.message.content else {
            throw CleanupError.blocked("no answer")
        }
        if let reason = choice.finishReason, reason != "stop" { throw CleanupError.unfinished(reason) }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum Wire {
        struct Request: Encodable {
            var model: String
            var messages: [Message]
            var temperature: Double
        }
        struct Message: Codable {
            var role: String
            var content: String?
        }
        struct Response: Decodable {
            var choices: [Choice]
        }
        struct Choice: Decodable {
            var message: Message
            var finishReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
    }
}

/// Sends a finished transcript to the local cleanup server. Refuses any URL off this Mac.
public struct LocalCleaner: TextCleaner {
    public typealias Perform = GeminiBatchTranscriber.Perform

    private let url: URL
    private let model: String
    private let perform: Perform

    public init(url: URL = LocalCleanup.defaultURL, model: String) {
        self.init(url: url, model: model, perform: { try await GeminiBatchTranscriber.urlSession.data(for: $0) })
    }

    public init(url: URL, model: String, perform: @escaping Perform) {
        self.url = url
        self.model = model
        self.perform = perform
    }

    public func clean(_ transcript: String) async throws -> String {
        guard Loopback.allows(url) else { throw LocalEngineError.notLoopback(url.absoluteString) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try LocalCleanup.requestBody(transcript: transcript, model: model)
        let (body, response) = try await perform(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CleanupError.http(status: status, message: String(decoding: body.prefix(300), as: UTF8.self)) }
        return try LocalCleanup.text(from: body)
    }
}
