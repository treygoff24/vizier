import Foundation
import Testing
@testable import VizierEngine

/// A batch link that answers or fails from a script, counting its calls.
private final class ScriptedLink: BatchTranscriber, @unchecked Sendable {
    let answer: Result<String, BatchError>
    let route: BatchReport.Route
    private(set) var calls = 0

    init(_ answer: Result<String, BatchError>, route: BatchReport.Route = .scribe) {
        self.answer = answer
        self.route = route
    }

    func transcribeReporting(_ audio: URL) async throws -> BatchReport {
        calls += 1
        let text = try answer.get()
        return BatchReport(route: route, bytes: 0, uploadSeconds: 0, transcriptionSeconds: 0, remoteDeleted: nil,
                           result: BatchTranscript(text: text, truncated: false), retried: false)
    }
}

/// Fixtures are synthetic words in the shapes whisper.cpp's server and an OpenAI-style chat
/// completion return.
@Suite struct LocalEngineTests {
    @Test func whisperPostsTheFileToThisMacAndJoinsItsSegmentsOnOneLine() async throws {
        let server = StubServer { _ in (200, [:], Data(#"{"text": " Zorblex the quaxil.\n And the gantry.\n"}"#.utf8)) }
        let url = try Fixture.flac(seconds: 1)
        let report = try await LocalWhisperTranscriber(url: LocalWhisper.defaultURL, perform: { await server.answer($0) }).transcribeReporting(url)
        #expect(report.transcript == "Zorblex the quaxil. And the gantry.")
        #expect(report.route == .local)
        let request = try #require(await server.requests.first)
        #expect(request.url == LocalWhisper.defaultURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.split(separator: "=", maxSplits: 1).last.map(String.init))
        #expect(request.httpBody == LocalWhisper.multipartBody(audio: try Data(contentsOf: url), filename: url.lastPathComponent, boundary: boundary))
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"response_format\"\r\n\r\njson\r\n") && body.contains("name=\"temperature\"\r\n\r\n0\r\n"))
    }

    @Test func whisperFailsLoudOnAnErrorStatus() async throws {
        let server = StubServer { _ in (500, [:], Data("model not loaded".utf8)) }
        let url = try Fixture.flac(seconds: 1)
        await #expect(throws: BatchError.http(status: 500, message: "model not loaded")) {
            try await LocalWhisperTranscriber(url: LocalWhisper.defaultURL, perform: { await server.answer($0) }).transcribeReporting(url)
        }
    }

