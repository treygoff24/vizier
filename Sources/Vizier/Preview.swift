import AVFoundation
import AppKit
import VizierEngine
import os

/// `Vizier --preview-surfaces <folder> [--open-popover] [--show-strip]` opens the popover and History
/// window on synthetic takes in `folder`, and with `--show-strip` the recording strip with sample
/// words, for building and screenshotting them without the installed app.
/// It installs no hotkey, records nothing, and never reads a real history or settings: it refuses
/// to run in their folders.
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let folder: URL
    private var statusItem: StatusItemController?
    private var surfaces: Surfaces?
    private var strip: StripController?

    init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let resolved = folder.resolvingSymlinksInPath().path
        if RealDataGuard.refuses(folder) {
            FileHandle.standardError.write(Data("refusing to preview in \(resolved): that is real Vizier data\n".utf8))
            exit(64)
        }
        let children = ["config", "Takes", "history.sqlite", "history.sqlite-wal", "history.sqlite-shm", "history.sqlite-journal"]
        if let child = RealDataGuard.refusedChild(in: folder, writing: children) {
            FileHandle.standardError.write(Data("refusing to preview in \(resolved): \(child) is a link, a hard link, or real Vizier data\n".utf8))
            exit(64)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let config = ConfigStore(directory: folder.appending(path: "config"))
            try config.writeStarterFilesIfMissing()
            let takes = TakeStore(root: folder.appending(path: "Takes"))
            let history = try HistoryStore(databaseURL: folder.appending(path: "history.sqlite"), takesRoot: takes.root)
            if try history.count() == 0 { try PreviewSeed.seed(history: history, takes: takes, config: config) }
            let rerunTake = try history.search("", outcomes: [.failed], limit: 100, before: nil)
                .first { (try? history.reruns(takeID: $0.id))?.isEmpty == false }

            let statusItem = StatusItemController()
            statusItem.alert = true
            let surfaces = Surfaces(statusItem: statusItem, history: history, config: config)
            self.statusItem = statusItem
            self.surfaces = surfaces
            surfaces.showHistory(selecting: CommandLine.arguments.contains("--show-rerun") ? rerunTake?.id : nil)
            if CommandLine.arguments.contains("--show-strip") {
                let strip = StripController()
                strip.begin(destination: "Notes", platform: "AP", level: { 0.55 }, seconds: { 14 })
                strip.setLive()
                let sample = "Move the standup to three and tell the team the demo slips a day".split(separator: " ")
                strip.setWords(sample.enumerated().map { WordLine.Plate(String($0.element), settled: $0.offset < sample.count - 2) })
                self.strip = strip
            }
            if CommandLine.arguments.contains("--open-popover") {
                let screen = NSScreen.main?.frame ?? .zero
                surfaces.popover.show(under: NSRect(x: screen.maxX - 460, y: screen.maxY - 30, width: 26, height: 24), alertWasLit: true)
            }
        } catch {
            FileHandle.standardError.write(Data("preview failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

/// Synthetic takes over four days, covering every outcome, with generated audio on some of them.
enum PreviewSeed {
    private static let sentences = [
        "Move the standup to three and tell the team the demo slips a day.",
        "Okay, run the full suite again and tell me which of those failures are new since this morning.",
        "Draft a short reply saying yes to Thursday, and ask whether the venue has parking.",
        "The trip notes need a section on how the ferry schedule changes when the weather turns.",
        "Look at the build log and find where the linker first complains.",
        "Remind me to call the pharmacy about the refill before noon tomorrow.",
        "Rename that function to something that says what it returns, not how it works.",
        "Can you pull the three strongest counterarguments and put them at the top?",
        "Ship it.",
        "Let's hold the release until the migration has run on a copy of production.",
        "Send the slides to the group with a note that the numbers on slide nine are preliminary.",
        "Summarize what changed in the outline between version four and version five.",
        "No, the other one, the file with the packing list.",
        "Add a test that proves the importer skips rows with no audio instead of failing the whole batch.",
        "Tell Robin the schedule looks fine except the Friday session, which needs a later start.",
        "Check whether the museum is open on Mondays and whether tickets can be booked online.",
    ]
    private static let places = ["Terminal", "Notes", "Messages", "Safari", "Mail", "TextEdit", "Notes", "Terminal"]

    static func seed(history: HistoryStore, takes: TakeStore, config: ConfigStore) throws {
        let modes = config.load().config.settings.modes
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var generator = SeededRandom(seed: 0xD1C7)
        var index = 0
        for dayBack in 0..<4 {
            let day = calendar.date(byAdding: .day, value: -dayBack, to: today)!
            let count = dayBack == 0 ? 14 : 9
            for slot in 0..<count {
                let minutes = 8 * 60 + 30 + slot * (dayBack == 0 ? 25 : 55) + Int(generator.next() % 20)
                var start = calendar.date(byAdding: .minute, value: minutes, to: day)!
                if start > .now { start = Date.now.addingTimeInterval(-Double(600 * (count - slot))) }
                let outcome = outcomeFor(index)
                let text = sentences[index % sentences.count]
                let mode = outcome == .failed && index % 5 == 0 ? nil : modes[index % max(modes.count, 1)]
                let files = try takes.newTake(startedAt: start)
                let durationMs = 1_500 + Int(generator.next() % 40_000)
                try history.begin(TakeDraft(
                    id: files.id, startedAt: start, destinationAtStart: places[index % places.count], modeID: mode?.id ?? "unknown",
                    transcriberEngine: mode?.transcriber.engine ?? "unknown", transcriberModel: mode?.transcriber.model ?? "unknown",
                    fallbackEngine: mode?.fallback?.engine, fallbackModel: mode?.fallback?.model,
                    cleanerEngine: mode?.cleanup?.engine, cleanerModel: mode?.cleanup?.model))
                if index % 3 == 0 {
                    let flac = try writeAudio(files, store: takes, milliseconds: min(durationMs, 12_000), seed: index)
                    let bytes = (try FileManager.default.attributesOfItem(atPath: flac.path)[.size] as? Int64) ?? 0
                    try history.setAudio(id: files.id, path: flac, byteCount: bytes, durationMs: min(durationMs, 12_000))
                }
                let words = outcome == .failed && index % 2 == 0 ? nil : text
                if let words {
                    let raw = words.replacingOccurrences(of: "Okay, ", with: "Okay um, ")
                    try history.setStages(id: files.id, stages: TakeStages(
                        raw: raw, cleaned: nil, final: outcome == .cancelled ? nil : words, route: outcome == .rerouted ? "batch" : "live",
                        transcriptionMs: 80 + Int(generator.next() % 300), cleanupMs: nil, replacementMs: 1))
                }
                let reason: String? = switch outcome {
                case .rerouted: "batch"
                case .held: index % 2 == 0 ? PasteDecision.vizierHadFocus : "no focused element and no windows in com.example.helper"
                case .failed: mode == nil ? "interrupted before delivery" : "No speech came through. The audio is saved."
                default: nil
                }
                try history.finish(id: files.id, stoppedAt: start.addingTimeInterval(Double(durationMs) / 1000), outcome: outcome, reason: reason,
                                   destinationAtPaste: outcome == .pasted || outcome == .rerouted ? places[index % places.count] : nil,
                                   pasteMethod: outcome == .pasted ? "keystroke" : nil,
                                   pasteMs: outcome == .pasted || outcome == .rerouted ? 180 + Int(generator.next() % 500) : nil)
                index += 1
            }
        }
        // Two re-runs of the newest failed take with audio, one that worked and one that did not.
        let failed = try history.search("", outcomes: [.failed], limit: 100, before: nil).first { $0.audioPath != nil }
        if let failed, let mode = modes.first {
            try history.addRerun(takeID: failed.id, RerunDraft(
                modeID: mode.id, transcriberEngine: "elevenlabs-scribe-batch", transcriberModel: "scribe_v2",
                succeeded: false, reason: "The transcription failed: HTTP 503: the service is busy."),
                at: failed.startedAt.addingTimeInterval(120))
            try history.addRerun(takeID: failed.id, RerunDraft(
                modeID: modes.last?.id ?? mode.id, transcriberEngine: "gemini-batch", transcriberModel: "gemini-3.5-transcribe",
                cleanerEngine: "gemini-generate", cleanerModel: "gemini-3.5-flash-lite",
                rawTranscript: "um check whether the museum is open on mondays",
                cleanedText: "Check whether the museum is open on Mondays.",
                finalText: "Check whether the museum is open on Mondays.",
                transcriptionMs: 1_840, cleanupMs: 710, replacementMs: 1, succeeded: true),
                at: failed.startedAt.addingTimeInterval(300))
        }
    }

    private static func outcomeFor(_ index: Int) -> TakeOutcome {
        switch index % 13 {
        case 4: .rerouted
        case 7: .held
        case 9: .cancelled
        case 11: .failed
        default: .pasted
        }
    }

    /// A voice-like signal: a pitched buzz whose loudness rises and falls in syllables, with pauses.
    private static func writeAudio(_ files: TakeFiles, store: TakeStore, milliseconds: Int, seed: Int) throws -> URL {
        let frames = milliseconds * 16
        let file = try AVAudioFile(forWriting: files.recording, settings: TakeStore.recordingSettings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: HALCapture.outputFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.int16ChannelData![0]
        for i in 0..<frames {
            let t = Double(i) / 16_000
            let syllable = max(0, sin(t * 2 * .pi * (2.5 + Double(seed % 4) * 0.4)))
            let phrase = sin(t * 2 * .pi * 0.23 + Double(seed)) > -0.6 ? 1.0 : 0.05
            let voice = sin(t * 2 * .pi * 140) + 0.5 * sin(t * 2 * .pi * 280) + 0.25 * sin(t * 2 * .pi * 420)
            samples[i] = Int16(max(-32_000, min(32_000, 6_000 * syllable * phrase * voice)))
        }
        try file.write(from: buffer)
        file.close()
        return try store.finishAudio(files)
    }
}

/// A small deterministic generator, so every preview seeds the same takes.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
}
