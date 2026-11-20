import Foundation
import Testing
@testable import VizierEngine

@Suite struct ProviderDiagnosticTests {
    private static let sentinel = "ZorblexQuaxil"

    private func failure(keeping codes: [String], _ perform: () async throws -> Void) async {
        do {
            try await perform()
            Issue.record("provider failure was treated as success")
        } catch {
            let diagnostic = String(describing: error)
            #expect(!diagnostic.contains(Self.sentinel))
            for code in codes { #expect(diagnostic.contains(code)) }
        }
    }

    @Test(arguments: ["known", "unknown", "plain"])
    func batchHTTPFailuresKeepCodesWithoutProviderText(_ shape: String) async throws {
        let audio = try Fixture.flac(seconds: 1)
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let providerText = Self.sentinel
        let scribeName = shape == "known" ? "invalid_api_key" : providerText
        let geminiName = shape == "known" ? "UNAUTHENTICATED" : providerText
        let scribe = StubServer { _ in
            let body = shape == "plain" ? providerText : #"{"detail":{"status":"\#(scribeName)","message":"\#(providerText)"}}"#
            return (401, [:], Data(body.utf8))
        }
        let gemini = StubServer { _ in
            let body = shape == "plain" ? providerText : #"{"error":{"status":"\#(geminiName)","message":"\#(providerText)"}}"#
            return (401, [:], Data(body.utf8))
        }
        let scribeBatch = ScribeBatchTranscriber(
            config: .init(model: "scribe_v2", languages: [], vocabulary: []),
            apiKey: "synthetic-key", perform: { await scribe.answer($0) })
        await failure(keeping: shape == "known" ? ["401", "invalid_api_key"] : ["401"]) {
            _ = try await scribeBatch.transcribeReporting(audio)
        }
        for cap in [Int.max, 1] {
            await failure(keeping: shape == "known" ? ["401", "UNAUTHENTICATED"] : ["401"]) {
                _ = try await Fixture.transcriber(gemini, maxInlineBytes: cap).transcribeReporting(audio)
            }
        }
        let routes = await gemini.requests.map(\.url)
        #expect(routes == [GeminiBatch.endpoint, GeminiFiles.uploadEndpoint])
    }

    @Test func localHTTPFailuresKeepOnlyTheStatus() async throws {
        let audio = try Fixture.flac(seconds: 1)
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let server = StubServer { _ in (503, [:], Data(Self.sentinel.utf8)) }
        await failure(keeping: ["503"]) {
            _ = try await LocalWhisperTranscriber(url: LocalWhisper.defaultURL, perform: { await server.answer($0) })
                .transcribeReporting(audio)
        }
        await failure(keeping: ["503"]) {
            _ = try await LocalCleaner(url: LocalCleanup.defaultURL, model: "q", perform: { await server.answer($0) })
                .clean("synthetic speech")
        }
    }

    @Test(arguments: [false, true])
    func unsuccessfulHTTP200ResponsesKeepOnlyKnownStatusesAndFinishReasons(_ known: Bool) async {
        let status = known ? "failed" : Self.sentinel
        let gemini = known ? "MAX_TOKENS" : Self.sentinel
        let local = known ? "length" : Self.sentinel
        await failure(keeping: known ? [status] : []) {
            _ = try GeminiBatch.transcript(from: Fixture.answer(status, ""))
        }
        await failure(keeping: known ? [gemini] : []) {
            _ = try GeminiCleanup.text(from: Data(#"{"candidates":[{"finishReason":"\#(gemini)"}]}"#.utf8))
        }
        let block = known ? "SAFETY" : Self.sentinel
        await failure(keeping: known ? [block] : []) {
            _ = try GeminiCleanup.text(from: Data(#"{"promptFeedback":{"blockReason":"\#(block)"}}"#.utf8))
        }
        await failure(keeping: known ? [local] : []) {
            _ = try LocalCleanup.text(from: Data(#"{"choices":[{"message":{"role":"assistant","content":"synthetic speech"},"finish_reason":"\#(local)"}]}"#.utf8))
        }
    }

    @Test func liveSpeechErrorFramesDoNotEchoProviderText() throws {
        let text = Self.sentinel
        func bytes(_ json: String) -> Data { Data(json.utf8) }

        var scribe = ScribeRealtimeSession()
        let auth = try ScribeRealtime.decode(bytes(#"{"message_type":"auth_error","error":"\#(text)"}"#))
        let scribeDiagnostic = String(describing: scribe.receive(auth))
        #expect(scribeDiagnostic.contains("auth_error"))
        #expect(!scribeDiagnostic.contains(text))
        var unknownScribe = ScribeRealtimeSession()
        let unknown = try ScribeRealtime.decode(bytes(#"{"message_type":"\#(text)","error":"\#(text)"}"#))
        #expect(!String(describing: unknownScribe.receive(unknown)).contains(text))

        var soniox = SonioxRealtimeSession()
        let rejected = try SonioxRealtime.decode(bytes(#"{"error_code":429,"error_type":"\#(text)","error_message":"\#(text)"}"#))
        let sonioxDiagnostic = String(describing: soniox.receive(rejected))
        #expect(sonioxDiagnostic.contains("429"))
        #expect(!sonioxDiagnostic.contains(text))

        var assembly = AssemblyAIRealtimeSession()
        let badRequest = try AssemblyAIRealtime.decode(bytes(#"{"type":"Error","error":"\#(text)"}"#))
        let outputs = assembly.receive(badRequest)
        #expect(outputs.contains { if case .failed = $0 { true } else { false } })
        #expect(!String(describing: outputs).contains(text))
    }
}
