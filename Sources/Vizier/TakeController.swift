import AVFoundation
import AppKit
import VizierEngine
import os

/// Owns the take lifecycle: start on a tap, stop on the next, cancel on Escape. Every take keeps
/// its audio, canceled ones included; the live transcript is pasted when a take stops. Each take's
/// `TakeLedger` writes its history row at every stage, before any point where the take can end.
final class TakeController {
    /// The remarks line's sentences: one plain sentence of fact each.
    enum Remark {
        static let streamDroppedRecording = "The live stream dropped. Audio is still recording and will go through batch when you stop."
        static let streamDroppedNoBatch = "The live stream dropped. Audio is still recording and will be saved when you stop."
        static let streamDropped = "The live stream dropped, so the saved audio went through batch."
        static let finalLate = "The live transcript did not finish in time, so the saved audio went through batch."
        static let unreachable = "The engine could not be reached. The audio is saved."
        static let localDown = "Local whisper did not answer. Is its server running? The audio is saved."
        static let offline = "The cloud could not be reached, so this Mac transcribed the saved audio."
        static func noKey(_ name: String) -> String {
            "There is no \(name) key yet, so nothing was transcribed. Add one in Settings › Accounts. The audio is saved."
        }
        static let speechModelMissing = "The Apple speech model is not ready (it may still be downloading), so nothing was transcribed. Get it in Settings › Transcription › Download speech model. The audio is saved."
        static let noSpeech = "No speech came through. The audio is saved."
        static let noFlac = "The live transcript failed and the audio could not be prepared for batch. The recording is saved."
        static let noAudio = "The mic never delivered audio. Check the input device."
        static let micFailed = "The mic could not start. Check the input device."
        static let micDenied = "Vizier does not have microphone access, so nothing was recorded. Turn it on in System Settings › Privacy & Security › Microphone."
        static let noFolder = "The take could not be saved, so nothing was recorded."
        static let pasteFailed = "The paste did not go through. The text is on the clipboard; ⌘V pastes it."
        static let accessibilityMissing = "Vizier does not have Accessibility access, so nothing was pasted. Turn it on in System Settings › Privacy & Security › Accessibility. The text is on the clipboard; ⌘V pastes it."

        /// A failed paste's remark: missing Accessibility says how to grant it.
        static func forPasteFailure(_ reason: String) -> String {
            reason == Paster.accessibilityMissing ? accessibilityMissing : pasteFailed
        }

        /// The remark that stops a take before it records, when microphone access is denied;
        /// nil when the take may start. Not yet asked goes ahead, so macOS can ask.
        static func micBlocked(_ access: PermissionState) -> String? {
            access == .denied ? micDenied : nil
        }
        static let noPasteTarget = "No text field had focus, so nothing was pasted. The text is on the clipboard; ⌘V pastes it."
        static let vizierHadFocus = "Vizier itself had focus, so nothing was pasted. The text is on the clipboard; ⌘V pastes it."
        static let focusMoved = "You switched apps after the take stopped, so nothing was pasted. The text is on the clipboard; ⌘V pastes it."
        static let secureField = "A password field had focus, so nothing was pasted. The text is on the clipboard; ⌘V pastes it."
        static let secureInput = "Secure input was on and the focused field could not be read, so nothing was pasted. The text is on the clipboard; ⌘V pastes it."
        static let cleanupLate = "The cleanup pass did not finish in time, so the raw transcript was pasted."
        static let cleanupFailed = "The cleanup pass failed, so the raw transcript was pasted."
        static let cleanupDropped = "The cleanup pass dropped too many words to trust, so the raw transcript was pasted."
        static let cleanupAdded = "The cleanup pass added words, so the raw transcript was pasted."
        static let settledWords = "The live transcript did not finish, so the settled words were pasted."
        static let batchTooLong = "The take is longer than the batch model's one-hour limit, so it was not sent to batch. The audio is saved."
        static let batchTruncated = "The batch transcript hit the model's output limit and may be cut off."
        static func batchRepeated(words: Int, durationMs: Int) -> String {
            "The batch transcript has \(words) words for \(spoken(durationMs)) of audio, so it may contain repeated text."
        }

