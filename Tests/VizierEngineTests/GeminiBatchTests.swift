import Foundation
import Network
import Testing
@testable import VizierEngine

/// Fixtures are synthetic words in the shapes of the Interactions API reference examples.
@Suite struct GeminiBatchTests {
    private let config = GeminiBatch.Config(model: "gemini-3.5-transcribe", mode: "smart", languages: ["en-US"], vocabulary: ["Zorblex"])

    private func json(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test func requestIsSnakeCaseWithTheConfigUnderTranscriptionConfig() throws {
        let body = try GeminiBatch.requestBody(audio: Data([0x66, 0x4C, 0x61, 0x43]), mimeType: "audio/flac", config: config)
        let expected = try json(Data("""
        {"model": "gemini-3.5-transcribe",
         "input": [{"type": "audio", "data": "ZkxhQw==", "mime_type": "audio/flac"}],
         "generation_config": {"transcription_config": {"mode": "smart", "language_codes": ["en-US"], "custom_vocabulary": ["Zorblex"]}},
         "store": false}
        """.utf8))
        #expect(try json(body) == expected)
    }

    @Test func aFileReferenceReplacesTheInlineDataAndKeepsEverythingElse() throws {
        let inline = try json(GeminiBatch.requestBody(audio: Data([0x66]), mimeType: "audio/flac", config: config)).mutableCopy() as! NSMutableDictionary
        inline["input"] = [["type": "audio", "uri": "https://generativelanguage.googleapis.com/v1beta/files/quaxil-7", "mime_type": "audio/flac"]]
        let byReference = try GeminiBatch.requestBody(
            fileURI: "https://generativelanguage.googleapis.com/v1beta/files/quaxil-7", mimeType: "audio/flac", config: config)
        #expect(try json(byReference) == inline)
    }

    @Test func emptyListsAreLeftOutButTheModeNeverIs() throws {
        let bare = GeminiBatch.Config(model: "m", mode: "smart", languages: [], vocabulary: [])
        let body = try json(GeminiBatch.requestBody(audio: Data(), mimeType: "audio/flac", config: bare))
        #expect(body.value(forKeyPath: "generation_config.transcription_config") as? NSDictionary == ["mode": "smart"])
    }

    @Test func readsTheTextOfModelOutputSteps() throws {
        let response = """
        {"id": "v1_x", "object": "interaction", "status": "completed",
         "steps": [
           {"type": "thought", "content": [{"type": "text", "text": "ignored"}]},
           {"type": "model_output", "content": [{"type": "text", "text": "Zorblex the "}, {"type": "thought_summary", "text": "ignored"}, {"type": "text", "text": "quaxil.\\n"}]}
         ],
         "usage": {"total_tokens": 49}}
        """
        #expect(try GeminiBatch.transcript(from: Data(response.utf8)) == BatchTranscript(text: "Zorblex the quaxil.", truncated: false))
    }

    @Test func aCompletedInteractionWithNoTextIsEmpty() throws {
        #expect(try GeminiBatch.transcript(from: Data(#"{"status": "completed", "steps": []}"#.utf8)) == BatchTranscript(text: "", truncated: false))
    }

    /// The shape live probes saw: the model hit its output ceiling mid-loop.
    @Test func anIncompleteInteractionKeepsItsTextMarkedTruncated() throws {
        let response = #"{"status": "incomplete", "steps": [{"type": "model_output", "content": [{"type": "text", "text": "Zorblex the quaxil. the the the"}]}]}"#
        #expect(try GeminiBatch.transcript(from: Data(response.utf8)) == BatchTranscript(text: "Zorblex the quaxil. the the the", truncated: true))
    }

    @Test func anIncompleteInteractionWithNoTextThrows() {
        let response = #"{"status": "incomplete", "steps": [{"type": "model_output", "content": [{"type": "text", "text": "  "}]}]}"#
        #expect(throws: BatchError.incomplete(status: "incomplete")) { try GeminiBatch.transcript(from: Data(response.utf8)) }
    }

    @Test func anotherUnfinishedStatusThrowsEvenWithText() {
        let response = #"{"status": "failed", "steps": [{"type": "model_output", "content": [{"type": "text", "text": "Zorblex"}]}]}"#
        #expect(throws: BatchError.incomplete(status: "failed")) { try GeminiBatch.transcript(from: Data(response.utf8)) }
    }

    @Test func anUnfinishedInteractionThrows() {
        #expect(throws: BatchError.incomplete(status: "failed")) {
            try GeminiBatch.transcript(from: Data(#"{"status": "failed", "steps": []}"#.utf8))
        }
    }

    @Test func errorBodiesGiveTheirStatusAndMessage() {
        let body = #"{"error": {"code": 400, "message": "Invalid audio.", "status": "INVALID_ARGUMENT"}}"#
        #expect(GeminiBatch.errorMessage(from: Data(body.utf8)) == "INVALID_ARGUMENT: Invalid audio.")
        #expect(GeminiBatch.errorMessage(from: Data("<html>bad gateway</html>".utf8)) == "<html>bad gateway</html>")
    }

    @Test func theLargestInlineTakeWithAFullVocabularyStaysUnderTwentyMegabytes() throws {
        let vocabulary = (0..<1_000).map { "term\($0)-zorblex" }
        let full = GeminiBatch.Config(model: "gemini-3.5-transcribe", mode: "smart", languages: ["en-US"], vocabulary: vocabulary)
        let body = try GeminiBatch.requestBody(audio: Data(count: GeminiBatch.maxInlineAudioBytes), mimeType: "audio/flac", config: full)
        #expect(body.count < 20_000_000)
    }
}

/// The batch session must never follow a redirect: URLSession would copy `x-goog-api-key` (and on
/// a 307, the body) to wherever `Location` points.
@Suite struct BatchRedirectTests {
    @Test func theDelegateRefusesRedirectsToAnyHost() {
        let delegate = RefuseRedirects()
        let task = URLSession.shared.dataTask(with: GeminiBatch.endpoint)
        for target in ["https://evil.example/steal", "https://generativelanguage.googleapis.com/v1beta/interactions?moved=1"] {
            let response = HTTPURLResponse(url: GeminiBatch.endpoint, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            let passed = Passed()
            delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: target)!)) { passed.set($0) }
            #expect(passed.called && passed.request == nil, "\(target)")
        }
    }

