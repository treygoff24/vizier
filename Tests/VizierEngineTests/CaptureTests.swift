#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import VizierEngine

/// Everything a capture delivered, in the order it arrived.
private final class Log: @unchecked Sendable {
    enum Entry: Equatable {
        case samples([Int16])
        case event(CaptureEvent)
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func sink(_ buffer: UnsafeBufferPointer<Int16>) { lock.withLock { entries.append(.samples(Array(buffer))) } }
    func event(_ event: CaptureEvent) { lock.withLock { entries.append(.event(event)) } }
    var all: [Entry] { lock.withLock { entries } }
    var samples: [Int16] {
        var out: [Int16] = []
        for entry in all { if case .samples(let values) = entry { out += values } }
        return out
    }
    var events: [CaptureEvent] {
        var out: [CaptureEvent] = []
        for entry in all { if case .event(let event) = entry { out.append(event) } }
        return out
    }
    var count: Int { lock.withLock { entries.count } }
    var failures: [String] {
        var out: [String] = []
        for event in events { if case .failed(let reason) = event { out.append(reason) } }
        return out
    }
}

#if os(Linux)
/// Pids whose command line contains `marker`. Reads /proc with plain read(2): Foundation's file
/// reading crashes on /proc files that change under it.
private func processes(containing marker: String) -> [pid_t] {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
    return entries.compactMap { entry in
        guard let pid = pid_t(entry) else { return nil }
        let descriptor = open("/proc/\(entry)/cmdline", O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self).contains(marker) ? pid : nil
    }
}

/// A recorder command that prints `script` (a shell fragment) and nothing else of its own.
private func shell(_ script: String) -> [String] { ["/bin/sh", "-c", script] }

@Suite struct PipeCaptureTests {
    /// Runs the recorder script; with no `wait`, until it has ended on its own (the failed event), at most 5 s.
    private func run(_ script: String, grace: Duration = .seconds(3), wait: Duration? = nil) throws -> (Log, CaptureStats) {
        let capture = PipeCapture(command: shell(script), terminationGrace: grace)
        let log = Log()
        try capture.start(sink: { log.sink($0) }, onEvent: { log.event($0) })
        if let wait {
            Thread.sleep(forTimeInterval: wait.seconds)
        } else {
            let deadline = Date().addingTimeInterval(5)
            while log.failures.isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        }
        return (log, capture.stop())
    }