        private static func spoken(_ durationMs: Int) -> String {
            let seconds = durationMs / 1000
            if seconds < 90 { return "\(seconds) seconds" }
            return "\(Int((Double(seconds) / 60).rounded())) minutes"
        }

        static func cleanup(_ fallback: TextCleanup.Fallback) -> String {
            switch fallback {
            case .timedOut: cleanupLate
            case .failed: cleanupFailed
            case .tooShort: cleanupDropped
            case .tooLong: cleanupAdded
            }
        }
    }

    /// Finalizing reads DELAYED past 1 s (DESIGN.md). A mode with a cleanup pass gets this much
    /// longer, since cleanup is part of its normal path: a Flash-Lite pass takes 0.6 to 1.4 s, and
    /// the slowest release-to-text measured was 2.45 s.
    static let cleanupAllowance: TimeInterval = 1.5
    /// A Local take is transcribed after the stop: 0.8 to 2.0 s for takes of 13 to 43 s.
    static let localAllowance: TimeInterval = 2.5
    /// The local cleanup model took 0.6 s on short takes and 3 to 5 s past 100 words.
    static let localCleanupAllowance: TimeInterval = 4

    enum Phase { case idle, arming, recording, finalizing }

    private(set) var phase = Phase.idle {
        didSet { statusItem.phase = statusPhase }
    }

    /// Times the take's stop and paste, so a typed Cmd+V near them can be logged.
    var pasteWatch = TypedPasteWatch()
    /// Set only while onboarding's Practice step is on screen: a finished take's text goes here
    /// instead of being pasted, since Vizier never pastes into itself. Everywhere else it is nil.
    var practiceSink: ((String) -> Void)?

    /// The current take's words, for the strip.
    private(set) var words = WordLine()

    private struct Take {
        let files: TakeFiles
        let transcriber: LiveTranscriber?
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
    /// after a cancel resets the controller.
    private final class LiveText {
        var settled = SettledTranscript()
    }

    /// A take's saved audio: the FLAC, or the recording when FLAC failed.
    nonisolated private struct SavedAudio: Sendable {
        let url: URL
        let isFLAC: Bool
        let byteCount: Int64
        let durationMs: Int

        /// Duration from the file's frame count at 16 kHz; `fallbackSeconds` when the file can't be read.
        static func measure(_ url: URL, isFLAC: Bool, fallbackSeconds: Double) -> SavedAudio {
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            let seconds = (try? AVAudioFile(forReading: url)).map { Double($0.length) / 16_000 } ?? fallbackSeconds
            return SavedAudio(url: url, isFLAC: isFLAC, byteCount: bytes, durationMs: Int((seconds * 1000).rounded()))
        }
    }

    private typealias Provider = Engines.KeyAccount

    private struct Cleanup {
        let cleaner: any TextCleaner
        let model: String
        let timeout: Duration
        /// Runs on this Mac, which takes longer than a cloud pass on a long take.
        let local: Bool
    }

    private let statusItem: StatusItemController
    private let strip: StripController
    private let config = ConfigStore.standard
    private let store = TakeStore.standard
    private let recorder = TakeRecorder()
    private let sounds = Sounds()
    /// Nil when history could not open; takes still run, and each ledger writes nothing.
    private let history: HistoryStore?
    private var take: Take?
    private let log = Logger(subsystem: "net.praxient.dictum", category: "take")

    init(statusItem: StatusItemController, strip: StripController, history: HistoryStore?) {
        self.statusItem = statusItem
        self.strip = strip
        self.history = history
    }

    /// Readies the mic so the first take after launch doesn't lose its opening words. Call once
    /// mic access is granted; a take started meanwhile waits for it and uses the readied unit.
    func warmUpCapture() {
        recorder.warmUp()
    }

    var isCancelable: Bool { phase != .idle }
    var acceptsToggle: Bool { phase != .finalizing }

    /// `time` is the Right Command key-down; the stop's latency figures count from it.
    func toggle(at time: TimeInterval) {
        if phase == .idle { start(releasedAt: time) } else { stop(releasedAt: time) }
    }

    func cancel() {
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
        strip.finish(.cancelled, remark: nil)
        end()
    }

