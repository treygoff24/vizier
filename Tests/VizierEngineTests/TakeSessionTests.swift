import Foundation
import Synchronization
import Testing
@testable import VizierEngine

// Whole takes through `TakeSession`, with a fake for every collaborator. Audio is a generated sine
// wave; nothing here touches a microphone, a network, a keychain or a clipboard.

private enum TSFakeFailure: Error { case boom }

actor TSGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

final class TSFakeCapture: AudioCapture {
    private struct State {
        var sink: CaptureSink?
        var onEvent: (@Sendable (CaptureEvent) -> Void)?
        var signalled = false
        var failStart = false
        var prepared = 0
        var phase = 0.0
        /// Kept after `stop()`, so a test can deliver an event the way a straggling callback would.
        var lastOnEvent: (@Sendable (CaptureEvent) -> Void)?
    }

    private let state = Mutex(State())
    var meanSquare: Float { 0.25 }

    func failNextStart() { state.withLock { $0.failStart = true } }
    var prepareCount: Int { state.withLock { $0.prepared } }

    func prepare() { state.withLock { $0.prepared += 1 } }

    func emitLate(_ event: CaptureEvent) {
        let handler = state.withLock { $0.lastOnEvent }
        handler?(event)
    }

    func start(sink: @escaping CaptureSink, onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws {
        try state.withLock {
            if $0.failStart { $0.failStart = false; throw TSFakeFailure.boom }
            $0.sink = sink
            $0.onEvent = onEvent
            $0.lastOnEvent = onEvent
            $0.signalled = false
        }
    }

    func stop() -> CaptureStats {
        state.withLock {
            $0.sink = nil
            $0.onEvent = nil
        }
        return CaptureStats(deviceSwitches: 1, droppedBuffers: 0)
    }

    /// Delivers `seconds` of a 440 Hz sine in one sink call; the first call also reports the signal.
    func feed(seconds: Double) {
        let (sink, onEvent, first, start) = state.withLock { s -> (CaptureSink?, (@Sendable (CaptureEvent) -> Void)?, Bool, Double) in
            let first = !s.signalled
            s.signalled = true
            let start = s.phase
            s.phase += Double(Int(seconds * 16_000))
            return (s.sink, s.onEvent, first, start)
        }
        let samples = (0..<Int(seconds * 16_000)).map { Int16(sin((start + Double($0)) * 2 * .pi * 440 / 16_000) * 8_000) }
        samples.withUnsafeBufferPointer { sink?($0) }
        if first { onEvent?(.signal) }
    }
}

final class TSFakeLive: LiveTranscriber {
    enum Finish: Sendable { case final(String), fail(TranscriberError), hang }

    private struct State {
        var onEvent: (@Sendable (LiveTranscriberEvent) -> Void)?
        var sent = 0
        var started = false
        var cancelled = false
        var waiter: CheckedContinuation<String, any Error>?
    }

    private let state = Mutex(State())
    let finishWith: Finish
    init(_ finishWith: Finish) { self.finishWith = finishWith }

    var sentBytes: Int { state.withLock { $0.sent } }
    var wasCancelled: Bool { state.withLock { $0.cancelled } }

    func start(onEvent: @escaping @Sendable (LiveTranscriberEvent) -> Void) {
        state.withLock {
            $0.onEvent = onEvent
            $0.started = true
        }
    }

    func send(_ pcm: Data) { state.withLock { $0.sent += pcm.count } }

    func emit(_ event: LiveTranscriberEvent) {
        let handler = state.withLock { $0.onEvent }
        handler?(event)
    }

    func finish() async throws -> String {
        switch finishWith {
        case .final(let text): return text
        case .fail(let error): throw error
        case .hang:
            return try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { s -> Bool in
                    if s.cancelled { return true }
                    s.waiter = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: TranscriberError.cancelled) }
            }
        }
    }

    func cancel() {
        let waiter = state.withLock { s -> CheckedContinuation<String, any Error>? in
            s.cancelled = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(throwing: TranscriberError.cancelled)
    }
}

final class TSFakeBatch: BatchTranscriber {
    enum Result: Sendable { case text(String), fail(BatchError), failAny(String) }

    let result: Result
    let route: BatchReport.Route
    let gate: TSGate?
    private let calls = Mutex(0)

    init(_ result: Result, route: BatchReport.Route = .inline, gate: TSGate? = nil) {
        self.result = result
        self.route = route
        self.gate = gate
    }

    var callCount: Int { calls.withLock { $0 } }

    func transcribeReporting(_ audio: URL) async throws -> BatchReport {
        calls.withLock { $0 += 1 }
        if let gate { await gate.wait() }
        switch result {
        case .text(let text):
            return BatchReport(route: route, bytes: 1, uploadSeconds: 0, transcriptionSeconds: 0, remoteDeleted: nil,
                               result: BatchTranscript(text: text, truncated: false), retried: false)
        case .fail(let error): throw error
        case .failAny(let message): throw NSError(domain: message, code: 1)
        }
    }
}

final class TSFakeCleaner: TextCleaner {
    enum Result: Sendable { case text(String), fail }
    let result: Result
    let gate: TSGate?
    init(_ result: Result, gate: TSGate? = nil) {
        self.result = result
        self.gate = gate
    }

    func clean(_ transcript: String) async throws -> String {
        if let gate { await gate.wait() }
        switch result {
        case .text(let text): return text
        case .fail: throw TSFakeFailure.boom
        }
    }
}

final class TSFakeSecrets: SecretStore {
    private let values = Mutex<[String: String]>([:])
    private let failing = Mutex(false)
    func set(_ account: String, _ value: String) { values.withLock { $0[account] = value } }
    func failReads() { failing.withLock { $0 = true } }
    func read(_ account: String) throws -> String? {
        if failing.withLock({ $0 }) { throw TSFakeFailure.boom }
        return values.withLock { $0[account] }
    }
    func store(_ value: String, account: String) throws { set(account, value) }
}

/// Hands the session its transcribers, as `Engines` would: a cloud engine with no key gets none.
final class TSEngineKit: Sendable {
    private struct State {
        var lives: [TSFakeLive] = []
        var batches: [String: TSFakeBatch] = [:]
        var cleaners: [String: TSFakeCleaner] = [:]
        var liveKeys: [String?] = []
    }

    private let state = Mutex(State())
    func queue(_ live: TSFakeLive) { state.withLock { $0.lives.append(live) } }
    func setBatch(_ engine: String, _ batch: TSFakeBatch) { state.withLock { $0.batches[engine] = batch } }
    func setCleaner(_ engine: String, _ cleaner: TSFakeCleaner) { state.withLock { $0.cleaners[engine] = cleaner } }
    var keysSeenByLive: [String?] { state.withLock { $0.liveKeys } }

    var engines: TakeEngines {
        TakeEngines(
            live: { _, _, key in
                self.state.withLock { s in
                    s.liveKeys.append(key)
                    guard key != nil, !s.lives.isEmpty else { return nil }
                    return s.lives.removeFirst()
                }
            },
            batch: { spec, _, _, key in
                let needsKey = Engines.keyAccount(for: spec.engine) != nil
                if needsKey, key == nil { return nil }
                return self.state.withLock { $0.batches[spec.engine] }
            },
            cleaner: { pass, _, _, key in
                if pass.engine != "local-cleanup", key == nil { return nil }
                return self.state.withLock { $0.cleaners[pass.engine] }
            })
    }
}

