import Foundation
import Testing
@testable import VizierEngine

/// Fixtures are synthetic words in the shapes the AssemblyAI streaming API reference documents.
@Suite struct AssemblyAIRealtimeTests {
    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func urlCarriesModelRawPCMAndKeytermsAsAJSONArray() {
        let long = String(repeating: "z", count: 51)
        let setup = AssemblyAIRealtime.Setup(model: "universal-3-6-pro", vocabulary: ["Zorblex", " R&D ", long, "Zorblex"])
        let items = query(AssemblyAIRealtime.url(setup))
        #expect(items == ["speech_model": "universal-3-6-pro", "sample_rate": "16000", "encoding": "pcm_s16le", "keyterms_prompt": #"["Zorblex","R&D"]"#])
        #expect(query(AssemblyAIRealtime.url(.init(model: "m", vocabulary: [], prompt: "Dictation."))) ["prompt"] == "Dictation.")
    }

    @Test func decodesBeginTurnTerminationAndErrors() throws {
        #expect(try AssemblyAIRealtime.decode(Data(#"{"type":"Begin","id":"x","expires_at":1}"#.utf8)) == .begin)
        let turn = #"{"type":"Turn","turn_order":2,"end_of_turn":true,"transcript":"Zorblex quaxil.","words":[]}"#
        #expect(try AssemblyAIRealtime.decode(Data(turn.utf8)) == .turn(order: 2, text: "Zorblex quaxil.", ended: true))
        #expect(try AssemblyAIRealtime.decode(Data(#"{"type":"Termination","audio_duration_seconds":3}"#.utf8)) == .termination)
        #expect(try AssemblyAIRealtime.decode(Data(#"{"error":"Invalid API key"}"#.utf8)) == .failed("Invalid API key"))
    }

    @Test func audioWaitsForBeginAndTheForcedTurnEndsTheTake() {
        var session = AssemblyAIRealtimeSession()
        #expect(session.audio(Data([1])) == [])
        #expect(session.receive(.begin) == [.sendAudio(Data([1]))])
        _ = session.receive(.turn(order: 0, text: "Zorblex.", ended: true))
        _ = session.receive(.turn(order: 1, text: "the qua", ended: false))
        #expect(session.end() == [.sendForceEndpoint, .sendTerminate])
        // A late repeat of a turn that had ended before the stop is not the forced endpoint.
        #expect(session.receive(.turn(order: 0, text: "Zorblex.", ended: true)) == [.transcript(settled: "Zorblex.", pending: "the qua")])
        #expect(session.receive(.turn(order: 1, text: "The quaxil.", ended: true))
            == [.transcript(settled: "Zorblex. The quaxil.", pending: ""), .done("Zorblex. The quaxil.")])
        #expect(session.receive(.termination) == [])
    }

    @Test func withNoOpenTurnTerminationEndsTheTake() {
        var session = AssemblyAIRealtimeSession()
        _ = session.receive(.begin)
        _ = session.receive(.turn(order: 0, text: "Zorblex.", ended: true))
        _ = session.end()
        #expect(session.receive(.termination) == [.done("Zorblex.")])
        var closed = AssemblyAIRealtimeSession()
        _ = closed.receive(.begin)
        _ = closed.end()
        #expect(closed.liveClosed("closed 1008") == [.failed("closed 1008")])
    }
}
