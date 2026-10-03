import Foundation
import Testing
@testable import VizierEngine

/// Fixtures are synthetic words in the shapes Scribe v2 Realtime sent during live probes.
@Suite struct ScribeRealtimeCodecTests {
    private func json(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func query(_ url: URL) -> [(String, String)] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    }

    @Test func urlCarriesTheModelManualCommitsAndABareLanguageCode() {
        let setup = ScribeRealtime.Setup(model: "scribe_v2_realtime", languages: ["en-US"], vocabulary: ["Zorblex", "Quaxil"], noVerbatim: false)
        let items = query(ScribeRealtime.url(setup))
        #expect(items.map(\.0) == ["model_id", "audio_format", "commit_strategy", "include_timestamps", "language_code", "keyterms", "keyterms"])
        #expect(items.map(\.1) == ["scribe_v2_realtime", "pcm_16000", "manual", "true", "en", "Zorblex", "Quaxil"])
        #expect(ScribeRealtime.url(setup).absoluteString.hasPrefix("wss://api.elevenlabs.io/v1/speech-to-text/realtime?"))
    }

    @Test func noVerbatimAndAnEmptyLanguageListChangeOnlyTheirOwnParameters() {
        let setup = ScribeRealtime.Setup(model: "m", languages: [], vocabulary: [], noVerbatim: true)
        #expect(query(ScribeRealtime.url(setup)).map(\.0) == ["model_id", "audio_format", "commit_strategy", "include_timestamps", "no_verbatim"])
    }

    @Test func keytermsKeepTheFirstFiftyThatFitAndSkipLongOnes() {
        let long = "Zorblexquaxilgantryish" // 22 characters
        let vocabulary = [long] + (1...60).map { "Term\($0)" }
        let terms = ScribeRealtime.keyterms(vocabulary)
        #expect(terms.count == 50)
        #expect(terms.first == "Term1")
        #expect(!terms.contains(long))
    }

    @Test func aPlusOrAmpersandInATermSurvivesTheURL() {
        let setup = ScribeRealtime.Setup(model: "m", languages: ["en"], vocabulary: ["Q++", "R&D"], noVerbatim: false)
        let url = ScribeRealtime.url(setup)
        #expect(url.absoluteString.contains("keyterms=Q%2B%2B&keyterms=R%26D"))
        #expect(query(url).filter { $0.0 == "keyterms" }.map(\.1) == ["Q++", "R&D"])
    }

    @Test func audioAndCommitAreInputChunks() throws {
        let audio = try json(ScribeRealtime.encode(.audio(Data([0x01, 0x00, 0xFF, 0x7F]))))
        #expect(audio == ["message_type": "input_audio_chunk", "audio_base_64": "AQD/fw==", "commit": false, "sample_rate": 16_000])
        let commit = try json(ScribeRealtime.encode(.commit))
        #expect(commit == ["message_type": "input_audio_chunk", "audio_base_64": "", "commit": true, "sample_rate": 16_000])
    }

