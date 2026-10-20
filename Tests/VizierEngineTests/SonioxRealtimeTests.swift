import Foundation
import Testing
@testable import VizierEngine

/// Fixtures are synthetic words in the shapes the Soniox WebSocket API reference documents.
@Suite struct SonioxRealtimeTests {
    private func json(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test func configFrameCarriesRawPCMBareLanguageHintsAndTerms() throws {
        let setup = SonioxRealtime.Setup(model: "stt-rt-v5", languages: ["en-US", "en_GB", "es"], vocabulary: [" Zorblex ", "Quaxil", "Zorblex", ""])
        let frame = try json(SonioxRealtime.configFrame(setup, apiKey: "k"))
        #expect(frame == [
            "api_key": "k", "model": "stt-rt-v5", "audio_format": "pcm_s16le", "sample_rate": 16_000, "num_channels": 1,
            "language_hints": ["en", "es"], "context": ["terms": ["Zorblex", "Quaxil"]],
        ])
        let bare = try json(SonioxRealtime.configFrame(SonioxRealtime.Setup(model: "m", languages: [], vocabulary: []), apiKey: "k"))
        #expect(bare["context"] == nil && bare["language_hints"] == nil)
        let general = SonioxRealtime.Setup(model: "m", languages: [], vocabulary: [], general: [.init(key: "domain", value: "Zorblex")])
        #expect(try json(SonioxRealtime.configFrame(general, apiKey: "k"))["context"] as? NSDictionary == ["general": [["key": "domain", "value": "Zorblex"]]])
    }

    @Test func decodesTokensFinishedAndErrors() throws {
        let tokens = #"{"tokens":[{"text":"Zor","is_final":true},{"text":"blex","is_final":false}],"final_audio_proc_ms":760}"#
        #expect(try SonioxRealtime.decode(Data(tokens.utf8)) == .tokens([.init("Zor", isFinal: true), .init("blex", isFinal: false)]))
        #expect(try SonioxRealtime.decode(Data(#"{"tokens":[],"finished":true}"#.utf8)) == .finished)
        let error = #"{"tokens":[],"error_code":401,"error_type":"unauthenticated","error_message":"Incorrect API key provided."}"#
        #expect(try SonioxRealtime.decode(Data(error.utf8)) == .failed(type: "unauthenticated", message: "Incorrect API key provided."))
    }

    @Test func aTakeEndsAtTheFinMarkerAfterSilenceAndAFinalize() {
        var session = SonioxRealtimeSession()
        #expect(session.audio(Data([1, 2])) == [.sendAudio(Data([1, 2]))])
        #expect(session.receive(.tokens([.init("Zorblex", isFinal: true), .init(" the", isFinal: false)]))
            == [.transcript(settled: "Zorblex", pending: "the")])
        // A <fin> before the stop is not the take's end.
        #expect(session.receive(.tokens([.init("<fin>", isFinal: true)])) == [.transcript(settled: "Zorblex", pending: "")])
        #expect(session.end() == [.sendAudio(Data(count: 6_400)), .sendFinalize])
        #expect(session.audio(Data([3])) == [])
        #expect(session.receive(.tokens([.init(" the quaxil.", isFinal: true), .init("<fin>", isFinal: true)]))
            == [.transcript(settled: "Zorblex the quaxil.", pending: ""), .done("Zorblex the quaxil.")])
        #expect(session.receive(.tokens([.init(" more", isFinal: true)])) == [])
    }

    @Test func aCloseOrErrorBeforeTheFinalFailsTheTake() {
        var closed = SonioxRealtimeSession()
        _ = closed.end()
        #expect(closed.liveClosed("closed 1006") == [.failed("closed 1006")])
        #expect(closed.liveClosed("again") == [])
        var errored = SonioxRealtimeSession()
        #expect(errored.receive(.failed(type: "unauthenticated", message: "bad key")) == [.failed("unauthenticated: bad key")])
    }
}
