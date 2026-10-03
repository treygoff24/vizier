import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif
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
        #expect((body.value(forKey: "generation_config") as? NSDictionary)?.value(forKey: "transcription_config") as? NSDictionary == ["mode": "smart"])
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
#if canImport(Network)
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
#else
// The same server on POSIX sockets, for platforms without Apple's Network framework.
import Glibc

final class RedirectServer: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var seen: [String] = []
    /// Signalled once the accept loop has returned, so `stop` closes the socket only after it.
    private let finished = DispatchSemaphore(value: 0)
    let port: UInt16
    var paths: [String] { lock.withLock { seen } }

    private init() throws {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    static func start() async throws -> RedirectServer {
        let server = try RedirectServer()
        Thread.detachNewThread { server.acceptLoop() }
        return server
    }

    /// Wakes a blocked `accept` with `shutdown`, waits for the loop to return, then closes the
    /// descriptor once, so the loop never touches a descriptor number reused elsewhere.
    func stop() {
        shutdown(descriptor, Int32(SHUT_RDWR))
        finished.wait()
        close(descriptor)
    }

    private func acceptLoop() {
        defer { finished.signal() }
        while true {
            let connection = accept(descriptor, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return
            }
            // A client that stalls cannot hold the loop: reads give up after two seconds.
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let path = Self.requestPath(connection)
            lock.withLock { seen.append(path) }
            let reply = path == "/start"
                ? "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(port)/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            Self.sendAll(Array(reply.utf8), to: connection)
            close(connection)
        }
    }

    /// The request line's path, read until the first CRLF (TCP may split it), capped at 64 KiB.
    private static func requestPath(_ connection: Int32) -> String {
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while received.count < 65_536, !received.containsCRLF {
            let count = read(connection, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            received.append(contentsOf: chunk[0..<count])
        }
        let line = String(decoding: received, as: UTF8.self).split(separator: "\r\n").first ?? ""
        return line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }

    /// Writes every byte, retrying short writes and EINTR; a gone peer ends it without SIGPIPE.
    private static func sendAll(_ bytes: [UInt8], to connection: Int32) {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes[offset...].withUnsafeBytes { send(connection, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            if sent < 0, errno == EINTR { continue }
            if sent <= 0 { return }
            offset += sent
        }
    }
}

private extension Array where Element == UInt8 {
    var containsCRLF: Bool {
        guard count >= 2 else { return false }
        return (1..<count).contains { self[$0 - 1] == 13 && self[$0] == 10 }
    }
}
#endif
