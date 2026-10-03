import Foundation

/// The protocol logic of one Scribe Realtime take, apart from the socket, so it can be tested
/// without a network. Feed it what happens; send what it returns, in order.
///
/// Audio that arrives before `session_started` is held and sent right after it. Vizier commits
/// segments itself, at a pause once 20 s of audio is uncommitted and unconditionally at 28 s, so
/// the server's own commit at about 36 s never fires. Every commit gets exactly one answer, a
/// `committed_transcript` or a `commit_throttled`, so the take is done when the stop's commit and
/// every commit before it have been answered. Waiting for "the next final" instead could end a
/// long take on an earlier segment's final and lose its last words.
///
/// Scribe needs a few seconds of audio around a word to hear it: a segment of under about 4 s
/// comes back wrong or empty (measured on live takes). A take that stops less than 6 s
/// after a commit therefore ends in a segment too short to trust, so the session also asks for a
/// repair: audio from before that commit through the stop, sent at once to a fresh session. Its
/// text replaces the words that audio covers unless it fails, times out, or comes back much
/// shorter than the live text. A commit at a pause cuts no word, so a stop with only quiet after
/// one needs no repair.
///
/// A repair's answer takes longer the more audio it carries: 0.35 s for 6 s, 1 s for 20 s, 1.4 s
/// for 40 s (measured with synthetic speech). So when the previous segment's word timings
/// have arrived and match its text, the repair starts at the word boundary that leaves about
/// 8 s of audio and keeps the words before it. Without usable timings it carries the whole
/// previous segment, as it always did.
///
/// The server may close the live connection once it has answered everything (it did after a
/// `commit_throttled`); that is only a failure while an answer is still owed. It also closes right
/// after a throttled commit even while an earlier commit's answer is owed, losing that answer
/// (seen with a pause commit at 20.30 s and the stop at 20.31 s). So a stop that finds under half a
/// second since a mid-take commit sends no commit of its own; the take ends on the answers
/// already owed. That sliver is quiet after a pause commit, and any speech in it, or anything a
/// forced commit cut, is covered by the repair, which still runs.
public struct ScribeRealtimeSession: Sendable {
    public enum Output: Equatable, Sendable {
        case send(ScribeRealtime.ClientMessage)
        /// Open a fresh session, send `ScribeRealtimeSession.repairMessages(audio)`, and report
        /// its committed transcript with `repaired(_:)` or its failure with `repairFailed(_:)`.
        case repair(Data)
        /// Everything heard so far, for the strip: finished segments, then the current one.
        case transcript(settled: String, pending: String)
        /// Something worth a line in the log.
        case note(String)
        /// The take's text. Nothing follows it.
        case done(String)
        /// The server reported an error. Nothing follows it.
        case failed(String)
    }

    /// 16 kHz 16-bit mono PCM: 32,000 bytes a second.
    static let bytesPerSecond = 32_000
    /// Past this much uncommitted audio, a pause ends the segment.
    public static let commitAtPauseAfterBytes = 20 * bytesPerSecond
    /// Past this much, the segment ends whatever the audio holds. With `repairBelowBytes`, this
    /// keeps a repair under the server's own commit at about 36 s.
    public static let commitAlwaysAfterBytes = 28 * bytesPerSecond
    /// A stop with less than this after a mid-take commit sends no commit: the server throttles a
    /// commit under 0.3 s and then closes, and the margin keeps well clear of that.
    public static let stopCommitMinimumBytes = bytesPerSecond / 2
    /// A take that stops with less than this after its last commit gets a repair.
    public static let repairBelowBytes = 6 * bytesPerSecond
    /// A repair is used unless it has fewer words than this share of the live text it replaces.
    static let repairMinimumWordShare = 0.7
    /// A spliced repair carries at least this much audio, from a word boundary in the previous
    /// segment through the stop: enough context for Scribe, which misheard segments under 4 s.
    public static let repairTailBytes = 8 * bytesPerSecond
    /// A splice starts at a sentence when one starts in the stretch that leaves between
    /// `repairTailBytes` and this much audio. Scribe capitalizes the first word it hears, so a cut
    /// mid-sentence read "room at Pier 9, Next to" (seen on a live run with synthetic speech).
    public static let sentenceTailBytes = 14 * bytesPerSecond
    /// A spliced repair's audio starts this far before its first word, or at the end of the
    /// word before it if that is later, so the word's onset is not clipped.
    static let spliceLeadSeconds = 0.3

