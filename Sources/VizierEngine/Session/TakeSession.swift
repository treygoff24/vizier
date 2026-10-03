import Foundation
#if canImport(os)
import os
#endif

/// Neutral classification of the Apple speech engine's failures, supplied by the platform so the
/// session never names an Apple type. Where no such engine exists (Linux) nothing matches.
public struct SpeechModelCheck: Sendable {
    /// A live stream's `streamLost` reason says the on-device speech model is not installed.
    public var streamLostMeansModelMissing: @Sendable (String) -> Bool
    /// A batch link's error says the same.
    public var batchErrorMeansModelMissing: @Sendable (any Error) -> Bool

    public init(
        streamLostMeansModelMissing: @escaping @Sendable (String) -> Bool,
        batchErrorMeansModelMissing: @escaping @Sendable (any Error) -> Bool
    ) {
        self.streamLostMeansModelMissing = streamLostMeansModelMissing
        self.batchErrorMeansModelMissing = batchErrorMeansModelMissing
    }

    public static let none = SpeechModelCheck(streamLostMeansModelMissing: { _ in false }, batchErrorMeansModelMissing: { _ in false })
}

/// Builds a take's transcribers and cleanup pass. `standard` is `Engines`; a test swaps in fakes.
public struct TakeEngines: Sendable {
    public var live: @Sendable (VizierConfig.Transcriber, [String], String?) -> (any LiveTranscriber)?
    public var batch: @Sendable (VizierConfig.Fallback, [String], [String], String?) -> (any BatchTranscriber)?
    public var cleaner: @Sendable (VizierConfig.Cleanup, [String], VizierConfig, String?) -> (any TextCleaner)?

    public init(
        live: @escaping @Sendable (VizierConfig.Transcriber, [String], String?) -> (any LiveTranscriber)?,
        batch: @escaping @Sendable (VizierConfig.Fallback, [String], [String], String?) -> (any BatchTranscriber)?,
        cleaner: @escaping @Sendable (VizierConfig.Cleanup, [String], VizierConfig, String?) -> (any TextCleaner)?
    ) {
        self.live = live
        self.batch = batch
        self.cleaner = cleaner
    }

    public static let standard = TakeEngines(
        live: { Engines.live($0, vocabulary: $1, key: $2) },
        batch: { Engines.batch($0, languages: $1, vocabulary: $2, key: $3) },
        cleaner: { Engines.cleaner($0, languages: $1, config: $2, key: $3) })
}

/// Owns the take lifecycle: start on a tap, stop on the next, cancel on Escape. Every take keeps
/// its audio, canceled ones included; the live transcript is pasted when a take stops. Each take's
/// `TakeLedger` writes its history row at every stage, before any point where the take can end.
///
/// This is the macOS app's `TakeController` orchestration moved into the engine so the Mac app and
/// the Linux daemon run the same state machine. Everything platform-specific arrives through the
/// collaborators handed to `init`.
@MainActor
public final class TakeSession: TakeControl {
    /// Finalizing reads DELAYED past 1 s (DESIGN.md). A mode with a cleanup pass gets this much
    /// longer, since cleanup is part of its normal path: a Flash-Lite pass takes 0.6 to 1.4 s, and
    /// the slowest release-to-text measured was 2.45 s.
    public static let cleanupAllowance: TimeInterval = 1.5
    /// A Local take is transcribed after the stop: 0.8 to 2.0 s for takes of 13 to 43 s.
    public static let localAllowance: TimeInterval = 2.5
    /// The local cleanup model took 0.6 s on short takes and 3 to 5 s past 100 words.
    public static let localCleanupAllowance: TimeInterval = 4

    public private(set) var phase = TakePhase.idle {
        didSet { if phase != oldValue { presentation.phaseChanged(phase) } }
    }

    /// Times the take's stop and paste, so a typed Cmd+V near them can be logged.
    public var pasteWatch = TypedPasteWatch()
    /// Set only while onboarding's Practice step is on screen: a finished take's text goes here
    /// instead of being pasted, since Vizier never pastes into itself. Everywhere else it is nil.
    public var practiceSink: ((String) -> Void)?

    /// The current take's words, for the strip.
    public private(set) var words = WordLine()

    /// False until recovery of crashed takes has finished (or `markReady()`); commands before that
    /// are refused with `startupNotReady`.
    public private(set) var isReady = false

