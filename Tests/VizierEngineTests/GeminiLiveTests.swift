import Foundation
import Testing
@testable import VizierEngine

/// Fixtures are synthetic words in the shapes the Live API sent during a live probe.
@Suite struct GeminiLiveCodecTests {
    private func json(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func json(_ text: String) throws -> NSDictionary {
        try json(Data(text.utf8))
    }

    @Test func setupTurnsOffActivityDetectionAndCarriesVocabulary() throws {
        let setup = GeminiLive.Setup(model: "gemini-3.5-transcribe-live", mode: "SMART", languages: ["en-US"], vocabulary: ["Zorblex", "Quaxil"])
        let expected = try json("""
        {"setup": {
          "model": "models/gemini-3.5-transcribe-live",
          "generationConfig": {"responseModalities": ["TEXT"]},
          "realtimeInputConfig": {"automaticActivityDetection": {"disabled": true}},
          "inputAudioTranscription": {"mode": "SMART", "customVocabulary": ["Zorblex", "Quaxil"], "languageCodes": ["en-US"]}
        }}
        """)
        #expect(try json(GeminiLive.encode(.setup(setup))) == expected)
    }

    @Test func setupLeavesOutEmptyListsAndKeepsAnExistingPrefix() throws {
        let setup = GeminiLive.Setup(model: "models/m", mode: "SMART", languages: [], vocabulary: [])
        let wire = try json(GeminiLive.encode(.setup(setup)))
        let body = try #require(wire["setup"] as? NSDictionary)
        #expect(body["model"] as? String == "models/m")
        #expect(body.value(forKey: "inputAudioTranscription") as? NSDictionary == ["mode": "SMART"])
    }

    @Test func audioIsBase64PCMAtSixteenKilohertz() throws {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
        let expected = try json(#"{"realtimeInput": {"audio": {"data": "AQD/fw==", "mimeType": "audio/pcm;rate=16000"}}}"#)
        #expect(try json(GeminiLive.encode(.audio(pcm))) == expected)
        #expect(String(decoding: try GeminiLive.encode(.audio(pcm)), as: UTF8.self).contains("audio/pcm"))
    }

    @Test func activityMarkersAreEmptyObjects() throws {
        #expect(try json(GeminiLive.encode(.activityStart)) == json(#"{"realtimeInput": {"activityStart": {}}}"#))
        #expect(try json(GeminiLive.encode(.activityEnd)) == json(#"{"realtimeInput": {"activityEnd": {}}}"#))
    }

    @Test func decodesEachServerFrameShape() throws {
        let frames: [(String, [GeminiLive.ServerEvent])] = [
            (#"{"setupComplete": {}}"#, [.setupComplete]),
            (#"{"serverContent": {"interimInputTranscription": {"text": "zorblex the"}}}"#, [.interim("zorblex the")]),
            (#"{"serverContent": {"inputTranscription": {"text": "Zorblex the quaxil."}}}"#, [.final("Zorblex the quaxil.")]),
            (#"{"serverContent": {"generationComplete": true}}"#, [.generationComplete]),
            (#"{"serverContent": {}, "voiceActivity": {"type": "ACTIVITY_END", "audioOffset": "4.1s"}}"#, [.activityEnded]),
            (#"{"serverContent": {}, "voiceActivity": {"type": "ACTIVITY_START", "audioOffset": "0s"}}"#, []),
            (#"{"goAway": {"timeLeft": "10s"}}"#, [.goAway(timeLeft: "10s")]),
            (#"{"serverContent": {"inputTranscription": {"text": "Done."}, "generationComplete": true}}"#, [.final("Done."), .generationComplete]),
        ]
        for (frame, events) in frames {
            #expect(try GeminiLive.decode(Data(frame.utf8)) == events, "\(frame)")
        }
    }

    @Test func aFrameThatIsNotJSONThrows() {
        #expect(throws: (any Error).self) { try GeminiLive.decode(Data("not json".utf8)) }
    }
}

@Suite struct GeminiLiveSessionTests {
    private let setup = GeminiLive.Setup(model: "m", mode: "SMART", languages: ["en-US"], vocabulary: [])
    private let a = Data([1, 1]), b = Data([2, 2]), c = Data([3, 3])

    @Test func holdsAudioUntilSetupThenStartsTheActivityFirst() {
        var session = GeminiLiveSession(setup: setup)
        #expect(session.begin() == [.send(.setup(setup))])
        #expect(session.audio(a) == [])
        #expect(session.audio(b) == [])
        #expect(session.receive(.setupComplete) == [.send(.activityStart), .send(.audio(a)), .send(.audio(b))])
        #expect(session.audio(c) == [.send(.audio(c))])
    }

    @Test func aStopBeforeSetupStillSendsEveryHeldChunkBeforeTheEnd() {
        var session = GeminiLiveSession(setup: setup)
        _ = session.begin()
        _ = session.audio(a)
        _ = session.audio(b)
        #expect(session.end() == [])
        #expect(session.audio(c) == [])
        #expect(session.receive(.setupComplete) == [.send(.activityStart), .send(.audio(a)), .send(.audio(b)), .send(.activityEnd)])
        #expect(session.receive(.final("Zorblex.")) == [.transcript(settled: "Zorblex.", pending: "")])
        #expect(session.receive(.generationComplete) == [.done("Zorblex.")])
    }

    @Test func endsOnlyOnGenerationCompleteAfterTheActivityEnds() {
        var session = GeminiLiveSession(setup: setup)
        _ = session.begin()
        _ = session.receive(.setupComplete)
        #expect(session.receive(.generationComplete) == [])
        #expect(session.end() == [.send(.activityEnd)])
        #expect(session.end() == [])
        #expect(session.audio(a) == [])
        #expect(session.receive(.final("Quaxil zorblex.")) == [.transcript(settled: "Quaxil zorblex.", pending: "")])
        #expect(session.receive(.generationComplete) == [.done("Quaxil zorblex.")])
        #expect(session.receive(.generationComplete) == [])
        #expect(session.receive(.interim("late")) == [])
    }

    @Test func interimsShowSettledFinalsThenTheWordsInFlux() {
        var session = GeminiLiveSession(setup: setup)
        _ = session.begin()
        _ = session.receive(.setupComplete)
        #expect(session.receive(.interim("zorblex")) == [.transcript(settled: "", pending: "zorblex")])
        #expect(session.receive(.final("Zorblex.")) == [.transcript(settled: "Zorblex.", pending: "")])
        #expect(session.receive(.interim(" quaxil ")) == [.transcript(settled: "Zorblex.", pending: "quaxil")])
        #expect(session.receive(.final("Quaxil.")) == [.transcript(settled: "Zorblex. Quaxil.", pending: "")])
        _ = session.end()
        #expect(session.receive(.generationComplete) == [.done("Zorblex. Quaxil.")])
    }

    @Test func aTakeWithNothingHeardEndsEmpty() {
        var session = GeminiLiveSession(setup: setup)
        _ = session.begin()
        _ = session.receive(.setupComplete)
        _ = session.end()
        #expect(session.receive(.generationComplete) == [.done("")])
    }

    /// The live server sends a silent activity no final and no generationComplete, only the
    /// activity-end echo (seen on a live connection); without this the take waits out the final timeout.
    @Test func theActivityEndEchoEndsASilentTakeAtOnce() {
        var session = GeminiLiveSession(setup: setup)
        _ = session.begin()
        _ = session.receive(.setupComplete)
        #expect(session.receive(.activityEnded) == [])
        _ = session.end()
        #expect(session.receive(.activityEnded) == [.done("")])
        #expect(session.receive(.generationComplete) == [])
    }

    @Test func onceTextHasComeTheEchoDoesNotCutTheTakeShort() {
        var session = GeminiLiveSession(setup: setup)
        _ = session.begin()
        _ = session.receive(.setupComplete)
        _ = session.receive(.interim("zorblex"))
        _ = session.end()
        #expect(session.receive(.activityEnded) == [])
        _ = session.receive(.final("Zorblex."))
        #expect(session.receive(.generationComplete) == [.done("Zorblex.")])
    }

    @Test func aFinalWithNoInterimsAlsoCountsAsText() {
        var session = GeminiLiveSession(setup: setup)
        _ = session.begin()
        _ = session.receive(.setupComplete)
        _ = session.end()
        _ = session.receive(.final("Quaxil."))
        #expect(session.receive(.activityEnded) == [])
        #expect(session.receive(.generationComplete) == [.done("Quaxil.")])
    }

    @Test func whitespaceInterimsDoNotCountAsText() {
        var session = GeminiLiveSession(setup: setup)
        _ = session.begin()
        _ = session.receive(.setupComplete)
        _ = session.receive(.interim("  "))
        _ = session.end()
        #expect(session.receive(.activityEnded) == [.done("")])
    }

    @Test func eventsBeforeSetupAreIgnored() {
        var session = GeminiLiveSession(setup: setup)
        _ = session.begin()
        #expect(session.receive(.interim("x")) == [])
        #expect(session.receive(.final("x")) == [])
        #expect(session.begin() == [])
    }
}