    @Test func decodesEachServerMessageShape() throws {
        let frames: [(String, ScribeRealtime.ServerEvent)] = [
            (#"{"message_type": "session_started", "session_id": "x", "config": {"sample_rate": 16000}}"#, .sessionStarted),
            (#"{"message_type": "partial_transcript", "text": "Zorblex the"}"#, .partial("Zorblex the")),
            (#"{"message_type": "committed_transcript", "text": "Zorblex the quaxil."}"#, .committed("Zorblex the quaxil.")),
            (#"{"message_type": "committed_transcript", "text": ""}"#, .committed("")),
            (#"{"message_type": "commit_throttled", "error": "Commit request ignored: only 0.00s of uncommitted audio."}"#, .commitIgnored),
            (#"{"message_type": "auth_error", "error": "You must be authenticated to use this endpoint."}"#,
             .failed(type: "auth_error", message: "You must be authenticated to use this endpoint.")),
            (#"{"message_type": "invalid_request", "error": "Invalid language code received: 'en-US'."}"#,
             .failed(type: "invalid_request", message: "Invalid language code received: 'en-US'.")),
            (#"{"message_type": "committed_transcript_with_timestamps", "text": "Zorblex", "words": []}"#, .timed(text: "Zorblex", tokens: [])),
            (#"{"message_type": "committed_transcript_with_timestamps", "text": "Zorblex runs.", "words": [{"text": "Zorblex", "start": 30.06, "end": 30.5, "type": "word", "logprob": -0.1, "characters": ["Z"]}, {"text": " ", "start": 30.5, "end": 30.52, "type": "spacing"}, {"text": "runs.", "start": 30.52, "end": 30.9, "type": "word"}, {"text": "x", "type": "word"}]}"#,
             .timed(text: "Zorblex runs.", tokens: [.init("Zorblex", start: 30.06, end: 30.5), .init(" ", start: 30.5, end: 30.52, isWord: false),
                                                     .init("runs.", start: 30.52, end: 30.9)])),
            (#"{"message_type": "session_warning", "text": "x"}"#, .ignored),
        ]
        for (frame, event) in frames {
            #expect(try ScribeRealtime.decode(Data(frame.utf8)) == event, "\(frame)")
        }
    }

    @Test func aFrameThatIsNotJSONThrows() {
        #expect(throws: (any Error).self) { try ScribeRealtime.decode(Data("not json".utf8)) }
    }
}

@Suite struct ScribeRealtimeSessionTests {
    private let a = Data([1, 1]), b = Data([2, 2]), c = Data([3, 3])
    private static let second = 32_000

    /// Synthetic audio shaped like real takes: room noise, and speech only 8 dB over it with a
    /// 100 ms gap at the noise after every 400 ms of voice.
    private static let noise: Int16 = 1_000, voice: Int16 = 2_500
    private static func frames(_ count: Int, _ level: Int16) -> Data {
        Data((0..<(count * 320)).flatMap { _ in withUnsafeBytes(of: level.littleEndian) { Array($0) } })
    }
    private static func speech(seconds: Double) -> Data {
        var out = Data()
        while out.count < Int(seconds * Double(second)) { out += frames(20, voice) + frames(5, noise) }
        return out.prefix(Int(seconds * Double(second)))
    }
    private static func pause(ms: Int) -> Data { frames(ms / 20, noise) }

    /// Streams `pcm` in 100 ms chunks, returning every output and the audio time of each commit.
    private func stream(_ pcm: Data, into session: inout ScribeRealtimeSession, sentBefore: Int = 0) -> (outputs: [ScribeRealtimeSession.Output], commitsAt: [Double]) {
        var outputs: [ScribeRealtimeSession.Output] = []
        var commitsAt: [Double] = []
        var sent = sentBefore
        for start in stride(from: 0, to: pcm.count, by: 3_200) {
            let chunk = pcm.subdata(in: start..<min(start + 3_200, pcm.count))
            sent += chunk.count
            let out = session.audio(chunk)
            if out.contains(.send(.commit)) { commitsAt.append(Double(sent) / Double(Self.second)) }
            outputs += out
        }
        return (outputs, commitsAt)
    }

    private func started() -> ScribeRealtimeSession {
        var session = ScribeRealtimeSession()
        _ = session.receive(.sessionStarted)
        return session
    }

    private func repairs(_ outputs: [ScribeRealtimeSession.Output]) -> [Data] {
        outputs.compactMap { if case .repair(let audio) = $0 { audio } else { nil } }
    }

    @Test func holdsAudioUntilTheSessionStartsThenSendsItInOrder() {
        var session = ScribeRealtimeSession()
        #expect(session.audio(a) == [])
        #expect(session.audio(b) == [])
        #expect(session.receive(.sessionStarted) == [.send(.audio(a)), .send(.audio(b))])
        #expect(session.audio(c) == [.send(.audio(c))])
    }

    @Test func aStopBeforeTheSessionStartsStillSendsEverythingThenCommits() {
        var session = ScribeRealtimeSession()
        _ = session.audio(a)
        #expect(session.end() == [])
        #expect(session.audio(b) == [])
        #expect(session.receive(.sessionStarted) == [.send(.audio(a)), .send(.commit)])
        #expect(session.receive(.committed("Zorblex.")) == [.transcript(settled: "Zorblex.", pending: ""), .done("Zorblex.")])
    }

    @Test func theStopCommitsAndItsFinalEndsTheTake() {
        var session = started()
        _ = session.audio(a)
        #expect(session.receive(.partial("Zorblex the")) == [.transcript(settled: "", pending: "Zorblex the")])
        #expect(session.end() == [.send(.commit)])
        #expect(session.audio(b) == [])
        #expect(session.receive(.committed(" Zorblex the quaxil. ")) == [
            .transcript(settled: "Zorblex the quaxil.", pending: ""), .done("Zorblex the quaxil."),
        ])
        #expect(session.receive(.committed("late")) == [])
    }

    @Test func aSilentTakeEndsEmpty() {
        var session = started()
        _ = session.end()
        #expect(session.receive(.committed("")) == [.transcript(settled: "", pending: ""), .done("")])
    }

    @Test func anIgnoredStopCommitEndsWithWhatWasAlreadyCommitted() {
        var session = started()
        #expect(stream(Self.speech(seconds: 35), into: &session).commitsAt == [28])
        _ = session.receive(.committed("Zorblex the quaxil."))
        #expect(session.end() == [.send(.commit)])
        #expect(session.receive(.commitIgnored) == [.done("Zorblex the quaxil.")])
    }

    /// The case self-commits exist for: a mid-take segment's final arriving after the stop must
    /// not end the take, or the last segment's words are lost.
    @Test func waitsForEveryCommitsAnswerBeforeEnding() {
        var session = started()
        _ = stream(Self.speech(seconds: 35), into: &session)
        #expect(session.end() == [.send(.commit)])
        #expect(session.receive(.committed("First segment.")) == [.transcript(settled: "First segment.", pending: "")])
        #expect(session.receive(.committed("Last words.")) == [
            .transcript(settled: "First segment. Last words.", pending: ""), .done("First segment. Last words."),
        ])
    }

    @Test func commitsAtAPauseInRoomNoiseOnlyAfterTwentySeconds() {
        var session = started()
        let early = Self.speech(seconds: 10) + Self.pause(ms: 600) + Self.speech(seconds: 10)
        #expect(stream(early, into: &session).commitsAt == [], "a pause before 20 s does not commit")
        let (_, commitsAt) = stream(Self.pause(ms: 400) + Self.speech(seconds: 3), into: &session, sentBefore: early.count)
        #expect(commitsAt.count == 1)
        #expect(commitsAt.first.map { $0 > 20.6 && $0 <= 21.0 } == true, "commits once 300 ms of the pause has passed, not before: \(commitsAt)")
    }

    @Test func gapsBetweenWordsAreNotPausesAndTwentyEightSecondsAlwaysCommits() {
        var session = started()
        let (outputs, commitsAt) = stream(Self.speech(seconds: 60), into: &session)
        #expect(commitsAt == [28, 56])
        #expect(outputs.count { $0 == .send(.commit) } == 2)
    }

    @Test func aStopSoonAfterACommitAsksForARepairOfBothSegments() {
        var session = started()
        let audio = Self.speech(seconds: 30.5)
        _ = stream(audio, into: &session)
        let out = session.end()
        #expect(out.first == .send(.commit))
        #expect(repairs(out) == [audio], "the repair carries the last mid-take segment and the short one after it")
    }

    @Test func aRepairCoversOnlyTheLastTwoSegments() {
        var session = started()
        let audio = Self.speech(seconds: 59)
        _ = stream(audio, into: &session)
        #expect(repairs(session.end()) == [audio.suffix(from: 28 * Self.second)])
    }

    @Test func noRepairWhenTheLastSegmentIsLongEnoughOrThereWasNoCommit() {
        var long = started()
        _ = stream(Self.speech(seconds: 34.5), into: &long)
        #expect(repairs(long.end()) == [])
        var short = started()
        _ = stream(Self.speech(seconds: 3), into: &short)
        #expect(repairs(short.end()) == [])
    }

    @Test func aRepairReplacesTheSegmentsItCoversOnceEverythingHasAnswered() {
        var session = started()
        _ = stream(Self.speech(seconds: 58), into: &session)
        _ = session.receive(.committed("Zorblex runs first."))
        _ = session.end()
        #expect(session.repaired("Then the quaxil ships and the gantry closes.") == [], "waits for the live answers")
        _ = session.receive(.committed("Then the quaxil ships and-"))
        let out = session.receive(.committed(""))
        #expect(out.last == .done("Zorblex runs first. Then the quaxil ships and the gantry closes."))
        #expect(out.contains(.note("repair used: 8 words for 5 live")))
    }

    @Test func liveAnswersWaitForAPendingRepair() {
        var session = started()
        _ = stream(Self.speech(seconds: 30), into: &session)
        _ = session.end()
        _ = session.receive(.committed("Zorblex runs and-"))
        #expect(session.receive(.committed("")).contains { if case .done = $0 { true } else { false } } == false)
        #expect(session.repaired("Zorblex runs and the quaxil ships.").last == .done("Zorblex runs and the quaxil ships."))
    }

    @Test func aFailedRepairKeepsTheLiveText() {
        var session = started()
        _ = stream(Self.speech(seconds: 30), into: &session)
        _ = session.end()
        _ = session.receive(.committed("Zorblex runs."))
        _ = session.receive(.committed("Quaxil"))
        #expect(session.repairFailed("no answer before the repair deadline") == [
            .note("repair failed, keeping the live text: no answer before the repair deadline"), .done("Zorblex runs. Quaxil"),
        ])
        #expect(session.repaired("late") == [])
    }

    @Test func aRepairMuchShorterThanTheLiveTextIsNotUsed() {
        var session = started()
        _ = stream(Self.speech(seconds: 30), into: &session)
        _ = session.end()
        _ = session.receive(.committed("Zorblex runs and the quaxil ships to the gantry today."))
        _ = session.receive(.committed(""))
        let out = session.repaired("Zorblex runs.")
        #expect(out.last == .done("Zorblex runs and the quaxil ships to the gantry today."))
        let empty = { () -> [ScribeRealtimeSession.Output] in
            var s = started()
            _ = stream(Self.speech(seconds: 30), into: &s)
            _ = s.end()
            _ = s.receive(.committed("Zorblex runs."))
            _ = s.receive(.committed(""))
            return s.repaired("")
        }()
        #expect(empty.last == .done("Zorblex runs."))
    }

    @Test func aStopInThePauseAfterAPauseCommitNeedsNoRepair() {
        var session = started()
        let (_, commitsAt) = stream(Self.speech(seconds: 20.6) + Self.pause(ms: 1_000), into: &session)
        #expect(commitsAt.count == 1)
        #expect(session.end() == [.send(.commit)])
        _ = session.receive(.committed("Zorblex runs."))
        #expect(session.receive(.commitIgnored) == [.done("Zorblex runs.")])
    }

    /// A take with a pause commit at 20.30 s, the stop at 20.31 s. A stop commit on
    /// that sliver was throttled, the server hung up before the pause commit's answer, and the take
    /// fell back to batch. The stop now sends nothing and ends on the answer already owed.
    @Test func aStopRightAfterAPauseCommitSendsNoCommitAndEndsOnTheOwedAnswer() {
        var session = started()
        let (_, commitsAt) = stream(Self.speech(seconds: 20.6) + Self.pause(ms: 300), into: &session)
        #expect(commitsAt.count == 1)
        let end = session.end()
        #expect(!end.contains(.send(.commit)))
        #expect(repairs(end).isEmpty, "the sliver after a pause commit is quiet")
        #expect(session.receive(.committed("Zorblex runs.")) == [
            .transcript(settled: "Zorblex runs.", pending: ""), .done("Zorblex runs."),
        ])
    }

    @Test func aStopRightAfterAForcedCommitSendsNoCommitButStillRepairs() {
        var session = started()
        #expect(stream(Self.speech(seconds: 28.2), into: &session).commitsAt == [28])
        let end = session.end()
        #expect(!end.contains(.send(.commit)))
        #expect(repairs(end).count == 1, "a forced commit may have cut a word")
        _ = session.receive(.committed("Zorblex runs and-"))
        #expect(session.repaired("Zorblex runs and the quaxil.").last == .done("Zorblex runs and the quaxil."))
    }

    @Test func aStopWithHalfASecondOrMoreAfterACommitStillCommits() {
        var session = started()
        #expect(stream(Self.speech(seconds: 28.5), into: &session).commitsAt == [28])
        #expect(session.end().contains(.send(.commit)))
    }

    @Test func speechAfterAPauseCommitOrAForcedCommitStillGetsARepair() {
        var afterPause = started()
        let speechAfter = Self.speech(seconds: 20.6) + Self.pause(ms: 400) + Self.speech(seconds: 2)
        #expect(stream(speechAfter, into: &afterPause).commitsAt.count == 1)
        #expect(repairs(afterPause.end()).count == 1)

        var afterForced = started()
        #expect(stream(Self.speech(seconds: 28) + Self.pause(ms: 600), into: &afterForced).commitsAt == [28])
        #expect(repairs(afterForced.end()).count == 1, "a forced commit may have cut a word, so the repair runs even in quiet")
    }

    @Test func theLiveConnectionClosingAfterItsLastAnswerKeepsTheRepair() {
        var session = started()
        _ = stream(Self.speech(seconds: 30), into: &session)
        _ = session.end()
        _ = session.receive(.committed("Zorblex runs and-"))
        #expect(session.receive(.commitIgnored) == [])
        #expect(session.liveClosed("closed 1000: commit_throttled") == [.note("the live connection ended after its last answer: closed 1000: commit_throttled")])
        #expect(session.receive(.failed(type: "transcriber_error", message: "late")) == [.note("the live connection ended after its last answer: transcriber_error: late")])
        #expect(session.repaired("Zorblex runs and the quaxil ships.").last == .done("Zorblex runs and the quaxil ships."))
    }

    @Test func theLiveConnectionClosingWhileAnAnswerIsOwedFailsTheTake() {
        var ending = started()
        _ = stream(Self.speech(seconds: 30), into: &ending)
        _ = ending.end()
        _ = ending.receive(.committed("Zorblex runs and-"))
        #expect(ending.liveClosed("closed 1006") == [.failed("closed 1006")])
        #expect(ending.repaired("Zorblex runs and the quaxil ships.") == [])

        var streaming = started()
        _ = streaming.audio(a)
        #expect(streaming.liveClosed("closed 1006") == [.failed("closed 1006")])
    }

    @Test func repairMessagesAreTheAudioInOrderThenACommit() {
        let audio = Data((0..<7_000).map { UInt8($0 % 251) })
        let messages = ScribeRealtimeSession.repairMessages(audio)
        #expect(messages.count == 4)
        #expect(messages.last == .commit)
        let joined = messages.dropLast().reduce(into: Data()) { all, message in
            if case .audio(let chunk) = message { all += chunk }
        }
        #expect(joined == audio)
    }

    /// A timed copy of `text` with one word per element of `starts`, each lasting 0.4 s; the
    /// words are the text's space-separated pieces, so the pieces join back to it.
    private static func timed(_ text: String, starts: [Double]) -> ScribeRealtime.ServerEvent {
        let words = text.split(separator: " ").map(String.init)
        precondition(words.count == starts.count)
        var tokens: [ScribeRealtime.TimedToken] = []
        for (i, word) in words.enumerated() {
            if i > 0 { tokens.append(.init(" ", start: starts[i - 1] + 0.4, end: starts[i], isWord: false)) }
            tokens.append(.init(word, start: starts[i], end: starts[i] + 0.4))
        }
        return .timed(text: text, tokens: tokens)
    }

    private static let segment = "Zorblex runs first then the quaxil ships and-"
    private static let segmentStarts: [Double] = [1, 5, 10, 20, 21, 22.4, 25, 27.6]

    @Test func withTimingsTheRepairStartsAtTheWordThatLeavesEightSeconds() {
        var session = started()
        let audio = Self.speech(seconds: 30.5)
        _ = stream(audio, into: &session)
        _ = session.receive(.committed(Self.segment))
        _ = session.receive(Self.timed(Self.segment, starts: Self.segmentStarts))
        let out = session.end()
        // The stop is at 30.5 s, so the last word starting by 22.5 s is "quaxil" at 22.4; its
        // audio starts 0.3 s before it, after "the" ended at 21.4.
        #expect(repairs(out) == [audio.suffix(from: 707_200)])
        #expect(out.contains(.note("repair spliced 22100 ms into the previous segment")))
        _ = session.receive(.committed("gan"))
        let done = session.repaired("quaxil ships and the gantry closes.")
        #expect(done.last == .done("Zorblex runs first then the quaxil ships and the gantry closes."))
        #expect(done.contains(.note("repair used: 6 words for 4 live")), "only the spliced tail counts as live text")
    }

    @Test func aSplicedRepairFindsItsWordsOnTheSessionClockAfterEarlierSegments() {
        var session = started()
        let audio = Self.speech(seconds: 59)
        _ = stream(audio, into: &session)
        _ = session.receive(.committed("Zorblex runs first."))
        _ = session.receive(Self.timed("Zorblex runs first.", starts: [1, 10, 20]))
        let second = "then the quaxil ships"
        _ = session.receive(.committed(second))
        _ = session.receive(Self.timed(second, starts: [29, 40, 50.5, 52]))
        // The second segment runs from 28 s; the stop at 59 s leaves "quaxil" at 50.5 s the last
        // word by 51 s, so the audio starts at 50.2 s, 22.2 s into that segment.
        #expect(repairs(session.end()) == [audio.suffix(from: 28 * Self.second + 710_400)])
        _ = session.receive(.committed("and"))
        #expect(session.repaired("quaxil ships and the gantry.").last == .done("Zorblex runs first. then the quaxil ships and the gantry."))

        // Times that start before the segment are on some other clock, so no splice.
        var early = started()
        _ = stream(audio, into: &early)
        _ = early.receive(.committed("Zorblex runs first."))
        _ = early.receive(.committed(second))
        _ = early.receive(Self.timed(second, starts: [20, 40, 50.5, 52]))
        #expect(repairs(early.end()) == [audio.suffix(from: 28 * Self.second)])
    }

    @Test func aSpliceStartsAtASentenceWithinFourteenSecondsOfTheStop() {
        let audio = Self.speech(seconds: 30.5)
        func repair(_ text: String, _ starts: [Double]) -> [Data] {
            var session = started()
            _ = stream(audio, into: &session)
            _ = session.receive(.committed(text))
            _ = session.receive(Self.timed(text, starts: starts))
            return repairs(session.end())
        }
        // "Then" at 18 s starts a sentence 12.5 s before the stop; its audio starts at 17.7 s.
        let text = "Zorblex runs first. Then the quaxil ships and-"
        #expect(repair(text, [1, 5, 10, 18, 21, 22.4, 25, 27.6]) == [audio.suffix(from: 566_400)])
        // At 15 s it is more than 14 s before the stop, so the cut is the latest word again.
        #expect(repair(text, [1, 5, 10, 15, 21, 22.4, 25, 27.6]) == [audio.suffix(from: 707_200)])
        // A comma does not end a sentence.
        #expect(repair("Zorblex runs first, then the quaxil ships and-", [1, 5, 10, 18, 21, 22.4, 25, 27.6]) == [audio.suffix(from: 707_200)])
    }

    @Test func aMidSentenceSpliceKeepsTheLiveCasingOfItsFirstWord() {
        var session = started()
        _ = stream(Self.speech(seconds: 30.5), into: &session)
        _ = session.receive(.committed(Self.segment))
        _ = session.receive(Self.timed(Self.segment, starts: Self.segmentStarts))
        _ = session.end()
        _ = session.receive(.committed("gan"))
        #expect(session.repaired("Quaxil ships and the gantry closes.").last == .done("Zorblex runs first then the quaxil ships and the gantry closes."))
        #expect(ScribeRealtimeSession.matchFirstWordCase("Zorblex runs.", to: "Zorblex runs") == "Zorblex runs.")
        #expect(ScribeRealtimeSession.matchFirstWordCase("Next to it.", to: "the next") == "Next to it.", "a different word keeps its case")
        #expect(ScribeRealtimeSession.matchFirstWordCase("Next, to it.", to: "next to") == "Next, to it.", "punctuation makes it a different word")
    }

    @Test func withoutUsableTimingsTheRepairCarriesTheWholePreviousSegment() {
        let audio = Self.speech(seconds: 30.5)
        func repair(_ events: [ScribeRealtime.ServerEvent]) -> [Data] {
            var session = started()
            _ = stream(audio, into: &session)
            for event in events { _ = session.receive(event) }
            return repairs(session.end())
        }
        let committed = ScribeRealtime.ServerEvent.committed(Self.segment)
        #expect(repair([committed]) == [audio], "no timed copy yet")
        #expect(repair([Self.timed(Self.segment, starts: Self.segmentStarts)]) == [audio], "no plain answer yet")
        let other = "Zorblex runs first then the quaxil ships then"
        #expect(repair([committed, Self.timed(other, starts: Self.segmentStarts)]) == [audio], "a copy of other text")
        let unjoined = ScribeRealtime.ServerEvent.timed(text: Self.segment, tokens: [.init("Zorblex", start: 1, end: 2), .init("runs", start: 10, end: 11)])
        #expect(repair([committed, unjoined]) == [audio], "pieces that do not join back to the text")
        #expect(repair([committed, Self.timed(Self.segment, starts: [1, 23, 23.5, 24, 25, 26, 27, 27.6])]) == [audio], "only the first word is early enough")
        #expect(repair([committed, Self.timed(Self.segment, starts: [1, 5, 10, 20, 21, 22.4, 25, 29])]) == [audio], "a word after the segment ends")
    }

    @Test func theNoiseFloorKeepsOnlyTheNewestFrames() {
        var floor = NoiseFloor(capacity: 3)
        for energy in [1.0, 2, 3, 10, 20] { floor.add(energy) }
        #expect(floor.percentile(0) == 3)
        #expect(floor.percentile(0.9) == 20)
    }

    @Test func anErrorEndsTheTakeWithItsReason() {
        var session = ScribeRealtimeSession()
        #expect(session.receive(.failed(type: "auth_error", message: "You must be authenticated.")) == [.failed("auth_error: You must be authenticated.")])
        #expect(session.receive(.sessionStarted) == [])
        #expect(session.end() == [])
    }

    @Test func ignoredEventsChangeNothing() {
        var session = started()
        #expect(session.receive(.ignored) == [])
        #expect(session.end() == [.send(.commit)])
        #expect(session.receive(.ignored) == [])
    }
}