    /// Pauses are judged in 20 ms frames against the room's own noise: the 10th percentile of the
    /// last minute's frame energies. Speech in a real take sat only 7 to 10 dB over that noise,
    /// so a threshold relative to the take's average never saw a pause.
    static let frameBytes = 640
    static let noiseWindowFrames = 3_000
    static let noisePercentile = 0.1
    /// A frame is quiet within 6 dB of the noise floor; 300 ms of quiet frames is a pause.
    static let quietOverNoise = 4.0
    static let pauseFrames = 15

    private enum Phase { case awaitingSession, streaming, ending, done }
    private enum Repair: Equatable { case none, pending, answered(String), failed }

    private var phase = Phase.awaitingSession
    private var held: [Data] = []
    private var endRequested = false
    /// One entry per answered commit, in order; an ignored commit answers "".
    private var answers: [String] = []
    private var commitsSent = 0
    private var midTakeCommits = 0
    private var previousSegment = Data()
    private var currentSegment = Data()
    /// Audio streamed before the previous segment began, in bytes: where it sits on the session's
    /// clock, which is the clock of the word timings.
    private var previousSegmentStart = 0
    private var streamed = 0
    /// Timed copies of the newest committed segments, oldest first.
    private var timedSegments: [[ScribeRealtime.TimedToken]] = []
    private var repair = Repair.none
    /// For a spliced repair, the previous segment's text before the splice, which stays, and
    /// after it, which the repair replaces. Nil when the repair carries the whole segment.
    private var splice: (kept: String, replaced: String)?
    private var frameCarry = Data()
    private var noise = NoiseFloor(capacity: noiseWindowFrames)
    private var quietRun = 0
    private var lastCommitAtPause = false
    /// Frame energies since the last commit, to tell whether the stop came in the pause.
    private var segmentEnergies: [Double] = []

    public init() {}

    public mutating func audio(_ pcm: Data) -> [Output] {
        switch phase {
        case .awaitingSession where !endRequested:
            held.append(pcm)
            return []
        case .streaming:
            return stream(pcm)
        default:
            return []
        }
    }

    public mutating func end() -> [Output] {
        switch phase {
        case .awaitingSession:
            endRequested = true
            return []
        case .streaming:
            return finalCommit()
        default:
            return []
        }
    }

    public mutating func receive(_ event: ScribeRealtime.ServerEvent) -> [Output] {
        guard phase != .done else { return [] }
        switch (phase, event) {
        case (_, .failed(let type, let message)):
            return liveEnded("\(type): \(message)")
        case (.awaitingSession, .sessionStarted):
            phase = .streaming
            var out: [Output] = []
            for pcm in held { out += stream(pcm) }
            held = []
            if endRequested { out += finalCommit() }
            return out
        case (.streaming, .partial(let text)), (.ending, .partial(let text)):
            return [.transcript(settled: Self.join(answers), pending: Self.join([text]))]
        case (.streaming, .committed(let text)), (.ending, .committed(let text)):
            answers.append(text)
            return [.transcript(settled: Self.join(answers), pending: "")] + finishIfReady()
        case (.streaming, .timed(_, let tokens)), (.ending, .timed(_, let tokens)):
            timedSegments.append(tokens)
            if timedSegments.count > 2 { timedSegments.removeFirst() }
            return []
        case (.streaming, .commitIgnored), (.ending, .commitIgnored):
            answers.append("")
            return finishIfReady()
        default:
            return []
        }
    }

    /// The live connection closed or failed.
    public mutating func liveClosed(_ reason: String) -> [Output] {
        guard phase != .done else { return [] }
        return liveEnded(reason)
    }

    private mutating func liveEnded(_ reason: String) -> [Output] {
        if phase == .ending, answers.count >= commitsSent {
            return [.note("the live connection ended after its last answer: \(reason)")]
        }
        phase = .done
        return [.failed(reason)]
    }