    private struct Take {
        let files: TakeFiles
        let modeID: String
        let transcriber: (any LiveTranscriber)?
        /// The provider whose key was missing when the live transcriber couldn't be made.
        let missingKey: String?
        /// The saved audio's transcribers, tried in order when there is no live final.
        let batches: [BatchChain.Link]
        /// The mode has no live stream: the first batch link is its normal path, not a reroute.
        let batchOnly: Bool
        let cleanup: Cleanup?
        let removeFillers: Bool
        let replacer: WordReplacer?
        let startedAt: TimeInterval
        let ledger: TakeLedger
        let live: LiveText
    }

    /// The settled live words across the whole take. A reference, so `deliver` still has them
    /// after a cancel resets the session.
    private final class LiveText {
        var settled = SettledTranscript()
    }

    /// A take's saved audio: the FLAC, or the recording when FLAC failed.
    private struct SavedAudio: Sendable {
        let url: URL
        let isFLAC: Bool
        let byteCount: Int64
        let durationMs: Int

        /// Duration from the file's header; `fallbackSeconds` when the file can't be read.
        static func measure(_ url: URL, isFLAC: Bool, fallbackSeconds: Double) -> SavedAudio {
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            let seconds = TakeStore.duration(of: url) ?? fallbackSeconds
            return SavedAudio(url: url, isFLAC: isFLAC, byteCount: bytes, durationMs: Int((seconds * 1000).rounded()))
        }
    }

    private typealias Provider = Engines.KeyAccount

    private struct Cleanup {
        let cleaner: any TextCleaner
        let model: String
        let timeout: Duration
        /// Runs on this machine, which takes longer than a cloud pass on a long take.
        let local: Bool
    }

    private let config: ConfigStore
    private let store: TakeStore
    private let recorder: TakeRecorder
    /// Nil when history could not open; takes still run, and each ledger writes nothing.
    private let history: HistoryStore?
    private let secrets: any SecretStore
    private let presentation: any TakePresentation
    private let sounds: any SoundPlayer
    private let microphone: any MicPermission
    private let focus: any FocusProbe
    private let paster: any PasteService
    private let remarks: TakeRemarks
    private let speech: SpeechModelCheck
    private let engines: TakeEngines
    private let log: Logger

    private var take: Take?
    /// Every take's delivery by take id, removed as each completes; a drain awaits all of them.
    private var deliveries: [String: Task<Void, Never>] = [:]
    /// The crash-recovery pass, until it finishes.
    private var recovery: Task<Void, Never>?
    private var isQuiescing = false
    private var audioTasks: [String: Task<SavedAudio?, Never>] = [:]
    private var lastEnding: TakeEnding?

    public init(
        config: ConfigStore, store: TakeStore, recorder: TakeRecorder, history: HistoryStore?, secrets: any SecretStore,
        presentation: any TakePresentation, sounds: any SoundPlayer, microphone: any MicPermission, focus: any FocusProbe,
        paster: any PasteService, remarks: TakeRemarks, speech: SpeechModelCheck = .none, engines: TakeEngines = .standard,
        log: Logger = Logger(subsystem: "net.praxient.dictum", category: "take")
    ) {
        self.config = config
        self.store = store
        self.recorder = recorder
        self.history = history
        self.secrets = secrets
        self.presentation = presentation
        self.sounds = sounds
        self.microphone = microphone
        self.focus = focus
        self.paster = paster
        self.remarks = remarks
        self.speech = speech
        self.engines = engines
        self.log = log
    }

    /// Readies the mic so the first take after launch doesn't lose its opening words. Call once
    /// mic access is granted; a take started meanwhile waits for it and uses the readied unit.
    public func warmUpCapture() {
        recorder.warmUp()
    }

    public var isCancelable: Bool { phase != .idle }
    public var acceptsToggle: Bool { phase != .finalizing }

    /// Lets commands through without a recovery pass (the Mac app lists leftovers itself and has
    /// never made the hotkey wait for the repair).
    public func markReady() {
        isReady = true
    }

    /// Waits for every delivery, the crash recovery, and every audio save to finish.
    public func settled() async {
        for task in Array(deliveries.values) { await task.value }
        await recovery?.value
        for task in Array(audioTasks.values) { _ = await task.value }
    }

    private var hasWorkInFlight: Bool { !deliveries.isEmpty || recovery != nil || !audioTasks.isEmpty }