    @Test func neitherLocalEngineSendsAnythingOffThisMac() async throws {
        let server = StubServer { _ in (200, [:], Data(#"{"text": "leak"}"#.utf8)) }
        let url = try Fixture.flac(seconds: 1)
        let away = URL(string: "https://api.example.com/v1/audio/transcriptions")!
        await #expect(throws: LocalEngineError.notLoopback(away.absoluteString)) {
            try await LocalWhisperTranscriber(url: away, perform: { await server.answer($0) }).transcribeReporting(url)
        }
        let chatAway = URL(string: "http://10.0.0.2:8747/v1/chat/completions")!
        await #expect(throws: LocalEngineError.notLoopback(chatAway.absoluteString)) {
            try await LocalCleaner(url: chatAway, model: "q", perform: { await server.answer($0) }).clean("Zorblex")
        }
        #expect(await server.requests.isEmpty)
    }

    @Test(arguments: [
        ("http://127.0.0.1:8738/x", true), ("http://[::1]:8738/x", true), ("http://localhost:8747/x", false),
        ("http://LOCALHOST:8747/x", false), ("http://localhost.:8747/x", false), ("http://127.1:8738/x", false),
        ("https://127.0.0.1:8738/x", false), ("http://127.0.0.1.example.com/x", false), ("http://192.168.1.5/x", false),
        ("http://api.example.com/x", false),
    ])
    func loopbackMeansThisMacOverPlainHTTP(url: String, allowed: Bool) {
        #expect(Loopback.allows(URL(string: url)!) == allowed)
    }

    @Test func cleanupSendsTheTranscriptAloneAndReadsTheAnswer() async throws {
        let server = StubServer { _ in
            (200, [:], Data(#"{"id": "c1", "object": "chat.completion", "choices": [{"index": 0, "message": {"role": "assistant", "content": " Zorblex the quaxil. "}, "finish_reason": "stop"}]}"#.utf8))
        }
        let cleaned = try await LocalCleaner(url: LocalCleanup.defaultURL, model: "cleanup-model-x", perform: { await server.answer($0) })
            .clean("Um, Zorblex the, the quaxil.")
        #expect(cleaned == "Zorblex the quaxil.")
        let request = try #require(await server.requests.first)
        #expect(request.url == LocalCleanup.defaultURL)
        let sent = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(sent?["model"] as? String == "cleanup-model-x")
        let messages = try #require(sent?["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "Um, Zorblex the, the quaxil."]])
    }

    @Test func cleanupThatStopsEarlyOrFailsThrows() async throws {
        let cut = StubServer { _ in (200, [:], Data(#"{"choices": [{"message": {"role": "assistant", "content": "Zorblex"}, "finish_reason": "length"}]}"#.utf8)) }
        await #expect(throws: CleanupError.unfinished("length")) {
            try await LocalCleaner(url: LocalCleanup.defaultURL, model: "q", perform: { await cut.answer($0) }).clean("Zorblex the quaxil")
        }
        let down = StubServer { _ in (503, [:], Data("busy".utf8)) }
        await #expect(throws: CleanupError.http(status: 503, message: "busy")) {
            try await LocalCleaner(url: LocalCleanup.defaultURL, model: "q", perform: { await down.answer($0) }).clean("Zorblex")
        }
    }

    @Test func theChainTriesEachLinkInOrderUntilOneAnswers() async {
        let cloud = ScriptedLink(.failure(.http(status: 0, message: "offline")))
        let local = ScriptedLink(.success("Zorblex the quaxil."), route: .local)
        let unused = ScriptedLink(.success("never"))
        let links = [BatchChain.Link(engine: "elevenlabs-scribe-batch", transcriber: cloud),
                     BatchChain.Link(engine: "local-whisper", transcriber: local),
                     BatchChain.Link(engine: "gemini-batch", transcriber: unused)]
        guard case .success(let answer) = await BatchChain.run(links, audio: URL(fileURLWithPath: "/tmp/t.flac")) else {
            Issue.record("the chain did not answer")
            return
        }
        #expect(answer.index == 1 && answer.engine == "local-whisper" && answer.report.transcript == "Zorblex the quaxil.")
        #expect(cloud.calls == 1 && local.calls == 1 && unused.calls == 0)
    }

    @Test func aChainWithNoAnswerReportsEveryErrorAndWhetherTheTakeWasTooLong() async {
        let tooLong = ScriptedLink(.failure(.tooLong(seconds: 4000)))
        let down = ScriptedLink(.failure(.http(status: 0, message: "refused")))
        guard case .failure(let failure) = await BatchChain.run(
            [.init(engine: "gemini-batch", transcriber: tooLong), .init(engine: "local-whisper", transcriber: down)],
            audio: URL(fileURLWithPath: "/tmp/t.flac")) else {
            Issue.record("the chain answered")
            return
        }
        #expect(failure.errors.map(\.engine) == ["gemini-batch", "local-whisper"])
        #expect(failure.tooLong)
        guard case .failure(let plain) = await BatchChain.run([.init(engine: "local-whisper", transcriber: down)], audio: URL(fileURLWithPath: "/tmp/t.flac")) else {
            Issue.record("the chain answered")
            return
        }
        #expect(!plain.tooLong)
    }

    @Test func localEnginesNeedNoKey() {
        #expect(Engines.keyAccount(for: "local-whisper") == nil)
        #expect(Engines.keyAccount(for: "local-cleanup") == nil)
        #expect(Engines.keyAccount(for: "elevenlabs-scribe-batch") == .elevenLabs)
        #expect(Engines.keyAccount(for: "gemini-generate") == .gemini)
    }

    @Test func aLocalReRunReadsNoKeyAndAnOfflineFallbackStandsInForAMissingOne() throws {
        let config = VizierConfig()
        var asked: [String] = []
        var local = VizierConfig.Mode.local
        local.cleanup = .init(engine: "local-cleanup", model: "cleanup-model-x", thinkingLevel: nil, timeoutMs: 8000)
        let plan = try Rerun.plan(mode: local, config: config) { asked.append($0); return "k" }
        #expect(asked.isEmpty)
        #expect(plan.transcriber is LocalWhisperTranscriber && plan.transcriberEngine == "local-whisper")
        #expect(plan.cleanup?.cleaner is LocalCleaner && plan.cleanup?.engine == "local-cleanup")

        var scribe = VizierConfig.Mode.scribe
        scribe.fallback = .init(engine: "elevenlabs-scribe-batch", model: "scribe_v2", mode: "verbatim")
        scribe.offlineFallback = .init(engine: "local-whisper", model: "large-v3-turbo", mode: "verbatim")
        let withKey = try Rerun.plan(mode: scribe, config: config) { _ in "k" }
        #expect(withKey.transcriberEngine == "elevenlabs-scribe-batch")
        let noKey = try Rerun.plan(mode: scribe, config: config) { _ in nil }
        #expect(noKey.transcriberEngine == "local-whisper")
    }
}