    public mutating func repaired(_ text: String) -> [Output] {
        guard phase != .done, repair == .pending else { return [] }
        repair = .answered(text)
        return finishIfReady()
    }

    public mutating func repairFailed(_ reason: String) -> [Output] {
        guard phase != .done, repair == .pending else { return [] }
        repair = .failed
        return [.note("repair failed, keeping the live text: \(reason)")] + finishIfReady()
    }

    /// A repair's messages: the audio in 100 ms chunks, then a commit.
    public static func repairMessages(_ audio: Data) -> [ScribeRealtime.ClientMessage] {
        let chunk = bytesPerSecond / 10
        return stride(from: 0, to: audio.count, by: chunk).map { start in
            .audio(audio.subdata(in: start..<min(start + chunk, audio.count)))
        } + [.commit]
    }

    private mutating func stream(_ pcm: Data) -> [Output] {
        currentSegment.append(pcm)
        streamed += pcm.count
        listen(pcm)
        var out: [Output] = [.send(.audio(pcm))]
        let uncommitted = currentSegment.count
        let atPause = uncommitted >= Self.commitAtPauseAfterBytes && quietRun >= Self.pauseFrames
        if uncommitted >= Self.commitAlwaysAfterBytes || atPause {
            out.append(.send(.commit))
            commitsSent += 1
            midTakeCommits += 1
            lastCommitAtPause = atPause
            previousSegmentStart = streamed - currentSegment.count
            previousSegment = currentSegment
            currentSegment = Data()
            segmentEnergies = []
            quietRun = 0
        }
        return out
    }

    /// Tracks the noise floor and the current run of quiet frames. The run is counted only once
    /// a pause could end the segment, so the floor is sorted at most once per chunk, and only then.
    private mutating func listen(_ pcm: Data) {
        var bytes = frameCarry + pcm
        var energies: [Double] = []
        while bytes.count >= Self.frameBytes {
            energies.append(Self.meanSquare(bytes.prefix(Self.frameBytes)))
            bytes = Data(bytes.dropFirst(Self.frameBytes))
        }
        frameCarry = bytes
        for energy in energies { noise.add(energy) }
        segmentEnergies += energies
        guard currentSegment.count >= Self.commitAtPauseAfterBytes else {
            quietRun = 0
            return
        }
        let quiet = noise.percentile(Self.noisePercentile) * Self.quietOverNoise
        for energy in energies { quietRun = energy <= quiet ? quietRun + 1 : 0 }
    }

    private mutating func finalCommit() -> [Output] {
        phase = .ending
        var out: [Output]
        if midTakeCommits > 0, currentSegment.count < Self.stopCommitMinimumBytes {
            out = [.note("the stop came \(currentSegment.count * 1000 / Self.bytesPerSecond) ms after a commit; not committing again")]
        } else {
            commitsSent += 1
            out = [.send(.commit)]
        }
        if midTakeCommits > 0, currentSegment.count < Self.repairBelowBytes, !(lastCommitAtPause && !speechSinceCommit) {
            repair = .pending
            let audio = previousSegment + currentSegment
            if let cut = spliceCut() {
                splice = (cut.kept, cut.replaced)
                out.append(.note("repair spliced \(cut.offset * 1000 / Self.bytesPerSecond) ms into the previous segment"))
                out.append(.repair(audio.subdata(in: cut.offset..<audio.count)))
            } else {
                out.append(.repair(audio))
            }
        }
        return out + finishIfReady()
    }

