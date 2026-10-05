#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation
import Testing
@testable import VizierEngine

@Suite struct HistoryBoardTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // Far from this Mac's zone, so grouping by the system zone instead of this one shows up.
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func take(_ id: String, _ date: Date, outcome: TakeOutcome = .pasted, final: String? = nil, raw: String? = nil,
                      atStart: String? = nil, atPaste: String? = nil) -> TakeRecord {
        TakeRecord(id: id, startedAt: date, stoppedAt: nil, destinationAtStart: atStart, destinationAtPaste: atPaste,
                   audioPath: nil, audioBytes: nil, durationMs: nil, modeID: "scribe", transcriberEngine: "e", transcriberModel: "m",
                   fallbackEngine: nil, fallbackModel: nil, cleanerEngine: nil, cleanerModel: nil,
                   rawTranscript: raw, cleanedText: nil, finalText: final, route: nil, transcriptionMs: nil, cleanupMs: nil,
                   replacementMs: nil, pasteMs: nil, outcome: outcome, outcomeReason: nil, pasteMethod: nil,
                   verbatimBaseline: nil, verbatimBaselineModel: nil, verbatimBaselineMs: nil, rerunText: nil)
    }

    private func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test func takesGroupByLocalDayInOrderWithNamedRecentDays() {
        let now = local(28, 10)
        // 00:30 and 23:30 local sit on different UTC days than their local ones; grouping must be local.
        let takes = [take("a", local(28, 0, 30)), take("b", local(27, 23, 30)), take("c", local(27, 1)), take("d", local(25, 9))]
        let days = HistoryBoard.days(takes, calendar: calendar, now: now)
        #expect(days.map(\.label) == ["Today", "Yesterday", "Friday, Sep 25"])
        #expect(days.map { $0.takes.map(\.id) } == [["a"], ["b", "c"], ["d"]])
        #expect(HistoryBoard.days([], calendar: calendar, now: now).isEmpty)
    }

    @Test func filtersPickTheirOutcomes() {
        #expect(HistoryFilter.all.outcomes == nil)
        #expect(HistoryFilter.problems.outcomes == [.rerouted, .held, .failed])
        #expect(HistoryFilter.cancelled.outcomes == [.cancelled])
    }

    @Test func formattingMatchesTheBoard() {
        #expect(HistoryBoard.clock(local(28, 9, 5), calendar: calendar) == "09:05")
        #expect(HistoryBoard.length(20_600) == "0:21")
        #expect(HistoryBoard.length(724_000) == "12:04")
        #expect(HistoryBoard.length(nil) == "—")
        #expect(HistoryBoard.seconds(282) == "0.28 s")
        #expect(HistoryBoard.bytes(900) == "900 B")
        #expect(HistoryBoard.bytes(831_488) == "812 KB")
        #expect(HistoryBoard.bytes(49_251_427) == "47.0 MB")
        #expect(HistoryBoard.bytes(3_543_348_019) == "3.30 GB")
        #expect(HistoryBoard.platformCode("Gemini SMART") == "GS")
        #expect(HistoryBoard.platformCode("Scribe") == "SC")
    }

    @Test func aRowShowsItsBestTextDestinationAndWords() {
        let pasted = take("p", local(28, 9), final: "  Ship it now.  ", raw: "ship it now um", atStart: "Terminal", atPaste: "Slack")
        #expect(pasted.bestText == "  Ship it now.  ")
        #expect(pasted.words == 3)
        #expect(pasted.destination == "Slack")
        let failed = take("f", local(28, 9), outcome: .failed, final: "   ", raw: "only the raw words", atStart: "Terminal", atPaste: "")
        #expect(failed.bestText == "only the raw words")
        #expect(failed.destination == "Terminal")
        let cancelled = take("c", local(28, 9), outcome: .cancelled, raw: "stop")
        #expect(cancelled.words == nil)
        #expect(take("n", local(28, 9), outcome: .failed).bestText == nil)
        #expect(take("n", local(28, 9), outcome: .failed).words == 0)
    }

    @Test func waveformBarsFollowLoudnessAndSilenceIsFlat() throws {
        // Half a second of silence, then half a second of tone at a quarter of full scale.
        var samples = [Float](repeating: 0, count: 8_000)
        // Kept in named steps: Xcode 26's compiler cannot type-check this as one expression.
        let radiansPerSample: Double = 2 * Double.pi * 220 / 16_000
        for i in 0..<8_000 {
            let value: Double = 0.25 * sin(Double(i) * radiansPerSample)
            samples.append(Float(value))
        }
        let bars = samples.withUnsafeBufferPointer { Waveform.bars($0, count: 4) }
        #expect(bars[0] == 0 && bars[1] == 0)
        #expect(bars[2] > 0.99 && bars[3] > 0.99)

        let quiet = [Float](repeating: 0.001, count: 16_000)
        #expect(quiet.withUnsafeBufferPointer { Waveform.bars($0, count: 8) } == Array(repeating: 0, count: 8))
        #expect([Float]().withUnsafeBufferPointer { Waveform.bars($0, count: 3) } == [0, 0, 0])
    }

    #if canImport(AVFoundation)  // Linux has no FLAC decoder (plan D7), so the file-reading waveform is macOS-only
    @Test func waveformReadsATakesFLAC() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vizier-tests-\(UUID().uuidString)")
        let store = TakeStore(root: root)
        let takeFiles = try store.newTake()
        let file = try AVAudioFile(forWriting: takeFiles.recording, settings: TakeStore.recordingSettings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = 32_000
        let buffer = AVAudioPCMBuffer(pcmFormat: HALCapture.outputFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        // Loud first second, silent second second.
        let radiansPerSample: Double = 2 * Double.pi * 440 / 16_000
        for i in 0..<frames {
            let value: Double = i < 16_000 ? 8_000 * sin(Double(i) * radiansPerSample) : 0
            buffer.int16ChannelData![0][i] = Int16(value)
        }
        try file.write(from: buffer)
        file.close()
        let flac = try store.finishAudio(takeFiles)

        let bars = try Waveform.bars(of: flac, count: 64)
        #expect(bars.count == 64)
        #expect(bars[0..<30].allSatisfy { $0 > 0.9 })
        #expect(bars[34..<64].allSatisfy { $0 == 0 })
    }
    #endif
}