    /// Repairs history from the files on disk (rows for orphaned audio, rows left open closed as
    /// failed), then encodes recordings a crash left behind and points their rows at the FLAC, so
    /// no take stays half-saved or unlisted. Deletes no audio.
    ///
    /// The leftovers are listed here, on the main actor, before the hotkey can start a take: a
    /// recording that starts later is never picked up and encoded out from under its recorder.
    func recoverUnfinishedTakes() {
        let store = store
        let history = history
        let log = log
        let leftovers = store.unfinishedTakes()
        Task.detached(priority: .utility) {
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
    }

    private func start(releasedAt: TimeInterval) {
        let load = config.load()
        for error in load.errors {
            log.error("config: \(error.publicSummary, privacy: .public); running the last good config")
            log.error("config detail: \(error.description, privacy: .private)")
        }
        if !load.errors.isEmpty { statusItem.alert = true }

        // With microphone access denied the recorder would capture silence: say so instead.
        if let blocked = Remark.micBlocked(SystemPermissions().microphone()) {
            log.error("take did not start: microphone access is denied")
            postBoard(load.config)
            fail(blocked, ledger: nil)
            return
        }

        let files: TakeFiles
        let startedAt = Date.now
        do {
            files = try store.newTake(startedAt: startedAt)
        } catch {
            log.error("take did not start: \(String(describing: error), privacy: .private)")
            postBoard(load.config)
            fail(Remark.noFolder, ledger: nil)
            return
        }
        let id = files.id
        let mode = load.config.activeMode
        let destination = Self.destination()
        let draft = TakeDraft(
            id: id, startedAt: startedAt, destinationAtStart: destination.isEmpty ? nil : destination, modeID: mode.id,
            transcriberEngine: mode.transcriber.engine, transcriberModel: mode.transcriber.model,
            fallbackEngine: mode.fallback?.engine, fallbackModel: mode.fallback?.model,
            cleanerEngine: mode.cleanup?.engine, cleanerModel: mode.cleanup?.model)
        // A batch-only mode (Local) has no live stream and reads no key for one; an Apple engine needs none.
        let liveProvider = mode.isBatchOnly ? nil : Engines.keyAccount(for: mode.transcriber.engine)
        let liveKey = liveProvider.flatMap { key($0) }
        // A second Keychain read only when a batch link or cleanup is another provider's; none for a local engine.
        func keyFor(_ engine: String) -> String? {
            guard let provider = Engines.keyAccount(for: engine) else { return nil }
            return provider.account == liveProvider?.account ? liveKey : key(provider)
        }
        let batches = mode.batchChain.compactMap { spec in
            Engines.batch(spec, languages: mode.transcriber.languages, vocabulary: load.config.vocabulary, key: keyFor(spec.engine))
                .map { BatchChain.Link(engine: spec.engine, transcriber: $0) }
        }
        let cleanup = mode.cleanup.flatMap { pass in
            Engines.cleaner(pass, languages: mode.transcriber.languages, config: load.config, key: keyFor(pass.engine))
                .map { Cleanup(cleaner: $0, model: pass.model, timeout: .milliseconds(pass.timeoutMs), local: Engines.keyAccount(for: pass.engine) == nil) }
        }
        // A keyless engine (Apple) starts with no key; a cloud engine starts only when its key was found.
        let transcriber = Engines.liveTranscriber(for: mode, vocabulary: load.config.vocabulary, key: liveKey)
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
            fail(Remark.micFailed, ledger: TakeLedger(store: history, draft: draft))
            return
        }
        // The mic starts before the board: a clipped first syllable costs more than a strip that
        // posts a frame later. The history row's first write waits for the mic for the same reason.
        let ledger = TakeLedger(store: history, draft: draft)
        postBoard(load.config)
        take = Take(
            files: files, transcriber: transcriber, missingKey: liveKey == nil ? liveProvider?.name : nil,
            batches: batches, batchOnly: mode.isBatchOnly,
            cleanup: cleanup, removeFillers: FillerFilter.applies(to: mode),
            replacer: makeReplacer(load.config), startedAt: releasedAt, ledger: ledger, live: LiveText())
        words = WordLine()
        phase = .arming
        log.notice("take \(id, privacy: .public) started \(Self.ms(ProcessInfo.processInfo.systemUptime - releasedAt), privacy: .public) ms after the key-down")
    }

