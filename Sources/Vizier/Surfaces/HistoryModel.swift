import AVFoundation
import AppKit
import VizierEngine
import Observation
import os

/// What the History window and the popover read: the takes matching the search and filter, the
/// selection, and the audio player. Queries run off the main thread; a newer query's result
/// always wins over an older one's.
@Observable
final class HistoryModel {
    let store: HistoryStore
    let config: ConfigStore
    let player = TakePlayer()

    var query = "" { didSet { if query != oldValue { reload() } } }
    var filter: HistoryFilter = .all { didSet { if filter != oldValue { reload() } } }
    var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            if choosingModeFor != selectedID { choosingModeFor = nil }
            loadBars()
            loadReruns()
        }
    }

    private(set) var takes: [TakeRecord] = []
    private(set) var days: [TakeDay] = []
    private(set) var total = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var modes: [String: VizierConfig.Mode] = [:]
    /// The modes in the settings file's order, for the re-run picker.
    private(set) var modeList: [VizierConfig.Mode] = []
    /// The selected take's re-runs, oldest first, by take id.
    private(set) var reruns: [String: [TakeAttempt]] = [:]
    /// Takes with a re-run under way, and the name of the mode it runs through.
    private(set) var rerunning: [String: String] = [:]
    /// A re-run that could not start or could not be saved, by take id, in one plain sentence.
    private(set) var rerunNotice: [String: String] = [:]
    /// The attempt whose text was just put on the clipboard, for its COPIED label.
    var copiedAttempt: String?
    /// The take whose Re-run mode row is open, if any; it closes when another take is selected.
    var choosingModeFor: String?
    /// Changes when the list should scroll to the selected take; the value is that take's id and
    /// a counter, so revealing the same take twice still scrolls.
    private(set) var scrollTarget: ScrollTarget?

    struct ScrollTarget: Equatable {
        let id: String
        let serial: Int
    }

    /// A take `reveal` asked for, scrolled to once the rows holding it are loaded.
    @ObservationIgnored private var pendingReveal: String?
    /// Waveform bars by take id, filled as takes are selected.
    private(set) var bars: [String: [Float]] = [:]
    /// Set when the database could not be read; the window says so instead of showing nothing.
    private(set) var loadError: String?
    private(set) var loaded = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: "net.praxient.dictum", category: "history")

    init(store: HistoryStore, config: ConfigStore) {
        self.store = store
        self.config = config
        observer = NotificationCenter.default.addObserver(forName: HistoryStore.didChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var selected: TakeRecord? { takes.first { $0.id == selectedID } }

    func modeName(_ id: String) -> String {
        if let mode = modes[id] { return mode.name }
        if id == VoiceInkImport.modeID { return "VoiceInk" }
        return id == "unknown" ? "Unknown" : id
    }

    func modeCode(_ id: String) -> String {
        if let mode = modes[id] { return HistoryBoard.platformCode(mode.name) }
        if id == VoiceInkImport.modeID { return "VI" }
        return id == "unknown" ? "—" : HistoryBoard.platformCode(id)
    }

    func reload() {
        generation += 1
        let generation = generation
        let store = store, query = query.trimmingCharacters(in: .whitespacesAndNewlines), outcomes = filter.outcomes
        let modeList = config.load().config.settings.modes
        let modes = Dictionary(modeList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        Task.detached(priority: .userInitiated) {
            let result = Result { () throws -> ([TakeRecord], Int, Int64) in
                (try store.search(query, outcomes: outcomes, limit: 100_000, before: nil), try store.count(), try store.totalAudioBytes())
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return }
                self.modes = modes
                self.modeList = modeList
                self.loaded = true
                switch result {
                case .success(let (takes, total, bytes)):
                    self.takes = takes
                    self.days = HistoryBoard.days(takes)
                    self.total = total
                    self.totalBytes = bytes
                    self.loadError = nil
                    if self.selectedID == nil || !takes.contains(where: { $0.id == self.selectedID }) {
                        self.selectedID = takes.first?.id
                    } else {
                        // A selection made before these rows arrived (a take opened from the
                        // popover) had nothing to load against then.
                        self.loadBars()
                        self.loadReruns()
                    }
                    if let pending = self.pendingReveal, takes.contains(where: { $0.id == pending }) {
                        self.pendingReveal = nil
                        self.scroll(to: pending)
                    }
                case .failure(let error):
                    self.loadError = String(describing: error)
                    self.log.error("history could not be read: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    /// Opens the window's view on one take: clears a search or filter that would hide it.
    func reveal(_ id: String) {
        if !takes.contains(where: { $0.id == id }) {
            query = ""
            filter = .all
        }
        selectedID = id
        if takes.contains(where: { $0.id == id }) {
            pendingReveal = nil
            scroll(to: id)
        } else {
            pendingReveal = id
        }
    }

    /// The newest take that can be re-run (finished, with its FLAC on disk), or nil.
    func newestRerunnable() -> String? {
        let recent = (try? store.recent(limit: 50)) ?? []
        return recent.first(where: canRerun)?.id
    }

    private func scroll(to id: String) {
        scrollTarget = ScrollTarget(id: id, serial: (scrollTarget?.serial ?? 0) + 1)
    }

    func move(by offset: Int) {
        let ids = days.flatMap { $0.takes.map(\.id) }
        guard !ids.isEmpty else { return }
        let index = selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        selectedID = ids[min(max(index + offset, 0), ids.count - 1)]
    }

    /// Whether `take` can be re-run: it has finished and its FLAC is on disk.
    func canRerun(_ take: TakeRecord) -> Bool {
        guard take.outcome != .recording, take.outcome != .finalizing, let audio = take.audioPath,
              audio.pathExtension.lowercased() == "flac" else { return false }
        return FileManager.default.fileExists(atPath: audio.path)
    }

    /// Sends the take's saved audio through `mode` and records the result as a new attempt. Text
    /// that comes back goes on the clipboard, never pasted. The take's own record is unchanged.
    func rerun(_ take: TakeRecord, through mode: VizierConfig.Mode) {
        guard rerunning[take.id] == nil, canRerun(take), let audio = take.audioPath else { return }
        rerunNotice[take.id] = nil
        let plan: Rerun.Plan
        do {
            plan = try Rerun.plan(mode: mode, config: config.load().config) { account in
                do { return try Keychain.read(account) } catch { return nil }
            }
        } catch {
            rerunNotice[take.id] = error.description
            return
        }
        rerunning[take.id] = mode.name
        let store = store, id = take.id, log = log, modeID = mode.id
        log.notice("take \(id, privacy: .public) re-run through \(modeID, privacy: .public) started")
        Task.detached(priority: .userInitiated) {
            let draft = await Rerun.run(audio, plan: plan)
            let saved = Result { try store.addRerun(takeID: id, draft) }
            await MainActor.run { [weak self] in
                self?.rerunning[id] = nil
                switch saved {
                case .success(let attempt):
                    log.notice("take \(id, privacy: .public) re-run \(attempt.number, privacy: .public) \(attempt.outcome, privacy: .public): transcription \(attempt.transcriptionMs ?? -1, privacy: .public) ms, cleanup \(attempt.cleanupMs ?? -1, privacy: .public) ms, \(attempt.finalText?.count ?? 0, privacy: .public) characters")
                    if let text = attempt.finalText {
                        Self.copy(text)
                        self?.copiedAttempt = attempt.id
                    }
                    self?.loadReruns(id)
                case .failure(let error):
                    log.error("take \(id, privacy: .public) re-run could not be saved: \(String(describing: error), privacy: .private)")
                    self?.rerunNotice[id] = "The re-run could not be saved: \(error)"
                }
            }
        }
    }

    private func loadReruns(_ id: String? = nil) {
        guard let id = id ?? selectedID else { return }
        let store = store
        Task.detached(priority: .userInitiated) {
            let found = (try? store.reruns(takeID: id)) ?? []
            await MainActor.run { [weak self] in self?.reruns[id] = found }
        }
    }

    private func loadBars() {
        guard let take = selected, bars[take.id] == nil, let url = take.audioPath else { return }
        let id = take.id
        Task.detached(priority: .userInitiated) {
            let values = (try? Waveform.bars(of: url, count: 64)) ?? []
            await MainActor.run { [weak self] in self?.bars[id] = values }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Plays one take's saved audio at a time.
@Observable
final class TakePlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingID: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let log = Logger(subsystem: "net.praxient.dictum", category: "history")

    /// 0 to 1 through the playing take; 0 when nothing plays.
    var progress: Double {
        guard let player, player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }

    func toggle(_ take: TakeRecord) {
        if playingID == take.id {
            stop()
            return
        }
        stop()
        guard let url = take.audioPath else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.play() else { return }
            self.player = player
            playingID = take.id
        } catch {
            log.error("could not play a take: \(String(describing: error), privacy: .private)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