@MainActor
final class TSFakePresentation: TakePresentation {
    var phases: [TakePhase] = []
    var alerts = 0
    var began: [(destination: String, platform: String)] = []
    var lives = 0
    var words: [[WordLine.Plate]] = []
    var streamLosts: [String] = []
    var stoppedOnTime: [TimeInterval] = []
    var rerouting = 0
    var finishes: [(result: TakeResult, remark: String?)] = []

    func phaseChanged(_ phase: TakePhase) { phases.append(phase) }
    func raiseAlert() { alerts += 1 }
    func begin(destination: String, platform: String, level: @escaping @Sendable () -> Float, seconds: @escaping @Sendable () -> Double) {
        began.append((destination, platform))
    }
    func setLive() { lives += 1 }
    func setWords(_ plates: [WordLine.Plate]) { words.append(plates) }
    func streamLost(remark: String) { streamLosts.append(remark) }
    func stopped(onTime: TimeInterval) { stoppedOnTime.append(onTime) }
    func reroutingToBatch() { rerouting += 1 }
    func finish(_ result: TakeResult, remark: String?) { finishes.append((result, remark)) }
}

@MainActor
final class TSFakeSounds: SoundPlayer {
    var played: [TakeSound] = []
    func play(_ sound: TakeSound) { played.append(sound) }
}

@MainActor
final class TSFakeMic: MicPermission {
    var denied = false
    func microphoneDenied() -> Bool { denied }
}

@MainActor
final class TSFakeFocus: FocusProbe {
    var name = "Notes"
    var pid: Int32? = 4_242
    func destinationName() -> String { name }
    func focusedProcess() -> Int32? { pid }
    /// When set, the stop's fresh read answers this after a short suspension (a slow desktop reader).
    var fresh: Int32?
    func focusAtStop() async -> Int32? {
        guard let fresh else { return focusedProcess() }
        try? await Task.sleep(for: .milliseconds(30))
        return fresh
    }
}

@MainActor
final class TSFakePaster: PasteService {
    var outcome = PasteOutcome(kind: .pasted, method: "keystroke", reason: nil, onClipboard: true, permissionMissing: false, logCode: "keystroke")
    var gate: TSGate?
    var pasted: [String] = []
    /// The texts whose paste actually went out (not withdrawn).
    var sent: [String] = []
    var focusSeen: [Int32?] = []

    func paste(_ text: String, focusAtStop: Int32?, stillWanted: @escaping @MainActor () -> Bool) async -> PasteOutcome {
        pasted.append(text)
        focusSeen.append(focusAtStop)
        if let gate { await gate.wait() }
        guard stillWanted() else {
            return PasteOutcome(kind: .withdrawn, method: "", reason: nil, onClipboard: true, permissionMissing: false, logCode: "withdrawn")
        }
        sent.append(text)
        return outcome
    }

    static func held(_ reason: String, onClipboard: Bool = true) -> PasteOutcome {
        PasteOutcome(kind: .held, method: "", reason: reason, onClipboard: onClipboard, permissionMissing: false, logCode: "held")
    }

    static func failed(_ reason: String = "paste broke", onClipboard: Bool = true, permissionMissing: Bool = false) -> PasteOutcome {
        PasteOutcome(kind: .failed, method: "", reason: reason, onClipboard: onClipboard, permissionMissing: permissionMissing, logCode: "failed")
    }
}

/// A recording file that really writes, then fails where the test says.
final class TSFlakyRecordingFile: RecordingFile {
    private let inner: any RecordingFile
    private let failAppendsFrom: Int?
    private let failClose: Bool
    private let appends = Mutex(0)

    init(_ inner: any RecordingFile, failAppendsFrom: Int? = nil, failClose: Bool = false) {
        self.inner = inner
        self.failAppendsFrom = failAppendsFrom
        self.failClose = failClose
    }

    func append(_ samples: UnsafeBufferPointer<Int16>) throws {
        let n = appends.withLock { n -> Int in defer { n += 1 }; return n }
        if let failAppendsFrom, n >= failAppendsFrom { throw TSFakeFailure.boom }
        try inner.append(samples)
    }

    func close() throws {
        try inner.close()
        if failClose { throw TSFakeFailure.boom }
    }
}

extension VizierConfig.Mode {
    static let testCloud = VizierConfig.Mode(
        id: "cloud", name: "Cloud",
        transcriber: .init(engine: "gemini-live", model: "live-m", mode: "verbatim", languages: ["en-US"], finalTimeoutMs: 1_000),
        fallback: .init(engine: "gemini-batch", model: "batch-m", mode: "verbatim"), removeFillers: false)

    static let testCleaned = VizierConfig.Mode(
        id: "cleaned", name: "Cleaned",
        transcriber: .init(engine: "gemini-live", model: "live-m", mode: "verbatim", languages: ["en-US"], finalTimeoutMs: 1_000),
        fallback: .init(engine: "gemini-batch", model: "batch-m", mode: "verbatim"),
        cleanup: .init(engine: "gemini-generate", model: "clean-m", thinkingLevel: nil, timeoutMs: 400), removeFillers: false)

    static let testBatchCloud = VizierConfig.Mode(
        id: "batchcloud", name: "BatchCloud",
        transcriber: .init(engine: "gemini-batch", model: "b", mode: "verbatim", languages: ["en-US"], finalTimeoutMs: 1_000),
        removeFillers: false)

    static let testLocal = VizierConfig.Mode(
        id: "local", name: "Local",
        transcriber: .init(engine: "local-whisper", model: "w", mode: "verbatim", languages: ["en-US"], finalTimeoutMs: 1_000),
        removeFillers: false)
}

@MainActor
final class TSRig {
    let root: URL
    let config: ConfigStore
    let takes: TakeStore
    let databaseURL: URL
    let history: HistoryStore
    let capture = TSFakeCapture()
    let kit = TSEngineKit()
    let secrets = TSFakeSecrets()
    let presentation = TSFakePresentation()
    let sounds = TSFakeSounds()
    let mic = TSFakeMic()
    let focus = TSFakeFocus()
    let paster = TSFakePaster()
    let session: TakeSession

