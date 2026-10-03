#if os(Linux)
import Foundation
import Testing
@testable import VizierEngine

@Suite struct WebSocketTransportTests {
    typealias Provider = WebSocketTestServer.Provider
    private static let timeoutMs = 800
    // Exactly 100 ms of synthetic 16 kHz mono s16le, with enough energy to count as speech.
    private static let pcm = Data((0..<1600).flatMap { i -> [UInt8] in
        let value = Int16(sin(Double(i) * 2 * .pi * 440 / 16000) * 6000)
        return [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    })
    private static let orderedChunks = (0..<5).map { index in Data(pcm.map { $0 ^ UInt8(index) }) }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LiveTranscriberEvent] = []
        func append(_ event: LiveTranscriberEvent) { lock.withLock { values.append(event) } }
        var all: [LiveTranscriberEvent] { lock.withLock { values } }
    }
    private func make(_ provider: Provider, _ server: WebSocketTestServer) -> any LiveTranscriber {
        switch provider {
        case .scribe:
            ScribeRealtimeTranscriber(setup: .init(model: "test", languages: [], vocabulary: [], noVerbatim: false), apiKey: "synthetic-test-key", finalTimeoutMs: Self.timeoutMs, endpoint: server.endpoint)
        case .gemini:
            GeminiLiveTranscriber(setup: .init(model: "test", mode: "SMART", languages: [], vocabulary: []), apiKey: "synthetic-test-key", finalTimeoutMs: Self.timeoutMs, endpoint: server.endpoint)
        }
    }
    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }
    /// An independent watchdog cancels the real transport if its final timer regresses.
    private func finish(_ transcriber: any LiveTranscriber) async -> Result<String, TranscriberError> {
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(2)); transcriber.cancel() } catch {}
        }
        defer { watchdog.cancel() }
        let start = ContinuousClock.now
        let result: Result<String, TranscriberError>
        do { result = .success(try await transcriber.finish()) }
        catch let error as TranscriberError { result = .failure(error) }
        catch { Issue.record("unexpected error type: \(error)"); result = .failure(.timedOut) }
        #expect(ContinuousClock.now - start < .milliseconds(1500), "finish exceeded its own final timeout plus scheduling margin")
        return result
    }
    private func audio(_ frame: WebSocketTestServer.Frame, _ provider: Provider) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: frame.data) as? [String: Any] else { return nil }
        let base64: String?
        switch provider {
        case .scribe:
            guard json["commit"] as? Bool == false else { return nil }
            base64 = json["audio_base_64"] as? String
        case .gemini:
            let realtime = json["realtimeInput"] as? [String: Any]
            base64 = (realtime?["audio"] as? [String: Any])?["data"] as? String
        }
        return base64.flatMap { Data(base64Encoded: $0) }
    }

    @Test(arguments: Provider.allCases)
    func happyPath(_ provider: Provider) async throws {
        // RFC 6455's published handshake vector independently checks the helper's SHA-1.
        #expect(WebSocketTestServer.sha1(Data("dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11".utf8)).base64EncodedString() == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        let server = try WebSocketTestServer(provider: provider, behavior: .happy)
        defer { server.stop(); #expect(server.snapshot.error == nil) }
        let transcriber = make(provider, server), events = Events()
        transcriber.start { events.append($0) }
        for chunk in Self.orderedChunks { transcriber.send(chunk) }
        #expect(await waitUntil { events.all.contains(.transcript(settled: "", pending: "zorblex")) })
        #expect(await finish(transcriber) == .success("Zorblex."))
        #expect(events.all.contains(.transcript(settled: "Zorblex.", pending: "")))
        let frames = server.snapshot.frames
        #expect(frames.compactMap { audio($0, provider) } == Self.orderedChunks)
        #expect(frames.allSatisfy { $0.masked })
        #expect(await waitUntil { server.snapshot.frames.contains { $0.opcode == 10 && $0.data == Data("probe".utf8) } })
        #expect(server.snapshot.error == nil)
    }

    @Test(arguments: Provider.allCases, [401, 400])
    func refusedUpgrade(_ provider: Provider, _ status: Int) async throws {
        let server = try WebSocketTestServer(provider: provider, behavior: .refuse(status))
        defer { server.stop(); #expect(server.snapshot.error == nil) }
        let transcriber = make(provider, server), events = Events()
        transcriber.start { events.append($0) }
        #expect(await waitUntil { !events.all.isEmpty })
        let result = await finish(transcriber)
        guard case .failure(.streamLost(let reason)) = result else { Issue.record("expected stream loss: \(result)"); return }
        #expect(reason.contains("HTTP \(status)"))
        #expect(events.all == [.streamLost(reason)])
    }

    @Test(arguments: Provider.allCases)
    func serverCloseMidTake(_ provider: Provider) async throws {
        let server = try WebSocketTestServer(provider: provider, behavior: .close(1008, "synthetic policy reason"))
        defer { server.stop(); #expect(server.snapshot.error == nil) }
        let transcriber = make(provider, server), events = Events()
        transcriber.start { events.append($0) }
        transcriber.send(Self.pcm)
        #expect(await waitUntil { events.all.contains { if case .streamLost = $0 { true } else { false } } })
        let result = await finish(transcriber)
        guard case .failure(.streamLost(let reason)) = result else { Issue.record("expected stream loss: \(result)"); return }
        #expect(reason.contains("closed 1008"))
        #expect(reason.contains("synthetic policy reason"))
        #expect(events.all == [.streamLost(reason)])
    }

    @Test(arguments: Provider.allCases)
    func disconnectDuringSend(_ provider: Provider) async throws {
        let server = try WebSocketTestServer(provider: provider, behavior: .dropDuringSend)
        defer { server.stop(); #expect(server.snapshot.error == nil) }
        let transcriber = make(provider, server), events = Events()
        transcriber.start { events.append($0) }
        // Queue multiple PCM chunks so there is more work when the peer resets mid-payload.
        for _ in 0..<20 { transcriber.send(Self.pcm) }
        #expect(await waitUntil { !events.all.isEmpty })
        let result = await finish(transcriber)
        guard case .failure(.streamLost(let reason)) = result else { Issue.record("expected stream loss: \(result)"); return }
        #expect(events.all == [.streamLost(reason)])
        #expect(server.snapshot.droppedDuringPayload)
    }

    @Test(arguments: Provider.allCases)
    func disconnectDuringFinish(_ provider: Provider) async throws {
        let server = try WebSocketTestServer(provider: provider, behavior: .dropDuringFinish)
        defer { server.stop(); #expect(server.snapshot.error == nil) }
        let transcriber = make(provider, server), events = Events()
        transcriber.start { events.append($0) }
        for _ in 0..<5 { transcriber.send(Self.pcm) }
        #expect(await waitUntil { server.snapshot.frames.compactMap { audio($0, provider) }.count == 5 })
        let result = await finish(transcriber)
        guard case .failure(.streamLost(let reason)) = result else { Issue.record("expected stream loss: \(result)"); return }
        #expect(events.all == [.streamLost(reason)])
    }

    @Test(arguments: Provider.allCases)
    func cancelPendingFinish(_ provider: Provider) async throws {
        let server = try WebSocketTestServer(provider: provider, behavior: .silent)
        defer { server.stop(); #expect(server.snapshot.error == nil) }
        let transcriber = make(provider, server), events = Events()
        transcriber.start { events.append($0) }
        transcriber.send(Self.pcm)
        #expect(await waitUntil { server.snapshot.frames.contains { audio($0, provider) != nil } })
        let pending = Task { await finish(transcriber) }
        // Wait for the finish marker, proving cancellation interrupts an outstanding waiter.
        #expect(await waitUntil {
            server.snapshot.frames.contains { frame in
                let text = String(decoding: frame.data, as: UTF8.self)
                return provider == .scribe ? text.contains("\"commit\":true") : text.contains("activityEnd")
            }
        })
        transcriber.cancel()
        #expect(await pending.value == .failure(.cancelled))
        #expect(await finish(transcriber) == .failure(.cancelled))
        #expect(events.all.isEmpty)
    }

    @Test(arguments: Provider.allCases, [false, true])
    func finalTimeout(_ provider: Provider, _ neverSetup: Bool) async throws {
        let server = try WebSocketTestServer(provider: provider, behavior: neverSetup ? .neverSetup : .silent)
        defer { server.stop(); #expect(server.snapshot.error == nil) }
        let transcriber = make(provider, server), events = Events()
        transcriber.start { events.append($0) }
        for _ in 0..<5 { transcriber.send(Self.pcm) }
        #expect(await waitUntil { server.snapshot.upgraded })
        if !neverSetup {
            #expect(await waitUntil { server.snapshot.frames.compactMap { audio($0, provider) }.count == 5 })
        }
        let start = ContinuousClock.now
        #expect(await finish(transcriber) == .failure(.timedOut))
        #expect(ContinuousClock.now - start >= .milliseconds(Self.timeoutMs - 100))
        #expect(events.all.isEmpty)
    }
}
#endif