    @Test func aSampleSplitAcrossReadsIsJoinedBack() throws {
        // Samples 1, 2, 3, 4 written as 3 + 1 + 4 bytes with a pause between, so each write is its own read.
        let (log, stats) = try run(#"printf '\001\000\002'; sleep 0.15; printf '\000'; sleep 0.15; printf '\003\000\004\000'; sleep 0.15; exit 0"#)
        #expect(log.samples == [1, 2, 3, 4])
        #expect(stats.droppedBuffers == 0)
    }

    @Test func samplesAreLittleEndianSigned() throws {
        let (log, _) = try run(#"printf '\000\200\377\177\377\377'"#)
        #expect(log.samples == [Int16.min, Int16.max, -1])
    }

    @Test func aHalfSampleAtTheEndIsDroppedAndReported() throws {
        let (log, stats) = try run(#"printf '\001\000\002'"#)
        #expect(log.samples == [1])
        #expect(stats.droppedBuffers == 1)
        #expect(log.failures.count == 1)
        #expect(log.failures.first?.contains("half a sample") == true)
    }

    @Test func theFirstNonzeroSampleRaisesSignalOnceBeforeItsAudio() throws {
        let (log, _) = try run(#"printf '\000\000\000\000'; sleep 0.15; printf '\000\000\005\000'; sleep 0.15; printf '\007\000'; sleep 0.15"#)
        #expect(log.events.filter { $0 == .signal }.count == 1)
        let signalAt = try #require(log.all.firstIndex(of: .event(.signal)))
        let firstAudible = try #require(log.all.firstIndex(of: .samples([0, 5])))
        #expect(signalAt < firstAudible, "the signal is raised before the buffer that carries it is delivered")
    }

    @Test func digitalSilenceRaisesNoSignal() throws {
        let (log, _) = try run(#"printf '\000\000\000\000\000\000'; sleep 0.2"#)
        #expect(log.samples == [0, 0, 0])
        #expect(!log.events.contains(.signal))
    }

    @Test func theLevelIsTheMeanSquareOfTheLatestBufferScaledToUnity() async throws {
        // 0x4000 is half of full scale: mean square 0.25. A command that stays alive, so the level is read while running.
        let capture = PipeCapture(command: shell(#"printf '\000\100\000\100'; sleep 5"#), terminationGrace: .seconds(1))
        let log = Log()
        try capture.start(sink: { log.sink($0) }, onEvent: { log.event($0) })
        defer { _ = capture.stop() }
        let deadline = Date().addingTimeInterval(3)
        while capture.meanSquare == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(capture.meanSquare == 0.25)
        _ = capture.stop()
        #expect(capture.meanSquare == 0, "a stopped capture reads silence")
    }

    @Test func aRecorderThatDiesEarlyReportsFailedOnceAfterTheLastSample() throws {
        let (log, stats) = try run(#"printf '\001\000\002\000'; echo "no such node" >&2; exit 3"#)
        #expect(log.samples == [1, 2])
        let failures = log.failures
        #expect(failures.count == 1)
        #expect(failures.first?.contains("exit status 3") == true)
        #expect(failures.first?.contains("no such node") == true)
        #expect(log.all.last == .event(.failed(failures[0])), "failed comes after every sample")
        #expect(stats == CaptureStats())
    }

    @Test func stopDoesNotReportAFailureForTheDeathItCaused() throws {
        let (log, _) = try run(#"exec cat /dev/zero"#, wait: .milliseconds(200))
        #expect(log.failures.isEmpty)
        #expect(log.samples.count > 0)
    }

    @Test func stopTerminatesItsOwnChildAndNothingArrivesAfterItReturns() throws {
        let marker = "31.\(Int.random(in: 100_000...999_999))"
        let capture = PipeCapture(command: ["/bin/sh", "-c", "exec yes \(marker)"], terminationGrace: .seconds(3))
        let log = Log()
        try capture.start(sink: { log.sink($0) }, onEvent: { log.event($0) })
        func running() -> Bool { !processes(containing: marker).isEmpty }
        let deadline = Date().addingTimeInterval(5)
        while !running(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(running(), "the recorder was running (precondition)")
        // Under a loaded machine the child can be running before its first bytes arrive.
        while log.count == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let started = Date()
        _ = capture.stop()
        #expect(Date().timeIntervalSince(started) < 2.5)
        #expect(!running())
        let delivered = log.count
        #expect(delivered > 0)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(log.count == delivered)
        #expect(capture.stop() == CaptureStats(), "stop on a stopped capture is empty")
    }

    @Test func aSlowSinkLosesNoSamplesWhenStopRuns() throws {
        // 20 chunks of 2000 bytes, then the recorder idles. The sink takes 0.6 s per call, far longer
        // than the 0.1 s termination grace, so the drain outlives the grace.
        let capture = PipeCapture(command: shell(#"for i in $(seq 20); do head -c 2000 /dev/zero; done; exec sleep 30"#), terminationGrace: .milliseconds(100))
        let received = Mutex(0)
        let calls = Mutex(0)
        try capture.start(sink: { buffer in
            calls.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.6)
            received.withLock { $0 += buffer.count }
        }, onEvent: { _ in })
        let deadline = Date().addingTimeInterval(5)
        while calls.withLock({ $0 }) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        Thread.sleep(forTimeInterval: 0.3) // the recorder has written everything into the pipe by now
        _ = capture.stop()
        #expect(calls.withLock { $0 } >= 2, "the sink was still busy when stop ran (precondition)")
        #expect(received.withLock { $0 } == 20_000, "every sample the recorder wrote reached the sink")
    }

    @Test func aDescendantLeftBehindByARecorderThatExitsIsKilled() throws {
        let marker = "32.\(Int.random(in: 100_000...999_999))"
        // The descendant has its output redirected, so the pipe reaches EOF when the leader exits.
        let capture = PipeCapture(command: shell("sleep \(marker) >/dev/null 2>&1 </dev/null & sleep 0.5; exit 0"), terminationGrace: .seconds(1))
        let log = Log()
        try capture.start(sink: { log.sink($0) }, onEvent: { log.event($0) })
        defer { for pid in processes(containing: marker) { kill(pid, SIGKILL) } }
        let deadline = Date().addingTimeInterval(5)
        while processes(containing: marker).isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!processes(containing: marker).isEmpty, "the descendant existed (precondition)")
        while log.failures.isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!log.failures.isEmpty, "the recorder ended by itself")
        _ = capture.stop()
        let end = Date().addingTimeInterval(2)
        while !processes(containing: marker).isEmpty, Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        #expect(processes(containing: marker).isEmpty, "no survivor")
    }

    @Test func aHolderOutsideTheGroupDoesNotStallStopOrCostSamples() throws {
        let marker = "29.\(Int.random(in: 100_000...999_999))"
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("holder-\(marker).pid").path
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        // setsid puts the sleeper in a session and group of its own; it inherits stdout, so the pipe
        // never reaches EOF. It writes its own pid first, so the precondition below does not depend
        // on catching it in a /proc scan.
        let capture = PipeCapture(
            command: shell(#"printf '\001\000'; setsid sh -c 'echo $$ > "$0"; exec sleep \#(marker)' \#(pidFile) & exec sleep 30"#),
            terminationGrace: .milliseconds(300))
        let log = Log()
        try capture.start(sink: { log.sink($0) }, onEvent: { log.event($0) })
        func holder() -> pid_t? {
            guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return kill(pid, 0) == 0 ? pid : nil
        }
        defer { if let pid = holder() { kill(pid, SIGKILL) } }
        let deadline = Date().addingTimeInterval(5)
        while (holder() == nil || log.samples.isEmpty), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(holder() != nil, "the escaped holder exists (precondition)")
        let started = Date()
        _ = capture.stop()
        #expect(Date().timeIntervalSince(started) < 2.5)
        #expect(log.samples == [1])
    }

    @Test func aRecorderThatIgnoresTermIsKilledAndWhatItWroteIsKept() throws {
        let started = Date()
        let (log, _) = try run(#"trap '' TERM; while :; do printf '\001\000'; sleep 0.02; done"#, grace: .milliseconds(300), wait: .milliseconds(300))
        #expect(Date().timeIntervalSince(started) < 1.2, "killed at the 0.3 s grace, not left to the later abandon path")
        #expect(log.samples.count > 3)
        #expect(log.samples.allSatisfy { $0 == 1 })
    }

    @Test func startingTwiceIsRefusedAndACaptureCanRestartAfterStop() throws {
        let capture = PipeCapture(command: shell(#"printf '\001\000'; sleep 5"#), terminationGrace: .seconds(1))
        let log = Log()
        func waitFor(samples count: Int) {
            let deadline = Date().addingTimeInterval(5)
            while log.samples.count < count, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        }
        try capture.start(sink: { log.sink($0) }, onEvent: { log.event($0) })
        #expect(throws: PipeCaptureError.self) { try capture.start(sink: { _ in }, onEvent: { _ in }) }
        waitFor(samples: 1)
        _ = capture.stop()
        try capture.start(sink: { log.sink($0) }, onEvent: { log.event($0) })
        waitFor(samples: 2)
        _ = capture.stop()
        #expect(log.samples == [1, 1])
    }

    @Test func aRecorderStartedFromAThreadThatBlocksSigtermStillStopsOnSigterm() throws {
        // A daemon blocks or ignores signals it handles itself; the recorder must not inherit that.
        var blocked = sigset_t(), previous = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTERM)
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        let capture = PipeCapture(command: shell(#"exec cat /dev/zero"#), terminationGrace: .seconds(10))
        try capture.start(sink: { _ in }, onEvent: { _ in })
        Thread.sleep(forTimeInterval: 0.2)
        let started = Date()
        _ = capture.stop()
        #expect(Date().timeIntervalSince(started) < 3, "SIGTERM reached the recorder; it did not wait for the 10 s grace")
    }

    @Test func aMissingOrEmptyCommandThrowsBeforeAnythingStarts() {
        #expect(throws: PipeCaptureError.self) {
            try PipeCapture(command: ["vizier-no-such-recorder-\(UUID().uuidString)"]).start(sink: { _ in }, onEvent: { _ in })
        }
        #expect(throws: PipeCaptureError.self) { try PipeCapture(command: []).start(sink: { _ in }, onEvent: { _ in }) }
    }

    @Test func prepareCapturesNothing() {
        let capture = PipeCapture(command: shell("exit 1"))
        capture.prepare()
        #expect(capture.meanSquare == 0)
        #expect(capture.stop() == CaptureStats())
    }
}
#endif

/// A capture driven by hand: the test calls `feed`, as the audio thread would.
final class FakeCapture: AudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: CaptureSink?
    private var onEvent: (@Sendable (CaptureEvent) -> Void)?
    var failToStart: (any Error)?
    private(set) var prepared = 0

    var meanSquare: Float { 0 }
    func prepare() { prepared += 1 }

    func start(sink: @escaping CaptureSink, onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws {
        if let failToStart { throw failToStart }
        self.sink = sink
        self.onEvent = onEvent
    }

    func feed(_ samples: [Int16]) { samples.withUnsafeBufferPointer { sink?($0) } }
    func emit(_ event: CaptureEvent) { onEvent?(event) }

    func stop() -> CaptureStats {
        sink = nil
        onEvent = nil
        return CaptureStats(deviceSwitches: 2, droppedBuffers: 5)
    }
}

private struct StartFailure: Error {}

/// A WAV recording next to the take's own files, whatever the platform's default recording format.
private let wavFactory: @Sendable (TakeFiles) throws -> any RecordingFile = {
    try WAVRecordingFile(url: $0.directory.appending(path: $0.id + ".wav"))
}

private func wavURL(_ take: TakeFiles) -> URL { take.directory.appending(path: take.id + ".wav") }

/// A recording file that fails on demand, and remembers what it was given.
private final class FlakyFile: RecordingFile, @unchecked Sendable {
    private(set) var appended: [Int16] = []
    private(set) var closes = 0
    var failAppendAfter: Int?
    var failClose = false

    func append(_ samples: UnsafeBufferPointer<Int16>) throws {
        if let limit = failAppendAfter, appended.count >= limit { throw AudioFileError.tooLarge }
        appended += samples
    }

    func close() throws {
        closes += 1
        if failClose { throw AudioFileError.invalidFormat }
    }
}

private final class Chunks: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func add(_ data: Data) { lock.withLock { values.append(data) } }
    var all: [Data] { lock.withLock { values } }
}

@Suite struct TakeRecorderTests {
    private let store: TakeStore

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vizier-recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = TakeStore(root: root)
    }

    private func ramp(_ count: Int, from start: Int = 0) -> [Int16] { (start..<start + count).map { Int16(truncatingIfNeeded: $0 &* 31 &+ 7) } }

    @Test func everySampleIsOnDiskAndChunksAreExactly3200BytesWithTheRemainderDeliveredAtStop() throws {
        let capture = FakeCapture()
        let recorder = TakeRecorder(capture: capture, recordingFactory: wavFactory)
        let take = try store.newTake()
        let chunks = Chunks()
        try recorder.start(take, onChunk: { chunks.add($0) }, onEvent: { _ in })
        // Uneven buffers: 700 + 1,000 + 2,000 + 1,000 + 123 = 4,823 samples = 3 chunks of 1,600 and 23.
        var all: [Int16] = []
        for size in [700, 1_000, 2_000, 1_000, 123] {
            let part = ramp(size, from: all.count)
            all += part
            capture.feed(part)
        }
        #expect(chunks.all.map(\.count) == [3_200, 3_200, 3_200], "complete chunks go out as the audio arrives")
        let summary = recorder.stop()
        #expect(chunks.all.map(\.count) == [3_200, 3_200, 3_200, 46], "the partial last chunk is delivered at stop")
        let delivered = chunks.all.reduce(into: Data()) { $0.append($1) }
        #expect(delivered == all.withUnsafeBytes { Data($0) })
        #expect(summary.frames == Int64(all.count))
        #expect(summary.seconds == Double(all.count) / 16_000)
        #expect(summary.capture == CaptureStats(deviceSwitches: 2, droppedBuffers: 5))
        #expect(summary.writeError == nil)
        #expect(try WAVFile.samples(wavURL(take)) == all, "every sample is in the recording")
    }

    #if !os(macOS)
    @Test func theRecordingIsPrivateBeforeAnySampleArrives() throws {
        let recorder = TakeRecorder(capture: FakeCapture())
        let take = try store.newTake()
        try recorder.start(take, onChunk: { _ in }, onEvent: { _ in })
        defer { _ = recorder.stop() }
        var info = stat()
        try #require(stat(take.recording.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(take.recording.pathExtension == "wav")
    }
    #endif

    @Test func warmUpPreparesTheCaptureAndDoesNothingElse() throws {
        let capture = FakeCapture()
        let recorder = TakeRecorder(capture: capture)
        recorder.warmUp()
        #expect(capture.prepared == 1)
        #expect(recorder.capturedSeconds == 0)
    }

    @Test func capturedSecondsFollowTheSamplesReceived() throws {
        let capture = FakeCapture()
        let recorder = TakeRecorder(capture: capture)
        try recorder.start(try store.newTake(), onChunk: { _ in }, onEvent: { _ in })
        capture.feed(ramp(8_000))
        #expect(recorder.capturedSeconds == 0.5)
        _ = recorder.stop()
    }

    @Test func aFailureClosingTheRecordingLandsInWriteErrorAndTheTakeStillReturns() throws {
        let file = FlakyFile()
        file.failClose = true
        let capture = FakeCapture()
        let recorder = TakeRecorder(capture: capture, recordingFactory: { _ in file })
        try recorder.start(try store.newTake(), onChunk: { _ in }, onEvent: { _ in })
        capture.feed(ramp(1_600))
        let summary = recorder.stop()
        #expect(file.closes == 1)
        #expect(summary.frames == 1_600)
        #expect(summary.writeError?.contains("closing the recording failed") == true)
    }

    @Test func aFailedWriteIsReportedKeepsEarlierAudioAndDoesNotStopTheChunks() throws {
        let file = FlakyFile()
        file.failAppendAfter = 1_600
        let capture = FakeCapture()
        let recorder = TakeRecorder(capture: capture, recordingFactory: { _ in file })
        let chunks = Chunks()
        try recorder.start(try store.newTake(), onChunk: { chunks.add($0) }, onEvent: { _ in })
        capture.feed(ramp(1_600))
        capture.feed(ramp(1_600, from: 1_600))
        capture.feed(ramp(1_600, from: 3_200))
        let summary = recorder.stop()
        #expect(file.appended == ramp(1_600))
        #expect(summary.writeError != nil)
        #expect(summary.frames == 4_800)
        #expect(chunks.all.count == 3, "the live transcriber keeps its audio when the disk fails")
    }

    @Test func aCaptureThatFailsToStartLeavesNoOpenRecording() throws {
        let file = FlakyFile()
        let capture = FakeCapture()
        capture.failToStart = StartFailure()
        let recorder = TakeRecorder(capture: capture, recordingFactory: { _ in file })
        #expect(throws: StartFailure.self) {
            try recorder.start(try store.newTake(), onChunk: { _ in }, onEvent: { _ in })
        }
        #expect(file.closes == 1)
    }

    @Test func aFailedEventPassesThroughAndTheAudioSoFarIsKept() throws {
        let capture = FakeCapture()
        let recorder = TakeRecorder(capture: capture, recordingFactory: wavFactory)
        let take = try store.newTake()
        let log = Log()
        try recorder.start(take, onChunk: { _ in }, onEvent: { log.event($0) })
        capture.feed(ramp(2_000))
        capture.emit(.failed("recorder died"))
        let summary = recorder.stop()
        #expect(log.events == [.failed("recorder died")])
        #expect(summary.frames == 2_000)
        #expect(try WAVFile.samples(wavURL(take)) == ramp(2_000))
    }

    #if os(Linux)
    @Test func aRecorderOverARealPipeCaptureWritesWhatTheCommandSent() throws {
        let recorder = TakeRecorder(capture: PipeCapture(command: shell(#"printf '\001\000\002\000\003\000'; sleep 0.3"#)), recordingFactory: wavFactory)
        let take = try store.newTake()
        let chunks = Chunks()
        try recorder.start(take, onChunk: { chunks.add($0) }, onEvent: { _ in })
        let deadline = Date().addingTimeInterval(5)
        while recorder.capturedSeconds == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let summary = recorder.stop()
        #expect(summary.frames == 3)
        #expect(try WAVFile.samples(wavURL(take)) == [1, 2, 3])
        #expect(chunks.all.reduce(into: Data()) { $0.append($1) } == Data([1, 0, 2, 0, 3, 0]))
    }
    #endif
}