    init(
        mode: VizierConfig.Mode = .testCloud, remarks: TakeRemarks = .mac, key: Bool = true, ready: Bool = true,
        speech: SpeechModelCheck = .none, takesRoot: URL? = nil, seed: ((TakeStore, URL) throws -> Void)? = nil,
        recordingFactory: (@Sendable (TakeFiles) throws -> any RecordingFile)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "vizier-session-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        config = ConfigStore(directory: root.appending(path: "config"))
        try PrivateFiles.makeDirectory(config.directory)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(VizierConfig.Settings(mode: mode.id, modes: [mode])).write(to: config.settingsURL)
        let load = config.load()
        try #require(load.errors.isEmpty, "the test config must load: \(load.errors)")
        takes = TakeStore(root: takesRoot ?? root.appending(path: "Takes"))
        databaseURL = root.appending(path: "history.sqlite")
        // What an earlier run left behind, before this run's history opens (rows open at that moment are the crash's).
        try seed?(takes, databaseURL)
        history = try HistoryStore(databaseURL: databaseURL, takesRoot: takes.root)
        if key {
            secrets.set("gemini", "test-gemini-key")
            secrets.set("elevenlabs", "test-elevenlabs-key")
        }
        let fakeCapture = capture
        let recorder = recordingFactory.map { TakeRecorder(capture: fakeCapture, recordingFactory: $0) } ?? TakeRecorder(capture: fakeCapture)
        session = TakeSession(
            config: config, store: takes, recorder: recorder, history: history, secrets: secrets, presentation: presentation,
            sounds: sounds, microphone: mic, focus: focus, paster: paster, remarks: remarks, speech: speech, engines: kit.engines)
        if ready { session.markReady() }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Polls the main actor until `condition` holds.
    func until(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Starts a take, feeds `seconds` of audio, and waits until the first signal has been seen.
    @discardableResult
    func record(seconds: Double = 1) async throws -> String {
        let status = try session.start()
        let id = try #require(status.takeID)
        capture.feed(seconds: seconds)
        try #require(await until { self.session.phase == .recording })
        return id
    }

    func stopAndSettle() async throws {
        _ = try session.stop()
        await session.settled()
    }

    func row(_ id: String) throws -> TakeRecord {
        try #require(try HistoryStore(databaseURL: databaseURL, takesRoot: takes.root).record(id: id))
    }

    var finishedRemark: String? { presentation.finishes.last?.remark }
}

@MainActor
@Suite struct TakeSessionTests {
    @Test func aTakeWithALiveFinalPastesItAndRecordsEveryStage() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.final("hello there world")))
        let id = try await rig.record(seconds: 1)
        #expect(rig.session.phase == .recording)
        #expect(rig.presentation.began.count == 1)
        #expect(rig.presentation.lives == 1)
        try await rig.stopAndSettle()

