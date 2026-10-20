#if os(Linux)
import Foundation
import Testing
@testable import VizierEngine

@Suite(.timeLimit(.minutes(1))) struct WebSocketTransportTests {
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

@Suite(.timeLimit(.minutes(1))) struct ScribeRepairTransportTests {
    private static let setup = ScribeRealtime.Setup(model: "test", languages: [], vocabulary: [], noVerbatim: false)
    // 400 ms of voice, 100 ms of room noise: no 300 ms pause before the forced 28 s commit.
    private static let firstChunks: [Data] = (0..<280).map { index in
        let level: Int16 = index % 5 == 4 ? 1_000 : 2_500
        return Data((0..<1600).flatMap { _ in withUnsafeBytes(of: level.littleEndian) { Array($0) } })
    }
    private static let tailChunks = Array(firstChunks.prefix(25))
    private static let first = firstChunks.reduce(Data(), +)
    private static let tail = tailChunks.reduce(Data(), +)

    private func make(_ server: WebSocketTestServer, preparationTimeoutMs: Int = 1_000) -> ScribeRealtimeTranscriber {
        ScribeRealtimeTranscriber(setup: Self.setup, apiKey: "synthetic-test-key", finalTimeoutMs: 3_000,
                                  endpoint: server.endpoint, preparationTimeoutMs: preparationTimeoutMs)
    }
    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }
    private func audio(_ snapshot: WebSocketTestServer.Snapshot) -> Data {
        snapshot.frames.reduce(into: Data()) { bytes, frame in
            guard let object = try? JSONSerialization.jsonObject(with: frame.data) as? [String: Any],
                  object["commit"] as? Bool == false,
                  let base64 = object["audio_base_64"] as? String,
                  let chunk = Data(base64Encoded: base64) else { return }
            bytes += chunk
        }
    }
    private func commits(_ snapshot: WebSocketTestServer.Snapshot) -> Int {
        snapshot.frames.count { frame in
            guard let object = try? JSONSerialization.jsonObject(with: frame.data) as? [String: Any] else { return false }
            return object["commit"] as? Bool == true
        }
    }
    private func start(_ transcriber: ScribeRealtimeTranscriber, _ server: WebSocketTestServer) async throws {
        transcriber.start { _ in }
        for chunk in Self.firstChunks { transcriber.send(chunk) }
        try #require(await waitUntil { server.snapshots.count == 2 && server.snapshots[1].upgraded }, "the first commit must open a spare")
        #expect(commits(server.snapshots[0]) == 1)
    }
    private func checkServer(_ server: WebSocketTestServer) {
        server.stop()
        #expect(server.snapshot.error == nil)
        #expect(server.snapshots.allSatisfy { $0.error == nil })
    }

    @Test(arguments: [false, true])
    func spareReceivesPrefillThenLiveAudioAndOneCommitOnlyAfterStop(_ holdSetup: Bool) async throws {
        let server = try WebSocketTestServer(provider: .scribe, behaviors: [.scribeRepairLive, holdSetup ? .heldSetup : .happy])
        defer { checkServer(server) }
        let transcriber = make(server, preparationTimeoutMs: holdSetup ? 10_000 : 1_000)
        defer { transcriber.cancel() }
        try await start(transcriber, server)
        let prefill = Self.first.subdata(in: 630_400..<Self.first.count) // frozen 19.7 s splice
        if holdSetup {
            try #require(await waitUntil { server.snapshots[1].waitingForSetup })
            #expect(audio(server.snapshots[1]).isEmpty)
        } else {
            try #require(await waitUntil { audio(server.snapshots[1]) == prefill })
        }
        #expect(commits(server.snapshots[1]) == 0)
        for chunk in Self.tailChunks { transcriber.send(chunk) }
        if holdSetup {
            // diagnostics() is a queue barrier: every send above has reached the not-ready Link
            // before the server is allowed to send session_started. No scheduler timing window.
            let diagnostics = await transcriber.diagnostics()
            try #require(server.snapshots[1].waitingForSetup)
            #expect(diagnostics["repair_audio_ms"] == 10_800)
            #expect(audio(server.snapshots[1]).isEmpty)
            server.releaseSetup(connection: 1)
        }
        try #require(await waitUntil { audio(server.snapshots[1]) == prefill + Self.tail })
        #expect(commits(server.snapshots[1]) == 0, "prefill must never commit speculatively")
        _ = try await transcriber.finish()
        try #require(await waitUntil { server.snapshots.allSatisfy(\.closed) })
        #expect(commits(server.snapshots[1]) == 1)
        #expect(audio(server.snapshots[1]) == prefill + Self.tail)
        let frames = server.snapshots[1].frames
        let application = frames.filter { $0.opcode == 1 || $0.opcode == 2 }
        let last = try #require(application.last)
        let object = try #require(try JSONSerialization.jsonObject(with: last.data) as? [String: Any])
        #expect(object["commit"] as? Bool == true, "commit follows all audio")
    }

    @Test(arguments: [false, true])
    func failedPreparationOpensAColdRepairAtStop(_ prematureCommit: Bool) async throws {
        let server = try WebSocketTestServer(provider: .scribe, behaviors: [.scribeRepairLive, prematureCommit ? .prematureCommit : .neverSetup, .happy])
        defer { checkServer(server) }
        let transcriber = make(server)
        defer { transcriber.cancel() }
        try await start(transcriber, server)
        let deadline = ContinuousClock.now + .seconds(5)
        var failures = 0
        while failures == 0, ContinuousClock.now < deadline {
            failures = (await transcriber.diagnostics())["repair_preparation_failures"] ?? 0
            if failures == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }
        try #require(failures == 1, "an unstarted or prematurely committed spare must fail preparation")
        try #require(await waitUntil { server.snapshots[1].closed })
        #expect(commits(server.snapshots[1]) == 0)
        if !prematureCommit { #expect(audio(server.snapshots[1]).isEmpty) }
        for chunk in Self.tailChunks { transcriber.send(chunk) }
        _ = try await transcriber.finish()
        try #require(await waitUntil { server.snapshots.count == 3 && server.snapshots[2].closed })
        let all = Self.first + Self.tail
        #expect(audio(server.snapshots[2]) == all.subdata(in: 707_200..<all.count), "cold retry recomputes the shorter 22.1 s splice")
        #expect(commits(server.snapshots[2]) == 1)
    }

    @Test func cancelClosesBothLiveAndPreparedSockets() async throws {
        let server = try WebSocketTestServer(provider: .scribe, behaviors: [.scribeRepairLive, .happy])
        defer { checkServer(server) }
        let transcriber = make(server)
        try await start(transcriber, server)
        try #require(await waitUntil { !audio(server.snapshots[1]).isEmpty })
        transcriber.cancel()
        do { _ = try await transcriber.finish(); Issue.record("cancel must fail finish") }
        catch { #expect(error as? TranscriberError == .cancelled) }
        try #require(await waitUntil { server.snapshots.count == 2 && server.snapshots.allSatisfy(\.closed) })
        #expect(commits(server.snapshots[1]) == 0)
    }

    @Test func quietStopSettlesAndClosesAnUnusedPreparedSpare() async throws {
        let server = try WebSocketTestServer(provider: .scribe, behaviors: [.scribeRepairLive, .happy])
        defer { checkServer(server) }
        let transcriber = make(server)
        defer { transcriber.cancel() }
        transcriber.start { _ in }
        for chunk in Self.firstChunks.prefix(206) { transcriber.send(chunk) }
        let noise = Self.firstChunks[4]
        for _ in 0..<3 { transcriber.send(noise) }
        try #require(await waitUntil { server.snapshots.count == 2 && !audio(server.snapshots[1]).isEmpty })
        #expect(try await transcriber.finish() == "Zorblex runs quaxil.")
        try #require(await waitUntil { server.snapshots.allSatisfy(\.closed) })
        #expect(commits(server.snapshots[0]) == 1, "stop in the pause owes no second live commit")
        #expect(commits(server.snapshots[1]) == 0, "settle closes the unused spare without asking for repair")
    }

    @Test func stalledSpareAtStopRetriesWithAFreshShorterSplice() async throws {
        let server = try WebSocketTestServer(provider: .scribe, behaviors: [.scribeRepairLive, .neverSetup, .happy])
        defer { checkServer(server) }
        // Hold the independent setup timer out of this test: exercise finish's 500 ms stall check.
        let transcriber = make(server, preparationTimeoutMs: 10_000)
        defer { transcriber.cancel() }
        try await start(transcriber, server)
        try await Task.sleep(for: .milliseconds(600))
        try #require(!server.snapshots[1].closed)
        #expect((await transcriber.diagnostics())["repair_preparation_failures"] == nil)
        for chunk in Self.tailChunks { transcriber.send(chunk) }
        _ = try await transcriber.finish()
        try #require(await waitUntil { server.snapshots.count == 3 && server.snapshots.allSatisfy(\.closed) })
        #expect((await transcriber.diagnostics())["repair_setup_retries"] == 1)
        #expect(audio(server.snapshots[1]).isEmpty)
        #expect(commits(server.snapshots[1]) == 0)
        let all = Self.first + Self.tail
        #expect(audio(server.snapshots[2]) == all.subdata(in: 707_200..<all.count))
        #expect(commits(server.snapshots[2]) == 1)
    }
}
#endif