    /// Where a spliced repair starts: a byte offset into the previous segment at a word boundary,
    /// with the segment's text split there. Nil, for a repair of the whole segment, unless its
    /// answer has arrived with a timed copy whose pieces join back to exactly that text, every
    /// word sits inside the segment on the session's clock, and a word other than the first
    /// starts early enough to leave `repairTailBytes` of audio from it on. The cut is at the
    /// latest such word that starts a sentence within `sentenceTailBytes` of the stop, or else
    /// at the latest such word.
    private func spliceCut() -> (offset: Int, kept: String, replaced: String)? {
        let index = midTakeCommits - 1
        guard answers.count > index else { return nil }
        let answer = Self.join([answers[index]])
        guard !answer.isEmpty,
              let tokens = timedSegments.last(where: { Self.join([$0.map(\.text).joined()]) == answer })
        else { return nil }
        let bps = Double(Self.bytesPerSecond)
        let segmentStart = Double(previousSegmentStart) / bps
        let segmentEnd = Double(previousSegmentStart + previousSegment.count) / bps
        let latestStart = Double(streamed - Self.repairTailBytes) / bps
        let sentenceFrom = Double(streamed - Self.sentenceTailBytes) / bps
        let words = tokens.indices.filter { tokens[$0].isWord }
        guard words.allSatisfy({ tokens[$0].start >= segmentStart - 0.05 && tokens[$0].start <= segmentEnd + 0.05 }) else { return nil }
        let early = zip(words.dropLast(), words.dropFirst()).filter { tokens[$0.1].start <= latestStart }
        let sentence = early.last { tokens[$0.1].start >= sentenceFrom && Self.endsSentence(tokens[$0.0].text) }
        guard let (before, at) = sentence ?? early.last else { return nil }
        let startSeconds = max(tokens[at].start - Self.spliceLeadSeconds, tokens[before].end, segmentStart)
        let offset = Int(((startSeconds - segmentStart) * bps).rounded()) / 2 * 2
        guard offset > 0, offset < previousSegment.count else { return nil }
        return (offset, Self.join([tokens[..<at].map(\.text).joined()]), Self.join([tokens[at...].map(\.text).joined()]))
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’ ")).last else { return false }
        return ".?!".contains(last)
    }

    /// The repair's text with its first word cased as the live text had that same word: a
    /// mid-sentence splice otherwise capitalizes it. A different first word is left alone.
    static func matchFirstWordCase(_ repair: String, to live: String) -> String {
        guard let repairWord = repair.split(separator: " ").first, let liveWord = live.split(separator: " ").first,
              repairWord != liveWord, repairWord.lowercased() == liveWord.lowercased() else { return repair }
        return String(liveWord) + repair.dropFirst(repairWord.count)
    }

    /// At least 100 ms of frames above the quiet threshold since the last commit.
    private var speechSinceCommit: Bool {
        let quiet = noise.percentile(Self.noisePercentile) * Self.quietOverNoise
        return segmentEnergies.count { $0 > quiet } >= 5
    }

    private mutating func finishIfReady() -> [Output] {
        guard phase == .ending, answers.count >= commitsSent, repair != .pending else { return [] }
        phase = .done
        let live = Self.join(answers)
        guard case .answered(let text) = repair else { return [.done(live)] }
        // The repair covers the last mid-take commit's segment, or its words after the splice,
        // and the stop's.
        let replaced = midTakeCommits - 1
        let covered = [splice?.replaced ?? answers[replaced]] + answers[(replaced + 1)...]
        let liveWords = TextCleanup.wordCount(Self.join(covered))
        let repairWords = TextCleanup.wordCount(text)
        guard repairWords > 0, Double(repairWords) >= Double(liveWords) * Self.repairMinimumWordShare else {
            return [.note("repair had \(repairWords) words for \(liveWords) live; keeping the live text"), .done(live)]
        }
        return [.note("repair used: \(repairWords) words for \(liveWords) live"),
                .done(Self.join(Array(answers[..<replaced]) + [splice?.kept ?? "", splice.map { Self.matchFirstWordCase(text, to: $0.replaced) } ?? text]))]
    }

    /// The mean of the squared samples, little-endian 16-bit.
    static func meanSquare(_ pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                sum += sample * sample
            }
        }
        return sum / Double(count)
    }

    private static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// The last `capacity` frame energies, for a noise-floor percentile.
struct NoiseFloor: Sendable {
    private var ring: [Double] = []
    private var next = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    mutating func add(_ energy: Double) {
        if ring.count < capacity {
            ring.append(energy)
        } else {
            ring[next] = energy
            next = (next + 1) % capacity
        }
    }

    func percentile(_ share: Double) -> Double {
        guard !ring.isEmpty else { return 0 }
        let sorted = ring.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
    }
}