        #expect(rig.session.phase == .idle)
        #expect(rig.presentation.phases == [.arming, .recording, .finalizing, .idle])
        #expect(rig.sounds.played == [.start, .stop])
        #expect(rig.paster.pasted == ["hello there world "])
        #expect(rig.paster.focusSeen == [4_242])
        #expect(rig.presentation.finishes.count == 1)
        #expect(rig.presentation.finishes.first?.result == .pasted)
        #expect(rig.finishedRemark == nil)
        let record = try rig.row(id)
        #expect(record.outcome == .pasted)
        #expect(record.rawTranscript == "hello there world")
        #expect(record.finalText == "hello there world")
        #expect(record.route == "live")
        #expect(record.pasteMethod == "keystroke")
        #expect(record.destinationAtStart == "Notes")
        #expect(record.destinationAtPaste == "Notes")
        let audio = try #require(record.audioPath)
        #expect(audio.pathExtension == "flac")
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(abs(Double(try #require(record.durationMs)) - 1_000) < 5)
        let ending = try #require(rig.session.status().lastEnding)
        #expect(ending.takeID == id && ending.result == .pasted)
    }

    @Test func theChunksReachTheLiveTranscriberAndTheStatusReportsTheTake() async throws {
        let rig = try TSRig()
        let live = TSFakeLive(.final("x"))
        rig.kit.queue(live)
        let idle = rig.session.status()
        #expect(idle.phase == .idle && idle.takeID == nil && idle.seconds == 0 && idle.mode == "cloud")
        let id = try await rig.record(seconds: 1)
        let during = rig.session.status()
        #expect(during.phase == .recording && during.takeID == id && during.mode == "cloud")
        #expect(abs(during.seconds - 1) < 0.01)
        try await rig.stopAndSettle()
        #expect(live.sentBytes == 32_000)
    }

    @Test func aTakeWithNoKeyIsSavedAndSaysSoWithoutTheKeyOrAnyTranscript() async throws {
        let rig = try TSRig(key: false)
        let id = try await rig.record()
        try await rig.stopAndSettle()

        #expect(rig.kit.keysSeenByLive == [nil])
        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.presentation.finishes.first?.result == .failed)
        #expect(rig.finishedRemark == "There is no Gemini key yet, so nothing was transcribed. Add one in Settings › Accounts. The audio is saved.")
        #expect(rig.presentation.alerts >= 1)
        #expect(rig.sounds.played.contains(.problem))
        let record = try rig.row(id)
        #expect(record.outcome == .failed)
        #expect(record.outcomeReason == rig.finishedRemark)
        #expect(record.audioPath?.pathExtension == "flac")
    }

    @Test func aKeyStoreThatFailsToReadIsTreatedAsNoKey() async throws {
        let rig = try TSRig()
        rig.secrets.failReads()
        try await rig.record()
        try await rig.stopAndSettle()
        #expect(rig.presentation.finishes.first?.result == .failed)
        #expect(rig.finishedRemark?.hasPrefix("There is no Gemini key yet") == true)
    }

    @Test(arguments: [TranscriberError.timedOut, .streamLost("gone")])
    func aLiveFailureSendsTheSavedAudioToBatch(error: TranscriberError) async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.fail(error)))
        rig.kit.setBatch("gemini-batch", TSFakeBatch(.text("from batch")))
        let id = try await rig.record()
        try await rig.stopAndSettle()

        #expect(rig.presentation.rerouting == 1)
        #expect(rig.paster.pasted == ["from batch "])
        #expect(rig.presentation.finishes.first?.result == .rerouted(.batch))
        let why = error == .timedOut ? TakeRemarks.finalLate : TakeRemarks.streamDropped
        #expect(rig.finishedRemark == why)
        let record = try rig.row(id)
        #expect(record.outcome == .rerouted)
        #expect(record.outcomeReason == "batch")
        #expect(record.route == "batch")
        #expect(record.rawTranscript == "from batch")
    }

    @Test func aBatchThatFailsToo_PastesTheSettledLiveWords() async throws {
        let rig = try TSRig()
        let live = TSFakeLive(.fail(.streamLost("gone")))
        rig.kit.queue(live)
        rig.kit.setBatch("gemini-batch", TSFakeBatch(.failAny("down")))
        let id = try await rig.record()
        live.emit(.transcript(settled: "the settled words", pending: ""))
        try #require(await rig.until { rig.presentation.words.contains { !$0.isEmpty } })
        try await rig.stopAndSettle()

        #expect(rig.paster.pasted == ["the settled words "])
        #expect(rig.presentation.finishes.first?.result == .rerouted(.rawText))
        #expect(rig.finishedRemark == TakeRemarks.settledWords)
        let record = try rig.row(id)
        #expect(record.outcome == .rerouted)
        #expect(record.outcomeReason == "settled words")
        #expect(record.rawTranscript == "the settled words")
    }

    @Test func aBatchThatFailsWithNothingSettledFailsTheTakeButKeepsTheAudio() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.fail(.timedOut)))
        rig.kit.setBatch("gemini-batch", TSFakeBatch(.failAny("down")))
        let id = try await rig.record()
        try await rig.stopAndSettle()

        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.presentation.finishes.first?.result == .failed)
        #expect(rig.finishedRemark == TakeRemarks.unreachable)
        #expect(try rig.row(id).outcome == .failed)
        #expect(try rig.row(id).audioPath?.pathExtension == "flac")
    }

    @Test func aBatchThatIsTooLongSaysSo() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.fail(.timedOut)))
        rig.kit.setBatch("gemini-batch", TSFakeBatch(.fail(.tooLong(seconds: 4_000))))
        try await rig.record()
        try await rig.stopAndSettle()
        #expect(rig.finishedRemark == TakeRemarks.batchTooLong)
    }

    @Test func aCleanupPassThatFailsPastesTheRawTranscript() async throws {
        let rig = try TSRig(mode: .testCleaned)
        rig.kit.queue(TSFakeLive(.final("raw words here")))
        rig.kit.setCleaner("gemini-generate", TSFakeCleaner(.fail))
        let id = try await rig.record()
        try await rig.stopAndSettle()

        #expect(rig.paster.pasted == ["raw words here "])
        #expect(rig.presentation.finishes.first?.result == .rerouted(.rawText))
        #expect(rig.finishedRemark == TakeRemarks.cleanupFailed)
        let record = try rig.row(id)
        #expect(record.outcome == .rerouted)
        #expect(record.outcomeReason == "raw text")
        #expect(record.cleanedText == nil)
        #expect(record.cleanupMs != nil)
        #expect(record.finalText == "raw words here")
        // A mode with a cleanup pass gets the longer finalizing allowance.
        #expect(rig.presentation.stoppedOnTime == [1 + TakeSession.cleanupAllowance])
    }

    @Test func aCleanupPassThatAnswersIsWhatPastes() async throws {
        let rig = try TSRig(mode: .testCleaned)
        rig.kit.queue(TSFakeLive(.final("um raw words here")))
        rig.kit.setCleaner("gemini-generate", TSFakeCleaner(.text("Raw words here.")))
        let id = try await rig.record()
        try await rig.stopAndSettle()

        #expect(rig.paster.pasted == ["Raw words here. "])
        #expect(rig.presentation.finishes.first?.result == .pasted)
        #expect(try rig.row(id).cleanedText == "Raw words here.")
    }

    @Test func aBatchOnlyModeUsesBatchAsItsNormalPathAndSaysSoWhenItIsDown() async throws {
        let ok = try TSRig(mode: .testLocal)
        ok.kit.setBatch("local-whisper", TSFakeBatch(.text("local words"), route: .local))
        let okID = try await ok.record()
        try await ok.stopAndSettle()
        #expect(ok.kit.keysSeenByLive.isEmpty)
        #expect(ok.presentation.rerouting == 0)
        #expect(ok.presentation.finishes.first?.result == .pasted)
        #expect(ok.presentation.stoppedOnTime == [TakeSession.localAllowance])
        #expect(try ok.row(okID).route == "batch")

        let down = try TSRig(mode: .testLocal)
        down.kit.setBatch("local-whisper", TSFakeBatch(.failAny("refused")))
        try await down.record()
        try await down.stopAndSettle()
        #expect(down.finishedRemark == TakeRemarks.localDown)
    }

    @Test func aLiveFinalWithNoWordsFallsBackToTheSettledWordsAndIsNeverSentToBatch() async throws {
        let rig = try TSRig()
        let live = TSFakeLive(.final("   "))
        rig.kit.queue(live)
        let batch = TSFakeBatch(.text("should not be asked"))
        rig.kit.setBatch("gemini-batch", batch)
        try await rig.record()
        live.emit(.transcript(settled: "kept words", pending: ""))
        try #require(await rig.until { rig.presentation.words.contains { !$0.isEmpty } })
        try await rig.stopAndSettle()
        #expect(batch.callCount == 0)
        #expect(rig.paster.pasted == ["kept words "])
    }

    // MARK: Paste outcomes

    @Test func theStopPastesWithTheFreshFocusReadNotTheCachedOne() async throws {
        let rig = try TSRig()
        rig.focus.pid = 4_242       // what a stale cache would say
        rig.focus.fresh = 777       // where the user actually is at the stop
        rig.kit.queue(TSFakeLive(.final("hello there world")))
        _ = try await rig.record(seconds: 1)
        try await rig.stopAndSettle()
        #expect(rig.paster.focusSeen == [777])
    }

    @Test func aPasteHeldForFocusMovedKeepsTheTextOnTheClipboardAndSaysSo() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.final("some words")))
        rig.paster.outcome = TSFakePaster.held(PasteDecision.focusMoved)
        let id = try await rig.record()
        try await rig.stopAndSettle()

        #expect(rig.presentation.finishes.first?.result == .held)
        #expect(rig.finishedRemark == "You switched apps after the take stopped, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
        #expect(rig.presentation.alerts >= 1)
        #expect(rig.sounds.played.contains(.problem))
        let record = try rig.row(id)
        #expect(record.outcome == .held)
        #expect(record.outcomeReason == PasteDecision.focusMoved)
        #expect(record.pasteMethod == "clipboard")
    }

    @Test(arguments: [
        (PasteDecision.vizierHadFocus, "Vizier itself had focus, so nothing was pasted."),
        (PasteDecision.secureField, "A password field had focus, so nothing was pasted."),
        (PasteDecision.secureInput, "Secure input was on and the focused field could not be read, so nothing was pasted."),
        ("no target at all", "No text field had focus, so nothing was pasted."),
    ])
    func eachHeldReasonHasItsOwnSentence(reason: String, sentence: String) async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.final("some words")))
        rig.paster.outcome = TSFakePaster.held(reason)
        try await rig.record()
        try await rig.stopAndSettle()
        #expect(rig.finishedRemark == sentence + " The text is on the clipboard; ⌘V pastes it.")
    }

    @Test func aHeldPasteOnALinuxDesktopWithoutAClipboardPointsToVizierLast() async throws {
        let rig = try TSRig(remarks: .linux)
        rig.kit.queue(TSFakeLive(.final("some words")))
        rig.paster.outcome = TSFakePaster.held(PasteDecision.focusMoved, onClipboard: false)
        let id = try await rig.record()
        try await rig.stopAndSettle()

        let remark = try #require(rig.finishedRemark)
        #expect(remark == "You switched apps after the take stopped, so nothing was pasted. The text is saved in history; `vizier last` prints it.")
        #expect(!remark.contains("clipboard"))
        let record = try rig.row(id)
        #expect(record.outcome == .held)
        #expect(record.pasteMethod == nil)
    }

    @Test func aFailedPasteIsHeldOnTheClipboardOrSaysItWasNot() async throws {
        let withClipboard = try TSRig(remarks: .linux)
        withClipboard.kit.queue(TSFakeLive(.final("some words")))
        withClipboard.paster.outcome = TSFakePaster.failed()
        let id = try await withClipboard.record()
        try await withClipboard.stopAndSettle()
        #expect(withClipboard.finishedRemark == "The paste did not go through. The text is on the clipboard; Ctrl+V pastes it.")
        let held = try withClipboard.row(id)
        #expect(held.outcome == .held && held.outcomeReason == "paste failed" && held.pasteMethod == "clipboard")

        let without = try TSRig(remarks: .linux)
        without.kit.queue(TSFakeLive(.final("some words")))
        without.paster.outcome = TSFakePaster.failed(onClipboard: false)
        let id2 = try await without.record()
        try await without.stopAndSettle()
        #expect(without.finishedRemark == "The paste did not go through. The text is saved in history; `vizier last` prints it.")
        let lost = try without.row(id2)
        #expect(lost.outcome == .held && lost.pasteMethod == nil)
        #expect(lost.finalText == "some words")
    }

    @Test func aPasteBlockedByAMissingPermissionSaysHowToGrantIt() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.final("some words")))
        rig.paster.outcome = TSFakePaster.failed("Accessibility is not granted", permissionMissing: true)
        let id = try await rig.record()
        try await rig.stopAndSettle()
        #expect(rig.finishedRemark == "Vizier does not have Accessibility access, so nothing was pasted. Turn it on in System Settings › Privacy & Security › Accessibility. The text is on the clipboard; ⌘V pastes it.")
        #expect(try rig.row(id).outcomeReason == "accessibility not granted")
    }

    @Test func aHeldPasteStillCarriesTheHowTheTextWasGotWarnings() async throws {
        let rig = try TSRig()
        let live = TSFakeLive(.fail(.timedOut))
        rig.kit.queue(live)
        rig.kit.setBatch("gemini-batch", TSFakeBatch(.text("late words")))
        rig.paster.outcome = TSFakePaster.held(PasteDecision.secureField)
        try await rig.record()
        try await rig.stopAndSettle()
        #expect(rig.presentation.finishes.first?.result == .held)
        #expect(rig.finishedRemark == "A password field had focus, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
    }

    @Test func aPracticeTakeGoesToTheSinkAndIsRecordedAsPractice() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.final("practice words")))
        let received = Mutex<[String]>([])
        rig.session.practiceSink = { text in received.withLock { $0.append(text) } }
        let id = try await rig.record()
        try await rig.stopAndSettle()
        #expect(received.withLock { $0 } == ["practice words"])
        #expect(rig.paster.pasted.isEmpty)
        let record = try rig.row(id)
        #expect(record.outcome == .pasted && record.pasteMethod == "practice")
        #expect(rig.presentation.finishes.first?.result == .pasted)
    }

    // MARK: Cancel

    @Test func aCancelWhileRecordingKeepsTheAudioAndTheSettledWords() async throws {
        let rig = try TSRig()
        let live = TSFakeLive(.hang)
        rig.kit.queue(live)
        let id = try await rig.record()
        live.emit(.transcript(settled: "words before", pending: ""))
        try #require(await rig.until { rig.presentation.words.contains { !$0.isEmpty } })
        let status = try rig.session.cancel()
        await rig.session.settled()

        #expect(status.phase == .idle && status.takeID == nil)
        #expect(status.lastEnding?.result == .cancelled && status.lastEnding?.takeID == id)
        #expect(live.wasCancelled)
        #expect(rig.sounds.played == [.start, .cancel])
        #expect(rig.presentation.finishes.count == 1 && rig.presentation.finishes[0].result == .cancelled)
        #expect(rig.paster.pasted.isEmpty)
        let record = try rig.row(id)
        #expect(record.outcome == .cancelled)
        #expect(record.rawTranscript == "words before")
        #expect(record.audioPath?.pathExtension == "flac")
        #expect(FileManager.default.fileExists(atPath: try #require(record.audioPath).path))
    }

    @Test func aCancelWhileFinalizingDuringBatchWithdrawsTheTakeButKeepsTheBatchText() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.fail(.timedOut)))
        let gate = TSGate()
        rig.kit.setBatch("gemini-batch", TSFakeBatch(.text("batch text arrives late"), gate: gate))
        let id = try await rig.record()
        _ = try rig.session.stop()
        try #require(await rig.until { rig.presentation.rerouting == 1 })
        #expect(rig.session.phase == .finalizing)
        _ = try rig.session.cancel()
        #expect(rig.session.phase == .idle)
        await gate.open()
        await rig.session.settled()

        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.presentation.finishes.count == 1 && rig.presentation.finishes[0].result == .cancelled)
        let record = try rig.row(id)
        #expect(record.outcome == .cancelled)
        #expect(record.rawTranscript == "batch text arrives late")
    }

    @Test func aCancelDuringCleanupWithdrawsTheTake() async throws {
        let rig = try TSRig(mode: .testCleaned)
        rig.kit.queue(TSFakeLive(.final("raw words here")))
        let gate = TSGate()
        rig.kit.setCleaner("gemini-generate", TSFakeCleaner(.text("Raw words here."), gate: gate))
        let id = try await rig.record()
        _ = try rig.session.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.session.phase == .finalizing)
        _ = try rig.session.cancel()
        await gate.open()
        await rig.session.settled()

        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.paster.sent.isEmpty)
        #expect(rig.presentation.finishes.count == 1 && rig.presentation.finishes[0].result == .cancelled)
        let record = try rig.row(id)
        #expect(record.outcome == .cancelled)
        #expect(record.rawTranscript == "raw words here")
    }

    @Test func aCancelDuringThePrePastePauseWithdrawsThePaste() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.final("some words")))
        let gate = TSGate()
        rig.paster.gate = gate
        let id = try await rig.record()
        _ = try rig.session.stop()
        try #require(await rig.until { rig.paster.pasted.count == 1 })
        _ = try rig.session.cancel()
        await gate.open()
        await rig.session.settled()

        #expect(rig.paster.pasted.count == 1 && rig.paster.sent.isEmpty)
        #expect(rig.presentation.finishes.count == 1 && rig.presentation.finishes[0].result == .cancelled)
        #expect(rig.presentation.alerts == 0)
        #expect(rig.session.phase == .idle)
        let record = try rig.row(id)
        #expect(record.outcome == .cancelled)
        #expect(record.finalText == "some words")
        #expect(record.pasteMethod == nil)
    }

    @Test func aNewTakeStartedAfterACancelIsNotDisturbedByTheOldOnesLateCallbacks() async throws {
        let rig = try TSRig()
        let first = TSFakeLive(.hang)
        let second = TSFakeLive(.final("second take words"))
        rig.kit.queue(first)
        rig.kit.queue(second)
        try await rig.record()
        _ = try rig.session.cancel()
        let id2 = try await rig.record()
        let wordsBefore = rig.presentation.words.count
        let lostBefore = rig.presentation.streamLosts.count
        first.emit(.transcript(settled: "stale words", pending: "more"))
        first.emit(.streamLost("stale loss"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.presentation.words.count == wordsBefore)
        #expect(rig.presentation.streamLosts.count == lostBefore)
        try await rig.stopAndSettle()
        #expect(rig.paster.pasted == ["second take words "])
        #expect(try rig.row(id2).rawTranscript == "second take words")
    }

    @Test func aSignalThatArrivesAfterTheStopDoesNotRestartTheTake() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.hang))
        try await rig.record()
        _ = try rig.session.stop()
        rig.capture.emitLate(.signal)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.session.phase == .finalizing)
        #expect(rig.sounds.played == [.start, .stop])
        #expect(rig.presentation.lives == 1)
        _ = try rig.session.cancel()
    }

    @Test func aBatchOnlyModeOnACloudEngineReadsNoKeyForALiveStreamItDoesNotHave() async throws {
        let rig = try TSRig(mode: .testBatchCloud, key: false)
        try await rig.record()
        try await rig.stopAndSettle()
        // Today's behavior: with no batch transcriber to run, the take says the engine was unreachable.
        #expect(rig.finishedRemark == TakeRemarks.unreachable)
    }

    @Test func aLiveStreamLossWhileRecordingTellsTheStripWhatWillHappen() async throws {
        let withBatch = try TSRig()
        let live = TSFakeLive(.hang)
        withBatch.kit.queue(live)
        withBatch.kit.setBatch("gemini-batch", TSFakeBatch(.text("x")))
        try await withBatch.record()
        live.emit(.streamLost("socket closed"))
        try #require(await withBatch.until { !withBatch.presentation.streamLosts.isEmpty })
        #expect(withBatch.presentation.streamLosts == [TakeRemarks.streamDroppedRecording])
        _ = try withBatch.session.cancel()

        let noBatch = try TSRig(mode: VizierConfig.Mode(
            id: "nofallback", name: "NoFallback",
            transcriber: .init(engine: "gemini-live", model: "m", mode: "verbatim", languages: ["en-US"], finalTimeoutMs: 1_000)))
        let live2 = TSFakeLive(.hang)
        noBatch.kit.queue(live2)
        try await noBatch.record()
        live2.emit(.streamLost("socket closed"))
        try #require(await noBatch.until { !noBatch.presentation.streamLosts.isEmpty })
        #expect(noBatch.presentation.streamLosts == [TakeRemarks.streamDroppedNoBatch])
        _ = try noBatch.session.cancel()
    }

    @Test func theSpeechModelClassificationComesFromThePlatform() async throws {
        let check = SpeechModelCheck(
            streamLostMeansModelMissing: { $0 == "model absent" },
            batchErrorMeansModelMissing: { ($0 as NSError).domain == "model absent" })
        let stream = try TSRig(speech: check)
        let live = TSFakeLive(.hang)
        stream.kit.queue(live)
        stream.kit.setBatch("gemini-batch", TSFakeBatch(.text("x")))
        try await stream.record()
        live.emit(.streamLost("model absent"))
        try #require(await stream.until { !stream.presentation.streamLosts.isEmpty })
        #expect(stream.presentation.streamLosts == [TakeRemarks.mac.speechModelMissing])
        _ = try stream.session.cancel()

        let batch = try TSRig(speech: check)
        batch.kit.queue(TSFakeLive(.fail(.timedOut)))
        batch.kit.setBatch("gemini-batch", TSFakeBatch(.failAny("model absent")))
        try await batch.record()
        try await batch.stopAndSettle()
        #expect(batch.finishedRemark == TakeRemarks.mac.speechModelMissing)
    }

    // MARK: Commands (amendment A2)

    @Test func theCommandsRefuseWhatTheStateForbidsAndChangeNothingWhenRefused() async throws {
        let rig = try TSRig()
        let live = TSFakeLive(.hang)
        rig.kit.queue(live)
        #expect(throws: TakeCommandError.notRecording) { try rig.session.stop() }
        #expect(throws: TakeCommandError.notRecording) { try rig.session.cancel() }
        let started = try rig.session.start()
        #expect(started.phase == .arming)
        #expect(throws: TakeCommandError.alreadyRecording) { try rig.session.start() }
        rig.capture.feed(seconds: 0.5)
        try #require(await rig.until { rig.session.phase == .recording })
        let stopped = try rig.session.toggle()
        #expect(stopped.phase == .finalizing)
        #expect(throws: TakeCommandError.busyFinalizing) { try rig.session.toggle() }
        #expect(throws: TakeCommandError.busyFinalizing) { try rig.session.start() }
        #expect(throws: TakeCommandError.busyFinalizing) { try rig.session.stop() }
        #expect(rig.session.status().phase == .finalizing)
        #expect(!rig.session.acceptsToggle && rig.session.isCancelable)
        let cancelled = try rig.session.cancel()
        #expect(cancelled.phase == .idle)
        #expect(cancelled.lastEnding?.result == .cancelled)
    }

    @Test func aToggleStartsAndThenStopsAndStopDoesNotWaitForDelivery() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.hang))
        let first = try rig.session.toggle()
        #expect(first.phase == .arming && first.takeID != nil)
        let second = try rig.session.toggle()
        #expect(second.phase == .finalizing)
        #expect(rig.paster.pasted.isEmpty)
        _ = try rig.session.cancel()
    }

    @Test func commandsBeforeRecoveryFinishedAreRefused() async throws {
        let rig = try TSRig(ready: false)
        #expect(!rig.session.isReady)
        #expect(throws: TakeCommandError.startupNotReady) { try rig.session.start() }
        #expect(throws: TakeCommandError.startupNotReady) { try rig.session.toggle() }
        #expect(throws: TakeCommandError.startupNotReady) { try rig.session.stop() }
        #expect(throws: TakeCommandError.startupNotReady) { try rig.session.cancel() }
        await rig.session.recoverUnfinishedTakes().value
        #expect(rig.session.isReady)
        rig.kit.queue(TSFakeLive(.hang))
        #expect(try rig.session.start().phase == .arming)
        _ = try rig.session.cancel()
    }

    // MARK: Shutdown

    @Test func quiescingWhileRecordingStopsTheTakeSavesItsAudioAndRefusesNewTakes() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.final("shutdown words")))
        let id = try await rig.record()
        let drained = await rig.session.quiesce(until: .now + .seconds(5))

        #expect(drained)
        #expect(rig.session.phase == .idle)
        #expect(rig.presentation.finishes.count == 1 && rig.presentation.finishes[0].result == .pasted)
        #expect(rig.sounds.played == [.start, .stop])
        let record = try rig.row(id)
        #expect(record.outcome == .pasted)
        #expect(record.audioPath?.pathExtension == "flac")
        #expect(FileManager.default.fileExists(atPath: try #require(record.audioPath).path))
        #expect(throws: TakeCommandError.startupNotReady) { try rig.session.start() }
        #expect(throws: TakeCommandError.startupNotReady) { try rig.session.toggle() }
    }

    @Test func quiescingWhileFinalizingLetsTheDeliveryFinish() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.fail(.timedOut)))
        let gate = TSGate()
        rig.kit.setBatch("gemini-batch", TSFakeBatch(.text("late batch words"), gate: gate))
        let id = try await rig.record()
        _ = try rig.session.stop()
        try #require(await rig.until { rig.presentation.rerouting == 1 })
        let quiesce = Task { await rig.session.quiesce(until: .now + .seconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()

        #expect(await quiesce.value)
        #expect(rig.paster.sent == ["late batch words "])
        #expect(try rig.row(id).outcome == .rerouted)
        #expect(rig.presentation.finishes.count == 1 && rig.presentation.finishes[0].result == .rerouted(.batch))
    }

    @Test func quiescingPastTheDeadlineReportsWhatIsStillInFlightAndLeavesTheTakeAlone() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.fail(.timedOut)))
        let gate = TSGate()
        rig.kit.setBatch("gemini-batch", TSFakeBatch(.text("never in time"), gate: gate))
        let id = try await rig.record()
        _ = try rig.session.stop()
        try #require(await rig.until { rig.presentation.rerouting == 1 })
        let started = ContinuousClock.now
        let drained = await rig.session.quiesce(until: .now + .milliseconds(200))

        #expect(!drained)
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(rig.session.phase == .finalizing)
        #expect(rig.presentation.finishes.isEmpty)
        await gate.open()
        await rig.session.settled()
        #expect(try rig.row(id).outcome == .rerouted)
    }

    @Test func quiescingWaitsForACancelledEarlierDeliveryNotJustTheLatestOne() async throws {
        let rig = try TSRig()
        // Take A's batch is held open; A is cancelled but its delivery task is still suspended.
        rig.kit.queue(TSFakeLive(.fail(.timedOut)))
        let gate = TSGate()
        rig.kit.setBatch("gemini-batch", TSFakeBatch(.text("a, late"), gate: gate))
        try await rig.record()
        _ = try rig.session.stop()
        try #require(await rig.until { rig.presentation.rerouting == 1 })
        _ = try rig.session.cancel()
        // Take B runs to completion meanwhile.
        rig.kit.queue(TSFakeLive(.final("b words")))
        try await rig.record()
        _ = try rig.session.stop()
        try #require(await rig.until { rig.paster.sent == ["b words "] })
        try await Task.sleep(for: .milliseconds(50))

        let drained = await rig.session.quiesce(until: .now + .milliseconds(300))
        #expect(!drained, "A's delivery is still suspended")
        await gate.open()
        #expect(await rig.session.quiesce(until: .now + .seconds(10)))
    }

    @Test func quiescingWaitsForCrashRecoveryToFinish() async throws {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let samples = (0..<(16_000 * 20)).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16_000) * 8_000) }
        nonisolated(unsafe) var open: [any RecordingFile] = []
        let rig = try TSRig(ready: false, seed: { takes, databaseURL in
            let files = try takes.newTake(startedAt: started)
            let earlier = try HistoryStore(databaseURL: databaseURL, takesRoot: takes.root)
            try earlier.begin(TakeDraft(
                id: files.id, startedAt: started, destinationAtStart: nil, modeID: "cloud",
                transcriberEngine: "gemini-live", transcriberModel: "m", fallbackEngine: nil, fallbackModel: nil, cleanerEngine: nil, cleanerModel: nil))
            let file = try TakeStore.createRecordingFile(files)
            try samples.withUnsafeBufferPointer { try file.append($0) }
            open.append(file)
        })
        let recovery = rig.session.recoverUnfinishedTakes()
        // Recovery is under way (the main actor has not yielded since it started).
        #expect(!(await rig.session.quiesce(until: .now)), "recovery is still running at the deadline")
        #expect(await rig.session.quiesce(until: .now + .seconds(20)))
        #expect(rig.session.isReady)
        await recovery.value
        for file in open { try? file.close() }
    }

    @Test func quiescingAnIdleSessionReturnsAtOnceAndStillRefusesNewTakes() async throws {
        let rig = try TSRig()
        #expect(await rig.session.quiesce(until: .now + .seconds(1)))
        #expect(throws: TakeCommandError.startupNotReady) { try rig.session.start() }
        #expect(throws: TakeCommandError.notRecording) { try rig.session.cancel() }
    }

    @Test func warmingUpPreparesTheCapture() throws {
        let rig = try TSRig()
        rig.session.warmUpCapture()
        #expect(rig.capture.prepareCount == 1)
    }

    // MARK: Recovery

    @Test func recoveryEncodesACrashedRecordingAndPointsItsRowAtTheFlac() async throws {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let samples = (0..<16_000).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16_000) * 8_000) }
        nonisolated(unsafe) var crashed: (files: TakeFiles, file: any RecordingFile)?
        let rig = try TSRig(ready: false, seed: { takes, databaseURL in
            let files = try takes.newTake(startedAt: started)
            let earlier = try HistoryStore(databaseURL: databaseURL, takesRoot: takes.root)
            try earlier.begin(TakeDraft(
                id: files.id, startedAt: started, destinationAtStart: nil, modeID: "cloud",
                transcriberEngine: "gemini-live", transcriberModel: "m", fallbackEngine: nil, fallbackModel: nil, cleanerEngine: nil, cleanerModel: nil))
            let file = try TakeStore.createRecordingFile(files)
            try samples.withUnsafeBufferPointer { try file.append($0) }
            crashed = (files, file)  // The process "died": the recording is never closed.
        })
        let files = try #require(crashed).files
        #expect(FileManager.default.fileExists(atPath: files.recording.path))

        await rig.session.recoverUnfinishedTakes().value

        #expect(rig.session.isReady)
        #expect(!FileManager.default.fileExists(atPath: files.recording.path))
        #expect(FileManager.default.fileExists(atPath: files.flac.path))
        let record = try rig.row(files.id)
        #expect(record.outcome == .failed)
        #expect(record.audioPath?.lastPathComponent == files.flac.lastPathComponent)
        #expect(abs(Double(try #require(record.durationMs)) - 1_000) < 5)
        try? crashed?.file.close()
    }

    // MARK: Failures

    @Test func deniedMicrophoneAccessStopsTheTakeBeforeItRecordsAndWritesNoRow() async throws {
        let rig = try TSRig()
        rig.mic.denied = true
        let status = try rig.session.start()
        #expect(status.phase == .idle && status.takeID == nil)
        #expect(rig.presentation.finishes.count == 1 && rig.presentation.finishes[0].result == .failed)
        #expect(rig.finishedRemark == "Vizier does not have microphone access, so nothing was recorded. Turn it on in System Settings › Privacy & Security › Microphone.")
        #expect(rig.presentation.began.count == 1)
        #expect(rig.presentation.alerts == 1)
        #expect(try rig.history.count() == 0)
        #expect(status.lastEnding?.takeID == "")
    }

    @Test func aCaptureThatCannotStartFailsTheTakeAndCancelsItsTranscriber() async throws {
        let rig = try TSRig()
        let live = TSFakeLive(.hang)
        rig.kit.queue(live)
        rig.capture.failNextStart()
        let status = try rig.session.start()
        #expect(status.phase == .idle)
        #expect(live.wasCancelled)
        #expect(rig.finishedRemark == TakeRemarks.micFailed)
        let ending = try #require(status.lastEnding)
        let record = try rig.row(ending.takeID)
        #expect(record.outcome == .failed && record.outcomeReason == TakeRemarks.micFailed)
    }

    @Test func aTakesFolderThatCannotBeCreatedFailsTheTake() async throws {
        let blocker = FileManager.default.temporaryDirectory.appending(path: "vizier-blocker-\(UUID().uuidString)")
        try Data("not a folder".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let rig = try TSRig(takesRoot: blocker.appending(path: "Takes"))
        let status = try rig.session.start()
        #expect(status.phase == .idle)
        #expect(rig.finishedRemark == TakeRemarks.noFolder)
        #expect(rig.presentation.finishes[0].result == .failed)
    }

    @Test func aWriteFailureMidTakeKeepsTheEarlierAudioAndTheTakeStillDelivers() async throws {
        let rig = try TSRig(recordingFactory: { try TSFlakyRecordingFile(TakeStore.createRecordingFile($0), failAppendsFrom: 1) })
        rig.kit.queue(TSFakeLive(.final("words survive")))
        let id = try await rig.record(seconds: 1)
        rig.capture.feed(seconds: 1)
        try await rig.stopAndSettle()

        #expect(rig.paster.pasted == ["words survive "])
        let record = try rig.row(id)
        #expect(record.outcome == .pasted)
        #expect(record.audioPath?.pathExtension == "flac")
        #expect(abs(Double(try #require(record.durationMs)) - 1_000) < 5)
    }

    @Test func aCloseFailureKeepsTheRecordingAndTheTakeStillDelivers() async throws {
        let rig = try TSRig(recordingFactory: { try TSFlakyRecordingFile(TakeStore.createRecordingFile($0), failClose: true) })
        rig.kit.queue(TSFakeLive(.final("words survive")))
        let id = try await rig.record(seconds: 1)
        try await rig.stopAndSettle()
        #expect(rig.presentation.finishes.first?.result == .pasted)
        #expect(try rig.row(id).audioPath?.pathExtension == "flac")
    }

    @Test func aTakeThatHeardNothingSaysNoSpeech() async throws {
        let rig = try TSRig()
        rig.kit.queue(TSFakeLive(.final("")))
        try await rig.record()
        try await rig.stopAndSettle()
        #expect(rig.presentation.finishes.first?.result == .failed)
        #expect(rig.finishedRemark == TakeRemarks.noSpeech)
        #expect(rig.paster.pasted.isEmpty)
    }

    // MARK: Wording

    @Test func theMacRemarksAreTheOriginalStringsByteForByte() {
        let mac = TakeRemarks.mac
        #expect(mac.noKey("ElevenLabs") == "There is no ElevenLabs key yet, so nothing was transcribed. Add one in Settings › Accounts. The audio is saved.")
        #expect(mac.speechModelMissing == "The Apple speech model is not ready (it may still be downloading), so nothing was transcribed. Get it in Settings › Transcription › Download speech model. The audio is saved.")
        #expect(mac.offline == "The cloud could not be reached, so this Mac transcribed the saved audio.")
        #expect(mac.micDenied == "Vizier does not have microphone access, so nothing was recorded. Turn it on in System Settings › Privacy & Security › Microphone.")
        #expect(mac.pasteFailed() == "The paste did not go through. The text is on the clipboard; ⌘V pastes it.")
        #expect(mac.permissionMissing() == "Vizier does not have Accessibility access, so nothing was pasted. Turn it on in System Settings › Privacy & Security › Accessibility. The text is on the clipboard; ⌘V pastes it.")
        #expect(mac.noPasteTarget() == "No text field had focus, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
        #expect(mac.vizierHadFocus() == "Vizier itself had focus, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
        #expect(mac.focusMoved() == "You switched apps after the take stopped, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
        #expect(mac.secureField() == "A password field had focus, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
        #expect(mac.secureInput() == "Secure input was on and the focused field could not be read, so nothing was pasted. The text is on the clipboard; ⌘V pastes it.")
        #expect(TakeRemarks.streamDroppedRecording == "The live stream dropped. Audio is still recording and will go through batch when you stop.")
        #expect(TakeRemarks.streamDroppedNoBatch == "The live stream dropped. Audio is still recording and will be saved when you stop.")
        #expect(TakeRemarks.streamDropped == "The live stream dropped, so the saved audio went through batch.")
        #expect(TakeRemarks.finalLate == "The live transcript did not finish in time, so the saved audio went through batch.")
        #expect(TakeRemarks.unreachable == "The engine could not be reached. The audio is saved.")
        #expect(TakeRemarks.localDown == "Local whisper did not answer. Is its server running? The audio is saved.")
        #expect(TakeRemarks.noSpeech == "No speech came through. The audio is saved.")
        #expect(TakeRemarks.noFlac == "The live transcript failed and the audio could not be prepared for batch. The recording is saved.")
        #expect(TakeRemarks.noAudio == "The mic never delivered audio. Check the input device.")
        #expect(TakeRemarks.micFailed == "The mic could not start. Check the input device.")
        #expect(TakeRemarks.noFolder == "The take could not be saved, so nothing was recorded.")
        #expect(TakeRemarks.cleanupLate == "The cleanup pass did not finish in time, so the raw transcript was pasted.")
        #expect(TakeRemarks.cleanupFailed == "The cleanup pass failed, so the raw transcript was pasted.")
        #expect(TakeRemarks.cleanupDropped == "The cleanup pass dropped too many words to trust, so the raw transcript was pasted.")
        #expect(TakeRemarks.cleanupAdded == "The cleanup pass added words, so the raw transcript was pasted.")
        #expect(TakeRemarks.settledWords == "The live transcript did not finish, so the settled words were pasted.")
        #expect(TakeRemarks.batchTooLong == "The take is longer than the batch model's one-hour limit, so it was not sent to batch. The audio is saved.")
        #expect(TakeRemarks.batchTruncated == "The batch transcript hit the model's output limit and may be cut off.")
        #expect(TakeRemarks.batchRepeated(words: 900, durationMs: 60_000) == "The batch transcript has 900 words for 60 seconds of audio, so it may contain repeated text.")
        #expect(TakeRemarks.batchRepeated(words: 900, durationMs: 180_000) == "The batch transcript has 900 words for 3 minutes of audio, so it may contain repeated text.")
    }

    @Test func theLinuxRemarksNameLinuxThings() {
        let linux = TakeRemarks.linux
        #expect(linux.noKey("Gemini") == "There is no Gemini key yet, so nothing was transcribed. Add one with `vizier key set <name>`. The audio is saved.")
        #expect(linux.offline.contains("this computer"))
        #expect(linux.pasteFailed().contains("Ctrl+V"))
        for text in [linux.noKey("Gemini"), linux.offline, linux.micDenied, linux.pasteFailed(), linux.permissionMissing(), linux.focusMoved(), linux.noPasteTarget()] {
            #expect(!text.contains("Mac") && !text.contains("⌘") && !text.contains("Settings ›"), "\(text)")
        }
        for text in [linux.pasteFailed(onClipboard: false), linux.permissionMissing(onClipboard: false), linux.secureField(onClipboard: false)] {
            #expect(!text.contains("clipboard") && text.contains("`vizier last`"), "\(text)")
        }
    }
}
