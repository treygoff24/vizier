import Darwin
import Foundation
import os

/// Vizier was called Dictum until 2026-10-03. Its data lived in `~/Library/Application Support/Dictum/`
/// and its settings in `~/.config/dictum/`, with `dictum.jsonc` as the settings file. This moves them
/// to the new names once, at launch, before anything opens them.
///
/// For each folder: when the new one is missing and the old one is there, the old one is renamed to
/// the new name. A rename within one folder stays on one volume, so it is atomic, and it keeps every
/// permission (0700 folders, 0600 files) and every file inside as it was. When both are there,
/// neither is touched: someone has data in each, and only a person can say which to keep (an old
/// folder with nothing in it is no conflict, and is left where it is). Then, when the settings
/// folder has `dictum.jsonc` and no `vizier.jsonc`, the file is renamed the same way; when it has
/// both, both stay, as a conflict. Every rename refuses to replace anything already at the new
/// name, so nothing is ever deleted or overwritten. The log names fixed paths under the home folder
/// and outcomes, never contents.
///
/// The app must not start on an outcome that `blocksLaunch`: it would create the new folders or a
/// default `vizier.jsonc` beside data that did not move, and the next launch could no longer move it.
public enum UserDataMigration {
    /// A folder's old and new paths, relative to the home folder.
    public struct Folder: Sendable, Equatable {
        public let old: String
        public let new: String
    }

    public static let dataFolder = Folder(old: "Library/Application Support/Dictum", new: "Library/Application Support/Vizier")
    public static let settingsFolder = Folder(old: ".config/dictum", new: ".config/vizier")
    public static let folders = [dataFolder, settingsFolder]
    public static let legacySettingsFile = "dictum.jsonc"
    public static let settingsFile = "vizier.jsonc"

    public enum Outcome: Sendable, Equatable {
        /// The old path was renamed to the new one (paths relative to the home folder).
        case moved(from: String, to: String)
        /// Both paths exist; neither was touched.
        case bothPresent(old: String, new: String)
        /// A rename failed with this errno; the old path is as it was.
        case failed(from: String, to: String, errno: Int32)
        /// Both folders exist, but the old one holds nothing (a Finder `.DS_Store` at most); neither
        /// was touched, and the new one is used.
        case oldEmpty(old: String, new: String)

        /// True when the app must stop before it opens or creates anything: a failed rename or a
        /// conflict leaves the user's data at a path the app would not read, and starting would
        /// bury it under new, empty folders and files. A launch after the user resolves it retries.
        public var blocksLaunch: Bool {
            switch self {
            case .moved, .oldEmpty: false
            case .bothPresent, .failed: true
            }
        }
    }

    private static let log = Logger(subsystem: "net.praxient.dictum", category: "migration")

    /// Runs the migration under `home` and returns what it did; an empty list means there was
    /// nothing to move. Safe to run on every launch: once moved, the old paths are gone.
    @discardableResult
    public static func run(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Outcome] {
        var outcomes: [Outcome] = []
        var settingsReady = true
        for folder in folders {
            let oldThere = exists(home.appending(path: folder.old))
            let newThere = exists(home.appending(path: folder.new))
            guard oldThere else { continue }
            let outcome: Outcome = if !newThere {
                rename(folder.old, to: folder.new, in: home)
            } else if isEmptyFolder(home.appending(path: folder.old)) {
                .oldEmpty(old: folder.old, new: folder.new)
            } else {
                .bothPresent(old: folder.old, new: folder.new)
            }
            if outcome.blocksLaunch, folder == settingsFolder { settingsReady = false }
            outcomes.append(outcome)
        }
        // A settings folder left alone (both present, or a failed move) is left wholly alone.
        if settingsReady {
            let legacy = settingsFolder.new + "/" + legacySettingsFile
            let current = settingsFolder.new + "/" + settingsFile
            if exists(home.appending(path: legacy)) {
                // Both files: the user's Dictum settings are in one, and only they can say which to keep.
                outcomes.append(exists(home.appending(path: current)) ? .bothPresent(old: legacy, new: current) : rename(legacy, to: current, in: home))
            }
        }
        for outcome in outcomes { record(outcome) }
        return outcomes
    }

    /// True when a folder still waits to be moved: the old one is there and the new one is not.
    public static func isPending(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        folders.contains { exists(home.appending(path: $0.old)) && !exists(home.appending(path: $0.new)) }
    }

    /// True when anything is at `url`, a symlink included (a dangling one too).
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// True when `url` is a folder with nothing in it but, at most, Finder's `.DS_Store`. Anything
    /// unreadable counts as not empty.
    private static func isEmptyFolder(_ url: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return names.allSatisfy { $0 == ".DS_Store" }
    }

    private static func rename(_ old: String, to new: String, in home: URL) -> Outcome {
        // RENAME_EXCL: fail rather than replace anything that appeared at the new path meanwhile.
        if renamex_np(home.appending(path: old).path, home.appending(path: new).path, UInt32(RENAME_EXCL)) == 0 {
            return .moved(from: old, to: new)
        }
        return .failed(from: old, to: new, errno: errno)
    }

    private static func record(_ outcome: Outcome) {
        switch outcome {
        case .moved(let from, let to):
            log.notice("moved ~/\(from, privacy: .public) to ~/\(to, privacy: .public)")
        case .bothPresent(let old, let new):
            log.notice("both ~/\(old, privacy: .public) and ~/\(new, privacy: .public) exist; left both alone")
        case .failed(let from, let to, let code):
            log.error("could not move ~/\(from, privacy: .public) to ~/\(to, privacy: .public): errno \(code, privacy: .public); left it in place")
        case .oldEmpty(let old, let new):
            log.notice("~/\(old, privacy: .public) is empty beside ~/\(new, privacy: .public); left it alone")
        }
    }
}
