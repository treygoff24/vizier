import VizierEngine
import Foundation

/// `Vizier --import-voiceink [--dry-run] [--no-audio]` brings VoiceInk's history into Vizier's.
/// It is safe while Vizier runs: each take is one short transaction, and the store waits up to 5 s
/// for the app's own writes. `--dry-run` reads both histories and prints counts, writing nothing of Vizier's own; SQLite may still
/// create a `-shm` sidecar next to VoiceInk's database when it opens it (the source is not opened immutable).
/// `--no-audio` imports text only. Prints counts, never text.
enum ImportCommand {
    static func run(_ arguments: [String]) -> Int32? {
        guard arguments.contains("--import-voiceink") else { return nil }
        // The app moves the Dictum-era folders at launch. This command does not: it may run while
        // an older build has them open, and importing into a new, empty history would leave the
        // move blocked for good (both folders present).
        if UserDataMigration.isPending() {
            return fail("the Dictum-era data has not moved to Vizier's folders yet; open Vizier once, then run this again", code: 75)
        }
        let dryRun = arguments.contains("--dry-run")
        let copyAudio = !arguments.contains("--no-audio")
        let store = VoiceInkImport.standardFolder.appending(path: "default.store")
        guard FileManager.default.fileExists(atPath: store.path) else {
            return fail("no VoiceInk history at \(store.path)", code: 66)
        }
        do {
            if dryRun {
                // Read-only: a missing history counts as empty and is not created.
                let counts = try VoiceInkImport.dryRun(store: store, historyURL: HistoryStore.standardDatabaseURL, takesRoot: TakeStore.standard.root)
                print("VoiceInk has \(counts.found) takes; \(counts.new) are not in Vizier's history yet.")
                print("\(counts.audioFiles) of those have a recording, \(counts.audioBytes / 1_000_000) MB of WAV; as FLAC they take roughly half that.")
                return 0
            }
            let history = try HistoryStore.openStandard()
            let summary = try VoiceInkImport.run(store: store, history: history, takes: .standard, copyAudio: copyAudio) { so_far in
                print("… \(so_far.imported + so_far.alreadyThere) of \(so_far.found)")
            }
            print("VoiceInk takes found: \(summary.found). Imported: \(summary.imported). Already in history: \(summary.alreadyThere).")
            if copyAudio {
                print("Recordings copied as FLAC: \(summary.withAudio). Imported without audio (missing or would not convert): \(summary.audioFailed).")
            }
            return 0
        } catch {
            return fail(String(describing: error), code: 1)
        }
    }

    private static func fail(_ message: String, code: Int32) -> Int32 {
        FileHandle.standardError.write(Data("Vizier: \(message)\n".utf8))
        return code
    }
}