    public func quiesce(until deadline: ContinuousClock.Instant) async -> Bool {
        isQuiescing = true
        // Stopped, not cancelled: the audio is saved and the take delivers like any other.
        if take != nil, phase == .arming || phase == .recording {
            stop(releasedAt: ProcessInfo.processInfo.systemUptime)
        }
        guard hasWorkInFlight else { return true }
        // A deadline already passed with work still running is a timeout, decided here rather
        // than by racing a timer task against the work.
        guard ContinuousClock.now < deadline else { return false }
        let race = DrainRace()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            race.continuation = continuation
            let timeout = Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                race.finish(false)
            }
            Task {
                await settled()
                timeout.cancel()
                race.finish(true)
            }
        }
    }

    /// Resumes `quiesce` once: with true when everything drained, false at the deadline.
    @MainActor private final class DrainRace {
        var continuation: CheckedContinuation<Bool, Never>?

        func finish(_ drained: Bool) {
            continuation?.resume(returning: drained)
            continuation = nil
        }
    }

    // MARK: TakeControl (amendment A2)

    public func toggle() throws(TakeCommandError) -> TakeStatus {
        try toggle(at: ProcessInfo.processInfo.systemUptime)
    }

    /// `time` is the key-down's `systemUptime`; the stop's latency figures count from it.
    public func toggle(at time: TimeInterval) throws(TakeCommandError) -> TakeStatus {
        guard isReady else { throw .startupNotReady }
        switch phase {
        case .idle:
            guard !isQuiescing else { throw .startupNotReady }
            start(releasedAt: time)
        case .finalizing: throw .busyFinalizing
        case .arming, .recording: stop(releasedAt: time)
        }
        return status()
    }

    public func start() throws(TakeCommandError) -> TakeStatus {
        guard isReady else { throw .startupNotReady }
        switch phase {
        case .idle:
            guard !isQuiescing else { throw .startupNotReady }
            start(releasedAt: ProcessInfo.processInfo.systemUptime)
        case .finalizing: throw .busyFinalizing
        case .arming, .recording: throw .alreadyRecording
        }
        return status()
    }

    public func stop() throws(TakeCommandError) -> TakeStatus {
        guard isReady else { throw .startupNotReady }
        switch phase {
        case .idle: throw .notRecording
        case .finalizing: throw .busyFinalizing
        case .arming, .recording: stop(releasedAt: ProcessInfo.processInfo.systemUptime)
        }
        return status()
    }

    public func cancel() throws(TakeCommandError) -> TakeStatus {
        guard isReady else { throw .startupNotReady }
        guard take != nil, phase != .idle else { throw .notRecording }
        cancelTake()
        return status()
    }

    public func status() -> TakeStatus {
        if let take, phase != .idle {
            return TakeStatus(phase: phase, takeID: take.files.id, seconds: recorder.capturedSeconds, mode: take.modeID, lastEnding: lastEnding)
        }
        return TakeStatus(phase: .idle, takeID: nil, seconds: 0, mode: config.load().config.activeMode.id, lastEnding: lastEnding)
    }

    // MARK: Cancel

    private func cancelTake() {
        guard let take, phase != .idle else { return }
        if phase != .finalizing {
            let summary = recorder.stop()
            saveAudio(take.files, ledger: take.ledger, capturedSeconds: summary.seconds)
        }
        sounds.play(.cancel)
        take.transcriber?.cancel()
        // A cancel while recording has no final, so the words the strip had settled are the only
        // transcript this take will get; history keeps them beside the audio.
        if let settled = take.live.settled.standIn(for: nil) {
            take.ledger.transcript(raw: settled, route: "live", transcriptionMs: nil)
        }
        take.ledger.cancel()
        pasteWatch.endedWithoutPaste()
        log.notice("take \(take.files.id, privacy: .public) cancelled after \(self.recorder.capturedSeconds, format: .fixed(precision: 2), privacy: .public) s")
        present(.cancelled, remark: nil, takeID: take.files.id)
        end()
    }

    // MARK: Recovery

    /// Repairs history from the files on disk (rows for orphaned audio, rows left open closed as
    /// failed), then encodes recordings a crash left behind and points their rows at the FLAC, so
    /// no take stays half-saved or unlisted. Deletes no audio. The returned task finishes when the
    /// repair has, and marks the session ready.
    ///
    /// The leftovers are listed here, on the main actor, before the hotkey can start a take: a
    /// recording that starts later is never picked up and encoded out from under its recorder.
    @discardableResult
    public func recoverUnfinishedTakes() -> Task<Void, Never> {
        let store = store
        let history = history
        let log = log
        let leftovers = store.unfinishedTakes()
        let work = Task.detached(priority: .utility) {
            if let history {
                do {
                    try history.reconcileFiles()
                } catch {
                    log.error("could not reconcile history with the takes folder: \(String(describing: error), privacy: .private)")
                }
            }
            for take in leftovers {
                do {
                    let flac = try store.finishAudio(take)
                    log.notice("recovered take \(take.id, privacy: .public)")
                    guard let history else { continue }
                    let saved = SavedAudio.measure(flac, isFLAC: true, fallbackSeconds: 0)
                    do {
                        try history.setAudio(id: take.id, path: flac, byteCount: saved.byteCount, durationMs: saved.durationMs)
                    } catch {
                        log.error("could not point history at recovered take \(take.id, privacy: .public): \(String(describing: error), privacy: .private)")
                    }
                } catch {
                    log.error("could not recover take \(take.id, privacy: .public): \(String(describing: error), privacy: .private)")
                }
            }
        }
        let finished = Task { [weak self] in
            await work.value
            self?.isReady = true
            self?.recovery = nil
        }
        recovery = finished
        return finished
    }

    // MARK: Start

    private func start(releasedAt: TimeInterval) {
        let load = config.load()
        for error in load.errors {
            log.error("config: \(error.publicSummary, privacy: .public); running the last good config")
            log.error("config detail: \(error.description, privacy: .private)")
        }
        if !load.errors.isEmpty { presentation.raiseAlert() }

        // With microphone access denied the recorder would capture silence: say so instead.
        if microphone.microphoneDenied() {
            log.error("take did not start: microphone access is denied")
            postBoard(load.config)
            fail(remarks.micDenied, ledger: nil)
            return
        }

        let files: TakeFiles
        let startedAt = Date.now
        do {
            files = try store.newTake(startedAt: startedAt)
        } catch {
            log.error("take did not start: \(String(describing: error), privacy: .private)")
            postBoard(load.config)
            fail(TakeRemarks.noFolder, ledger: nil)
            return
        }
        let id = files.id
        let mode = load.config.activeMode
        let destination = focus.destinationName()
        let draft = TakeDraft(
            id: id, startedAt: startedAt, destinationAtStart: destination.isEmpty ? nil : destination, modeID: mode.id,
            transcriberEngine: mode.transcriber.engine, transcriberModel: mode.transcriber.model,
            fallbackEngine: mode.fallback?.engine, fallbackModel: mode.fallback?.model,
            cleanerEngine: mode.cleanup?.engine, cleanerModel: mode.cleanup?.model)
        // A batch-only mode (Local) has no live stream and reads no key for one; an Apple engine needs none.
        let liveProvider = mode.isBatchOnly ? nil : Engines.keyAccount(for: mode.transcriber.engine)
        let liveKey = liveProvider.flatMap { key($0) }
        // A second secret-store read only when a batch link or cleanup is another provider's; none for a local engine.
        func keyFor(_ engine: String) -> String? {
            guard let provider = Engines.keyAccount(for: engine) else { return nil }
            return provider.account == liveProvider?.account ? liveKey : key(provider)
        }
        let makeBatch = engines.batch
        let makeCleaner = engines.cleaner
        let batches = mode.batchChain.compactMap { spec in
            makeBatch(spec, mode.transcriber.languages, load.config.vocabulary, keyFor(spec.engine))
                .map { BatchChain.Link(engine: spec.engine, transcriber: $0) }
        }
        let cleanup = mode.cleanup.flatMap { pass in
            makeCleaner(pass, mode.transcriber.languages, load.config, keyFor(pass.engine))
                .map { Cleanup(cleaner: $0, model: pass.model, timeout: .milliseconds(pass.timeoutMs), local: Engines.keyAccount(for: pass.engine) == nil) }
        }
        // A keyless engine (Apple) starts with no key; a cloud engine starts only when its key was found.
        let transcriber = Engines.liveTranscriber(for: mode, vocabulary: load.config.vocabulary, key: liveKey, make: engines.live)
        transcriber?.start(onEvent: { [weak self] event in
            Task { @MainActor in self?.transcriptEvent(event, take: id) }
        })
        do {
            try recorder.start(files, onChunk: { chunk in transcriber?.send(chunk) }, onEvent: { [weak self] event in
                Task { @MainActor in self?.captureEvent(event) }
            })
        } catch {
            transcriber?.cancel()
            log.error("take did not start: \(String(describing: error), privacy: .private)")
            postBoard(load.config)
            fail(TakeRemarks.micFailed, ledger: TakeLedger(store: history, draft: draft), takeID: id)
            return
        }
        // The mic starts before the board: a clipped first syllable costs more than a strip that
        // posts a frame later. The history row's first write waits for the mic for the same reason.
        let ledger = TakeLedger(store: history, draft: draft)
        postBoard(load.config)
        take = Take(
            files: files, modeID: mode.id, transcriber: transcriber, missingKey: liveKey == nil ? liveProvider?.name : nil,
            batches: batches, batchOnly: mode.isBatchOnly,
            cleanup: cleanup, removeFillers: FillerFilter.applies(to: mode),
            replacer: makeReplacer(load.config), startedAt: releasedAt, ledger: ledger, live: LiveText())
        words = WordLine()
        phase = .arming
        log.notice("take \(id, privacy: .public) started \(Self.ms(ProcessInfo.processInfo.systemUptime - releasedAt), privacy: .public) ms after the key-down")
    }

    private func postBoard(_ config: VizierConfig) {
        let recorder = recorder
        presentation.begin(
            destination: focus.destinationName(), platform: HistoryBoard.platformCode(config.activeMode.name),
            level: { recorder.capture.meanSquare }, seconds: { recorder.capturedSeconds })
    }

    /// Read per take, so a key seeded while Vizier runs is picked up on the next take.
    private func key(_ provider: Provider) -> String? {
        do {
            if let key = try secrets.read(provider.account) { return key }
            log.error("no \(provider.name, privacy: .public) key found; \(self.remarks.addKeyHint, privacy: .public)")
        } catch {
            log.error("could not read the \(provider.name, privacy: .public) key: \(String(describing: error), privacy: .private)")
        }
        presentation.raiseAlert()
        return nil
    }

    private func makeReplacer(_ config: VizierConfig) -> WordReplacer? {
        do {
            return try WordReplacer(rules: config.replacements)
        } catch {
            log.error("word replacements are off for this take: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private func captureEvent(_ event: CaptureEvent) {
        switch event {
        case .signal:
            guard phase == .arming, let take else { return }
            phase = .recording
            presentation.setLive()
            // On the first real audio, not the tap: the ping means the mic is actually listening.
            sounds.play(.start)
            let delay = ProcessInfo.processInfo.systemUptime - take.startedAt
            log.notice("first signal \(delay * 1000, format: .fixed(precision: 0), privacy: .public) ms after the tap")
        case .deviceSwitched(let name):
            log.notice("capture moved to \(name, privacy: .private)")
        case .deviceSwitchFailed(let reason):
            log.error("capture could not follow the input change: \(reason, privacy: .private)")
        case .failed(let reason):
            log.error("capture ended by itself: \(reason, privacy: .private)")
        }
    }

    private func transcriptEvent(_ event: LiveTranscriberEvent, take id: String) {
        guard take?.files.id == id else { return }
        switch event {
        case .transcript(let settled, let pending):
            take?.live.settled.update(settled: settled, pending: pending)
            words.update(settled: settled, pending: pending)
            presentation.setWords(words.plates)
        case .streamLost(let reason):
            log.error("take \(id, privacy: .public) lost its live stream: \(reason, privacy: .private)")
            if phase == .arming || phase == .recording {
                if speech.streamLostMeansModelMissing(reason) {
                    presentation.streamLost(remark: remarks.speechModelMissing)
                } else {
                    presentation.streamLost(remark: take?.batches.isEmpty != false ? TakeRemarks.streamDroppedNoBatch : TakeRemarks.streamDroppedRecording)
                }
            }
        }
    }

    // MARK: Stop

    private func stop(releasedAt: TimeInterval) {
        guard let take else { return }
        // Where the user is at the stop tap; the paste goes nowhere else.
        // Started now (capture still stops at once); delivery awaits the answer before it pastes.
        let focus = focus
        let appAtStop = Task { await focus.focusAtStop() }
        // Stopping the recorder hands the last partial chunk to the transcriber before finish().
        let summary = recorder.stop()
        sounds.play(.stop)
        let heardSignal = phase != .arming
        phase = .finalizing
        pasteWatch.takeStopped(at: releasedAt)
        presentation.stopped(onTime: (take.batchOnly ? Self.localAllowance : 1) + (take.cleanup.map { $0.local ? Self.localCleanupAllowance : Self.cleanupAllowance } ?? 0))
        log.notice("take \(take.files.id, privacy: .public) stopped: \(summary.seconds, format: .fixed(precision: 2), privacy: .public) s captured, \(summary.capture.deviceSwitches, privacy: .public) input switches, \(summary.capture.droppedBuffers, privacy: .public) dropped buffers, signal \(heardSignal, privacy: .public)")
        if let error = summary.writeError {
            log.error("recording write failed mid-take: \(error, privacy: .private)")
        }
        take.ledger.stopped()
        let audio = saveAudio(take.files, ledger: take.ledger, capturedSeconds: summary.seconds)
        let takeID = take.files.id
        deliveries[takeID] = Task {
            await deliver(take, stoppedAt: releasedAt, appAtStop: appAtStop, heardSignal: heardSignal, audio: audio)
            deliveries[takeID] = nil
        }
    }

    /// Waits for the take's text, cleans it when the mode has a cleanup pass, and pastes it. When
    /// the live final doesn't come, the saved FLAC goes to batch; when batch can't help either, the
    /// settled live words paste; when cleanup doesn't hold, the raw transcript pastes. Latency is
    /// measured from the stop tap's key-up.
    ///
    /// Every text is written to the take's ledger the moment it exists, before any `guard` that
    /// can return: a take cancelled mid-flight keeps the text it had.
    private func deliver(_ take: Take, stoppedAt: TimeInterval, appAtStop: Task<Int32?, Never>, heardSignal: Bool, audio: Task<SavedAudio?, Never>) async {
        let id = take.files.id
        let ledger = take.ledger
        var text: String?
        var route = "live"
        var liveError: TranscriberError?
        var remark = take.missingKey.map(remarks.noKey) ?? TakeRemarks.unreachable
        /// Sentences about how the text was got, shown with any outcome that pastes or holds it.
        var warnings: [String?] = []
        var usedSettledWords = false
        if let transcriber = take.transcriber {
            do {
                let final = try await transcriber.finish()
                text = final
                ledger.transcript(raw: final, route: "live", transcriptionMs: Self.ms(ProcessInfo.processInfo.systemUptime - stoppedAt))
            } catch {
                liveError = error as? TranscriberError
                log.error("take \(id, privacy: .public) has no live final: \(String(describing: error), privacy: .private)")
            }
        }
        var batchTooLong = false
        /// A batch link other than the mode's normal path answered.
        var viaBackup = false
        var offlineAnswered = false
        if text == nil, self.take?.files.id == id, !take.batches.isEmpty {
            if !take.batchOnly { presentation.reroutingToBatch() }
            if let saved = await audio.value, saved.isFLAC {
                if !take.batchOnly { log.notice("take \(id, privacy: .public) re-routed via batch") }
                switch await BatchChain.run(take.batches, audio: saved.url) {
                case .success(let answer):
                    let report = answer.report
                    text = report.transcript
                    route = "batch"
                    viaBackup = !take.batchOnly || answer.index > 0
                    // The offline link is the last one, and it is local: the cloud links before it failed.
                    offlineAnswered = answer.index > 0 && report.route == .local
                    ledger.transcript(raw: report.transcript, route: "batch", transcriptionMs: Self.ms(ProcessInfo.processInfo.systemUptime - stoppedAt))
                    if answer.index > 0 {
                        log.notice("take \(id, privacy: .public) transcribed by \(answer.engine, privacy: .public) after \(answer.index, privacy: .public) batch engines failed")
                    }
                    if offlineAnswered { warnings.append(remarks.offline) }
                    if report.truncated { warnings.append(TakeRemarks.batchTruncated) }
                    if Self.implausiblyWordy(words: report.wordCount, durationMs: saved.durationMs) {
                        log.error("take \(id, privacy: .public) batch returned \(report.wordCount, privacy: .public) words for \(saved.durationMs, privacy: .public) ms of audio")
                        warnings.append(TakeRemarks.batchRepeated(words: report.wordCount, durationMs: saved.durationMs))
                    }
                case .failure(let failure):
                    for (engine, error) in failure.errors {
                        log.error("take \(id, privacy: .public) \(engine, privacy: .public) failed: \(String(describing: error), privacy: .private)")
                    }
                    if failure.errors.contains(where: { speech.batchErrorMeansModelMissing($0.error) }) {
                        remark = remarks.speechModelMissing
                    } else if failure.tooLong {
                        log.error("take \(id, privacy: .public) is too long for batch (\(saved.durationMs / 1000, privacy: .public) s)")
                        remark = TakeRemarks.batchTooLong
                        batchTooLong = true
                    } else if take.batchOnly, take.batches.first?.engine == "local-whisper" {
                        remark = TakeRemarks.localDown
                    }
                }
            } else {
                log.error("take \(id, privacy: .public) has no FLAC for batch")
                remark = TakeRemarks.noFlac
            }
        }
        // Never lose text the strip already showed: with no transcript, or a blank one (a live
        // final or batch answer with no words), the settled live words stand in, even for a take
        // cancelled while it waited. A blank live final is never sent to batch.
        if let settled = take.live.settled.standIn(for: text) {
            text = settled
            route = "live"
            usedSettledWords = true
            warnings = [TakeRemarks.settledWords] + (batchTooLong ? [TakeRemarks.batchTooLong] : [])
            ledger.transcript(raw: settled, route: "live", transcriptionMs: Self.ms(ProcessInfo.processInfo.systemUptime - stoppedAt))
            log.notice("take \(id, privacy: .public) has no final; using its settled live words")
        }
        let finalAt = ProcessInfo.processInfo.systemUptime
        guard self.take?.files.id == id else { return }
        guard let text else {
            log.error("take \(id, privacy: .public) failed; its audio is saved")
            fail(remark, ledger: ledger, takeID: id)
            return
        }
        // Cleanup runs before replacements, so the rules still catch what it missed (TR, CL, RP).
        var cleaned = text
        var cleanupRemark: String?
        var cleanupNote = "no cleanup"
        if let cleanup = take.cleanup, TextCleanup.wordCount(text) > 0 {
            let started = ProcessInfo.processInfo.systemUptime
            let result = await TextCleanup.run(text, cleaner: cleanup.cleaner, timeout: cleanup.timeout)
            let ms = Self.ms(ProcessInfo.processInfo.systemUptime - started)
            switch result {
            case .cleaned(let clean):
                cleaned = clean
                cleanupNote = "cleaned by \(cleanup.model) in \(ms) ms"
                ledger.cleaned(clean, cleanupMs: ms)
            case .raw(let fallback):
                cleanupRemark = TakeRemarks.cleanup(fallback)
                cleanupNote = "raw after \(ms) ms, cleanup \(fallback.publicSummary)"
                log.error("take \(id, privacy: .public) cleanup \(fallback.description, privacy: .private); pasting the raw transcript")
                // The pass ran but produced no cleaned text: record its time, leave the text unset.
                ledger.cleaned(nil, cleanupMs: ms)
            }
            guard self.take?.files.id == id else { return }
        }
        if take.removeFillers {
            let before = TextCleanup.wordCount(cleaned)
            cleaned = FillerFilter.apply(to: cleaned)
            cleanupNote += ", \(before - TextCleanup.wordCount(cleaned)) fillers removed"
            ledger.cleaned(cleaned, cleanupMs: nil)
        }
        let replaceStarted = ProcessInfo.processInfo.systemUptime
        let output = take.replacer?.apply(to: cleaned) ?? cleaned
        ledger.finalText(output, replacementMs: take.replacer == nil ? nil : Self.ms(ProcessInfo.processInfo.systemUptime - replaceStarted))
        guard !output.isEmpty else {
            log.notice("take \(id, privacy: .public) heard nothing to paste")
            fail(heardSignal ? TakeRemarks.noSpeech : TakeRemarks.noAudio, ledger: ledger, takeID: id)
            return
        }
        // The final replaces the live guesses on the board: every word settled, as it pastes.
        words.finish(output)
        presentation.setWords(words.plates)
        let outcome: PasteOutcome
        // A practice take shows its text in onboarding and sends no keystroke, so history records
        // it as practice rather than as a pasted keystroke.
        let practiced = practiceSink != nil
        if let practiceSink {
            practiceSink(output)
            outcome = PasteOutcome(kind: .pasted, method: "keystroke", reason: nil, onClipboard: false, permissionMissing: false, logCode: "keystroke")
        } else {
            let focusAtStop = await appAtStop.value
            outcome = await paster.paste(PasteText.separated(output), focusAtStop: focusAtStop) { [weak self] in self?.take?.files.id == id }
        }
        let pastedAt = ProcessInfo.processInfo.systemUptime
        switch outcome.kind {
        case .pasted: pasteWatch.pasted(at: pastedAt)
        case .failed, .held, .withdrawn: pasteWatch.endedWithoutPaste()
        }
        log.notice("take \(id, privacy: .public) paste \(practiced ? "practice" : outcome.logCode, privacy: .public) from \(route, privacy: .public), \(cleanupNote, privacy: .public): final \(Self.ms(finalAt - stoppedAt), privacy: .public) ms and paste \(Self.ms(pastedAt - stoppedAt), privacy: .public) ms after the stop tap, \(output.count, privacy: .public) characters")
        // History first: a cancel that already landed keeps its outcome (the ledger's first
        // terminal call wins), and one that lands later finds this one recorded.
        let reroute: String? = viaBackup ? (offlineAnswered ? "local whisper" : "batch") : usedSettledWords ? "settled words" : cleanupRemark != nil ? "raw text" : nil
        let clipboardMethod: String? = outcome.onClipboard ? "clipboard" : nil
        switch outcome.kind {
        case .pasted:
            ledger.conclude(reroute == nil ? .pasted : .rerouted, reason: reroute, destination: focus.destinationName(),
                            pasteMethod: practiced ? "practice" : outcome.method, pasteMs: practiced ? nil : Self.ms(pastedAt - stoppedAt))
        case .failed:
            // The text is on the clipboard when it says so, so the take is held there rather than lost.
            ledger.conclude(.held, reason: outcome.permissionMissing ? "accessibility not granted" : "paste failed", destination: focus.destinationName(), pasteMethod: clipboardMethod, pasteMs: nil)
        case .held:
            // Nowhere to paste: no keystroke went out, and the text waits on the clipboard.
            ledger.conclude(.held, reason: outcome.reason, destination: focus.destinationName(), pasteMethod: clipboardMethod, pasteMs: nil)
        case .withdrawn:
            ledger.cancel()
        }
        guard self.take?.files.id == id else { return }
        switch outcome.kind {
        case .pasted:
            if viaBackup {
                let why = take.batchOnly ? nil : liveError == .timedOut ? TakeRemarks.finalLate : take.transcriber == nil ? nil : TakeRemarks.streamDropped
                conclude(.rerouted(.batch), remark: Self.joined([why] + warnings + [cleanupRemark]))
            } else if !warnings.isEmpty, route == "batch" {
                conclude(.pasted, remark: Self.joined(warnings + [cleanupRemark]))
            } else if usedSettledWords {
                // The strip has no SETTLED sub-label; RAW TEXT is the nearest (live text, not a final).
                conclude(.rerouted(.rawText), remark: Self.joined(warnings + [cleanupRemark]))
            } else if let cleanupRemark {
                conclude(.rerouted(.rawText), remark: cleanupRemark)
            } else {
                conclude(.pasted, remark: nil)
            }
        case .failed:
            presentation.raiseAlert()
            conclude(.held, remark: Self.joined([remarks.forFailure(outcome)] + warnings + [cleanupRemark]))
        case .held:
            presentation.raiseAlert()
            conclude(.held, remark: Self.joined([remarks.forHeld(outcome)] + warnings + [cleanupRemark]))
        case .withdrawn:
            end()
        }
    }

    /// More than 300 words a minute is past fast speech: the batch model likely repeated itself.
    /// Takes under 30 seconds are not judged; a short burst can run fast.
    private static func implausiblyWordy(words: Int, durationMs: Int) -> Bool {
        guard durationMs >= 30_000 else { return false }
        return Double(words) / (Double(durationMs) / 60_000) > 300
    }

    private func fail(_ remark: String, ledger: TakeLedger?, takeID: String? = nil) {
        presentation.raiseAlert()
        pasteWatch.endedWithoutPaste()
        ledger?.conclude(.failed, reason: remark, destination: nil, pasteMethod: nil, pasteMs: nil)
        conclude(.failed, remark: remark, takeID: takeID)
    }

    private func conclude(_ result: TakeResult, remark: String?, takeID: String? = nil) {
        if result == .held || result == .failed { sounds.play(.problem) }
        present(result, remark: remark, takeID: takeID)
        end()
    }

    /// Records the take's ending for `status()` and tells the presentation.
    private func present(_ result: TakeResult, remark: String?, takeID: String?) {
        lastEnding = TakeEnding(takeID: takeID ?? take?.files.id ?? "", result: result, remark: remark, endedAt: .now)
        presentation.finish(result, remark: remark)
    }

    /// Encodes the take's recording to FLAC off the main actor and records the audio in history:
    /// the FLAC, or the recording when FLAC failed and it stays.
    @discardableResult
    private func saveAudio(_ files: TakeFiles, ledger: TakeLedger, capturedSeconds: Double) -> Task<SavedAudio?, Never> {
        let store = store
        let log = log
        let task = Task.detached(priority: .userInitiated) { () -> SavedAudio? in
            do {
                let flac = try store.finishAudio(files)
                log.notice("take \(files.id, privacy: .public) saved: \(flac.path, privacy: .private)")
                let saved = SavedAudio.measure(flac, isFLAC: true, fallbackSeconds: capturedSeconds)
                ledger.audioSaved(path: flac, byteCount: saved.byteCount, durationMs: saved.durationMs)
                return saved
            } catch {
                log.error("take \(files.id, privacy: .public) kept as recording, FLAC failed: \(String(describing: error), privacy: .private)")
                guard FileManager.default.fileExists(atPath: files.recording.path) else { return nil }
                let saved = SavedAudio.measure(files.recording, isFLAC: false, fallbackSeconds: capturedSeconds)
                ledger.audioSaved(path: files.recording, byteCount: saved.byteCount, durationMs: saved.durationMs)
                return saved
            }
        }
        audioTasks[files.id] = task
        Task { [weak self] in
            _ = await task.value
            self?.audioTasks[files.id] = nil
        }
        return task
    }

    private func end() {
        take = nil
        words = WordLine()
        phase = .idle
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    private static func joined(_ sentences: [String?]) -> String {
        sentences.compactMap(\.self).joined(separator: " ")
    }
}