    /// A real request through the transcriber's own session to a local server that answers 307:
    /// the redirect comes back as the response, and the target never sees a request.
    @Test func theBatchSessionReturnsTheRedirectInsteadOfFollowingIt() async throws {
        let server = try await RedirectServer.start()
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/start")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("test-key", forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = Data("audio".utf8)
        let (_, response) = try await GeminiBatchTranscriber.urlSession.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 307)
        #expect(server.paths == ["/start"])
    }

    final class Passed: @unchecked Sendable {
        private(set) var called = false
        private(set) var request: URLRequest?
        func set(_ request: URLRequest?) { called = true; self.request = request }
    }
}

/// A one-route HTTP server on 127.0.0.1: `/start` answers 307 to `/stolen`; anything else 200.
final class RedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "redirect-server")
    private let lock = NSLock()
    private var seen: [String] = []
    var paths: [String] { lock.withLock { seen } }
    var port: UInt16 { listener.port!.rawValue }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> RedirectServer {
        let server = try RedirectServer()
        server.listener.newConnectionHandler = { [server] connection in server.serve(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = NSLock()
            nonisolated(unsafe) var done = false
            server.listener.stateUpdateHandler = { state in
                resumed.withLock {
                    guard !done else { return }
                    switch state {
                    case .ready: done = true; continuation.resume()
                    case .failed(let error): done = true; continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            lock.withLock { seen.append(path) }
            let reply = path == "/start"
                ? "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(port)/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