    private func postBoard(_ config: VizierConfig) {
        let recorder = recorder
        strip.begin(
            destination: Self.destination(), platform: Self.platformCode(config.activeMode.name),
            level: { recorder.capture.meanSquare }, seconds: { recorder.capturedSeconds })
    }

    /// The focused app for the destination modules, VIZIER when Vizier itself has focus.
    private static func destination() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }

    static func platformCode(_ name: String) -> String { HistoryBoard.platformCode(name) }

    /// Read per take, so a key seeded while Vizier runs is picked up on the next take.
    private func key(_ provider: Provider) -> String? {
        do {
            if let key = try Keychain.read(provider.account) { return key }
            log.error("no \(provider.name, privacy: .public) key in the keychain; add one in Settings › Accounts")
        } catch {
            log.error("could not read the \(provider.name, privacy: .public) key: \(error.description, privacy: .private)")
        }
        statusItem.alert = true
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

    private func captureEvent(_ event: HALCapture.Event) {
        switch event {
        case .signal:
            guard phase == .arming, let take else { return }
            phase = .recording
            strip.setLive()
            // On the first real audio, not the tap: the ping means the mic is actually listening.
            sounds.play(.start)
            let delay = ProcessInfo.processInfo.systemUptime - take.startedAt
            log.notice("first signal \(delay * 1000, format: .fixed(precision: 0), privacy: .public) ms after the tap")
        case .deviceSwitched(let name):
            log.notice("capture moved to \(name, privacy: .private)")
        case .deviceSwitchFailed(let reason):
            log.error("capture could not follow the input change: \(reason, privacy: .private)")
        }
    }

    private func transcriptEvent(_ event: LiveTranscriberEvent, take id: String) {
        guard take?.files.id == id else { return }
        switch event {
        case .transcript(let settled, let pending):
            take?.live.settled.update(settled: settled, pending: pending)
            words.update(settled: settled, pending: pending)
            strip.setWords(words.plates)
        case .streamLost(let reason):
            log.error("take \(id, privacy: .public) lost its live stream: \(reason, privacy: .private)")
            if phase == .arming || phase == .recording {
                if reason == AppleSpeechTranscriber.modelMissingReason {
                    strip.streamLost(remark: Remark.speechModelMissing)
                } else {
                    strip.streamLost(remark: take?.batches.isEmpty != false ? Remark.streamDroppedNoBatch : Remark.streamDroppedRecording)
                }
            }
        }
    }

    private func stop(releasedAt: TimeInterval) {
        guard let take else { return }
        // Where the user is at the stop tap; the paste goes nowhere else.
        let appAtStop = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Stopping the recorder hands the last partial chunk to the transcriber before finish().
        let summary = recorder.stop()
        sounds.play(.stop)
        let heardSignal = phase != .arming
        phase = .finalizing
        pasteWatch.takeStopped(at: releasedAt)
        strip.stopped(onTime: (take.batchOnly ? Self.localAllowance : 1) + (take.cleanup.map { $0.local ? Self.localCleanupAllowance : Self.cleanupAllowance } ?? 0))
        log.notice("take \(take.files.id, privacy: .public) stopped: \(summary.seconds, format: .fixed(precision: 2), privacy: .public) s captured, \(summary.capture.deviceSwitches, privacy: .public) input switches, \(summary.capture.droppedBuffers, privacy: .public) dropped buffers, signal \(heardSignal, privacy: .public)")
        if let error = summary.writeError {
            log.error("recording write failed mid-take: \(error, privacy: .private)")
        }
        take.ledger.stopped()
        let audio = saveAudio(take.files, ledger: take.ledger, capturedSeconds: summary.seconds)
        Task { await deliver(take, stoppedAt: releasedAt, appAtStop: appAtStop, heardSignal: heardSignal, audio: audio) }
    }

    /// Waits for the take's text, cleans it when the mode has a cleanup pass, and pastes it. When
    /// the live final doesn't come, the saved FLAC goes to batch; when batch can't help either, the
    /// settled live words paste; when cleanup doesn't hold, the raw transcript pastes. Latency is
    /// measured from the stop tap's key-up.
    ///
    /// Every text is written to the take's ledger the moment it exists, before any `guard` that
    /// can return: a take cancelled mid-flight keeps the text it had.
    private func deliver(_ take: Take, stoppedAt: TimeInterval, appAtStop: pid_t?, heardSignal: Bool, audio: Task<SavedAudio?, Never>) async {
        let id = take.files.id
        let ledger = take.ledger
        var text: String?
        var route = "live"
        var liveError: TranscriberError?
        var remark = take.missingKey.map(Remark.noKey) ?? Remark.unreachable
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
            if !take.batchOnly { strip.reroutingToBatch() }
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
                    if offlineAnswered { warnings.append(Remark.offline) }
                    if report.truncated { warnings.append(Remark.batchTruncated) }
                    if Self.implausiblyWordy(words: report.wordCount, durationMs: saved.durationMs) {
                        log.error("take \(id, privacy: .public) batch returned \(report.wordCount, privacy: .public) words for \(saved.durationMs, privacy: .public) ms of audio")
                        warnings.append(Remark.batchRepeated(words: report.wordCount, durationMs: saved.durationMs))
                    }
                case .failure(let failure):
                    for (engine, error) in failure.errors {
                        log.error("take \(id, privacy: .public) \(engine, privacy: .public) failed: \(String(describing: error), privacy: .private)")
                    }
                    if failure.errors.contains(where: { if case AppleSpeechError.modelNotInstalled = $0.error { true } else { false } }) {
                        remark = Remark.speechModelMissing
                    } else if failure.tooLong {
                        log.error("take \(id, privacy: .public) is too long for batch (\(saved.durationMs / 1000, privacy: .public) s)")
                        remark = Remark.batchTooLong
                        batchTooLong = true
                    } else if take.batchOnly, take.batches.first?.engine == "local-whisper" {
                        remark = Remark.localDown
                    }
                }
            } else {
                log.error("take \(id, privacy: .public) has no FLAC for batch")
                remark = Remark.noFlac
            }
        }
        // Never lose text the strip already showed: with no transcript, or a blank one (a live
        // final or batch answer with no words), the settled live words stand in, even for a take
        // cancelled while it waited. A blank live final is never sent to batch.
        if let settled = take.live.settled.standIn(for: text) {
            text = settled
            route = "live"
            usedSettledWords = true
            warnings = [Remark.settledWords] + (batchTooLong ? [Remark.batchTooLong] : [])
            ledger.transcript(raw: settled, route: "live", transcriptionMs: Self.ms(ProcessInfo.processInfo.systemUptime - stoppedAt))
            log.notice("take \(id, privacy: .public) has no final; using its settled live words")
        }
        let finalAt = ProcessInfo.processInfo.systemUptime
        guard self.take?.files.id == id else { return }
        guard let text else {
            log.error("take \(id, privacy: .public) failed; its audio is saved")
            fail(remark, ledger: ledger)
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
                cleanupRemark = Remark.cleanup(fallback)
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
            fail(heardSignal ? Remark.noSpeech : Remark.noAudio, ledger: ledger)
            return
        }
        // The final replaces the live guesses on the board: every word settled, as it pastes.
        words.finish(output)
        strip.setWords(words.plates)
        let outcome: Paster.Outcome
        // A practice take shows its text in onboarding and sends no keystroke, so history records
        // it as practice rather than as a pasted keystroke.
        let practiced = practiceSink != nil
        if let practiceSink {
            practiceSink(output)
            outcome = .keystroke
        } else {
            outcome = await Paster.paste(PasteText.separated(output), appAtStop: appAtStop) { [weak self] in self?.take?.files.id == id }
        }
        let pastedAt = ProcessInfo.processInfo.systemUptime
        switch outcome {
        case .keystroke, .appleScript: pasteWatch.pasted(at: pastedAt)
        case .failed, .held, .withdrawn: pasteWatch.endedWithoutPaste()
        }
        log.notice("take \(id, privacy: .public) paste \(practiced ? "practice" : outcome.logCode, privacy: .public) from \(route, privacy: .public), \(cleanupNote, privacy: .public): final \(Self.ms(finalAt - stoppedAt), privacy: .public) ms and paste \(Self.ms(pastedAt - stoppedAt), privacy: .public) ms after the stop tap, \(output.count, privacy: .public) characters")
        // History first: a cancel that already landed keeps its outcome (the ledger's first
        // terminal call wins), and one that lands later finds this one recorded.
        let reroute: String? = viaBackup ? (offlineAnswered ? "local whisper" : "batch") : usedSettledWords ? "settled words" : cleanupRemark != nil ? "raw text" : nil
        switch outcome {
        case .keystroke, .appleScript:
            ledger.conclude(reroute == nil ? .pasted : .rerouted, reason: reroute, destination: Self.destination(),
                            pasteMethod: practiced ? "practice" : outcome.description, pasteMs: practiced ? nil : Self.ms(pastedAt - stoppedAt))
        case .failed:
            // The text is on the clipboard, so the take is held there rather than lost.
            ledger.conclude(.held, reason: outcome.failedForAccessibility ? "accessibility not granted" : "paste failed", destination: Self.destination(), pasteMethod: "clipboard", pasteMs: nil)
        case .held(let reason):
            // Nowhere to paste: no keystroke went out, and the text waits on the clipboard.
            ledger.conclude(.held, reason: reason, destination: Self.destination(), pasteMethod: "clipboard", pasteMs: nil)
        case .withdrawn:
            ledger.cancel()
        }
        guard self.take?.files.id == id else { return }
        switch outcome {
        case .keystroke, .appleScript:
            if viaBackup {
                let why = take.batchOnly ? nil : liveError == .timedOut ? Remark.finalLate : take.transcriber == nil ? nil : Remark.streamDropped
                conclude(.rerouted(.batch), remark: Self.remarks([why] + warnings + [cleanupRemark]))
            } else if !warnings.isEmpty, route == "batch" {
                conclude(.pasted, remark: Self.remarks(warnings + [cleanupRemark]))
            } else if usedSettledWords {
                // The strip has no SETTLED sub-label; RAW TEXT is the nearest (live text, not a final).
                conclude(.rerouted(.rawText), remark: Self.remarks(warnings + [cleanupRemark]))
            } else if let cleanupRemark {
                conclude(.rerouted(.rawText), remark: cleanupRemark)
            } else {
                conclude(.pasted, remark: nil)
            }
        case .failed(let reason):
            statusItem.alert = true
            conclude(.held, remark: Self.remarks([Remark.forPasteFailure(reason)] + warnings + [cleanupRemark]))
        case .held(let reason):
            statusItem.alert = true
            let remark = reason == PasteDecision.vizierHadFocus ? Remark.vizierHadFocus
                : reason == PasteDecision.focusMoved ? Remark.focusMoved
                : reason == PasteDecision.secureField ? Remark.secureField
                : reason == PasteDecision.secureInput ? Remark.secureInput : Remark.noPasteTarget
            conclude(.held, remark: Self.remarks([remark] + warnings + [cleanupRemark]))
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

    private func fail(_ remark: String, ledger: TakeLedger?) {
        statusItem.alert = true
        pasteWatch.endedWithoutPaste()
        ledger?.conclude(.failed, reason: remark, destination: nil, pasteMethod: nil, pasteMs: nil)
        conclude(.failed, remark: remark)
    }

    private func conclude(_ outcome: StripController.Outcome, remark: String?) {
        if outcome == .held || outcome == .failed { sounds.play(.problem) }
        strip.finish(outcome, remark: remark)
        end()
    }

    /// Encodes the take's recording to FLAC off the main actor and records the audio in history:
    /// the FLAC, or the recording when FLAC failed and it stays.
    @discardableResult
    private func saveAudio(_ files: TakeFiles, ledger: TakeLedger, capturedSeconds: Double) -> Task<SavedAudio?, Never> {
        let store = store
        let log = log
        return Task.detached(priority: .userInitiated) {
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
    }

    private func end() {
        take = nil
        words = WordLine()
        phase = .idle
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    private static func remarks(_ sentences: [String?]) -> String {
        sentences.compactMap(\.self).joined(separator: " ")
    }

    private var statusPhase: StatusItemController.Phase {
        switch phase {
        case .idle: .idle
        case .arming: .arming
        case .recording: .recording
        case .finalizing: .finalizing
        }
    }
}
