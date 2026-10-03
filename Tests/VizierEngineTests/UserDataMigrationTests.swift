#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import VizierEngine

/// The Dictum-to-Vizier move, against a temporary home folder. Every file holds synthetic text.
@Suite struct UserDataMigrationTests {
    private let home: URL
    private let oldData: URL, newData: URL, oldConfig: URL, newConfig: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "vizier-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        oldData = home.appending(path: "Library/Application Support/Dictum")
        newData = home.appending(path: "Library/Application Support/Vizier")
        oldConfig = home.appending(path: ".config/dictum")
        newConfig = home.appending(path: ".config/vizier")
        // The parents exist on every Mac; the app folders do not.
        try FileManager.default.createDirectory(at: home.appending(path: "Library/Application Support"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".config"), withIntermediateDirectories: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try PrivateFiles.makeDirectory(url.deletingLastPathComponent())
        try Data(text.utf8).write(to: url)
        try PrivateFiles.restrict(url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o7777 : 0
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Dictum's layout as an installed Dictum left it.
    private func makeOldLayout() throws {
        try write("history stand-in", to: oldData.appending(path: "history.sqlite"))
        try write("audio stand-in", to: oldData.appending(path: "Takes/2026-09/take.flac"))
        try write("{ \"mode\": \"apple\" }", to: oldConfig.appending(path: "dictum.jsonc"))
        try write("Zorblex", to: oldConfig.appending(path: "vocabulary.txt"))
        try write("zorb -> Zorblex", to: oldConfig.appending(path: "replacements.txt"))
    }

    @Test func aFreshInstallHasNothingToMoveAndCreatesNothing() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(UserDataMigration.run(home: home).isEmpty)
        #expect(!UserDataMigration.isPending(home: home))
        for folder in [oldData, newData, oldConfig, newConfig] { #expect(!exists(folder)) }
    }

    @Test func theOldFoldersMoveWholeWithTheirPermissionsAndTheSettingsFileIsRenamed() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeOldLayout()
        #expect(UserDataMigration.isPending(home: home))
        let outcomes = UserDataMigration.run(home: home)
        #expect(outcomes == [
            .moved(from: "Library/Application Support/Dictum", to: "Library/Application Support/Vizier"),
            .moved(from: ".config/dictum", to: ".config/vizier"),
            .moved(from: ".config/vizier/dictum.jsonc", to: ".config/vizier/vizier.jsonc"),
        ])
        #expect(!exists(oldData) && !exists(oldConfig))
        #expect(read(newData.appending(path: "history.sqlite")) == "history stand-in")
        #expect(read(newData.appending(path: "Takes/2026-09/take.flac")) == "audio stand-in")
        #expect(read(newConfig.appending(path: "vizier.jsonc")) == "{ \"mode\": \"apple\" }")
        #expect(!exists(newConfig.appending(path: "dictum.jsonc")))
        #expect(read(newConfig.appending(path: "vocabulary.txt")) == "Zorblex")
        #expect(read(newConfig.appending(path: "replacements.txt")) == "zorb -> Zorblex")
        #expect(mode(newData) == 0o700 && mode(newConfig) == 0o700 && mode(newData.appending(path: "Takes/2026-09")) == 0o700)
        #expect(mode(newData.appending(path: "history.sqlite")) == 0o600 && mode(newConfig.appending(path: "vizier.jsonc")) == 0o600)
        // A second launch finds nothing left to do.
        #expect(UserDataMigration.run(home: home).isEmpty)
        #expect(!UserDataMigration.isPending(home: home))
    }

    @Test func onlyTheNewFoldersPresentIsLeftAsItIs() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try write("new history", to: newData.appending(path: "history.sqlite"))
        try write("{ }", to: newConfig.appending(path: "vizier.jsonc"))
        #expect(UserDataMigration.run(home: home).isEmpty)
        #expect(read(newData.appending(path: "history.sqlite")) == "new history")
        #expect(read(newConfig.appending(path: "vizier.jsonc")) == "{ }")
        #expect(!exists(oldData) && !exists(oldConfig))
    }

    @Test func whenBothOldAndNewArePresentNeitherIsTouched() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeOldLayout()
        try write("new history", to: newData.appending(path: "history.sqlite"))
        // A stray dictum.jsonc in the new settings folder stays put too: that folder is left wholly alone.
        try write("{ \"stray\": 1 }", to: newConfig.appending(path: "dictum.jsonc"))
        let outcomes = UserDataMigration.run(home: home)
        #expect(outcomes == [
            .bothPresent(old: "Library/Application Support/Dictum", new: "Library/Application Support/Vizier"),
            .bothPresent(old: ".config/dictum", new: ".config/vizier"),
        ])
        #expect(read(oldData.appending(path: "history.sqlite")) == "history stand-in")
        #expect(read(oldData.appending(path: "Takes/2026-09/take.flac")) == "audio stand-in")
        #expect(read(newData.appending(path: "history.sqlite")) == "new history")
        #expect(read(oldConfig.appending(path: "dictum.jsonc")) == "{ \"mode\": \"apple\" }")
        #expect(read(newConfig.appending(path: "dictum.jsonc")) == "{ \"stray\": 1 }")
        #expect(!exists(newConfig.appending(path: "vizier.jsonc")))
    }

    @Test func aDictumJsoncAloneInTheNewFolderIsRenamed() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try write("{ \"mode\": \"scribe\" }", to: newConfig.appending(path: "dictum.jsonc"))
        #expect(UserDataMigration.run(home: home) == [.moved(from: ".config/vizier/dictum.jsonc", to: ".config/vizier/vizier.jsonc")])
        #expect(read(newConfig.appending(path: "vizier.jsonc")) == "{ \"mode\": \"scribe\" }")
        #expect(mode(newConfig.appending(path: "vizier.jsonc")) == 0o600)
        #expect(!exists(newConfig.appending(path: "dictum.jsonc")))
    }

    @Test func aDictumJsoncBesideAVizierJsoncIsLeftAloneAsAConflict() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try write("{ \"old\": 1 }", to: newConfig.appending(path: "dictum.jsonc"))
        try write("{ \"new\": 1 }", to: newConfig.appending(path: "vizier.jsonc"))
        let outcomes = UserDataMigration.run(home: home)
        #expect(outcomes == [.bothPresent(old: ".config/vizier/dictum.jsonc", new: ".config/vizier/vizier.jsonc")])
        #expect(outcomes.contains { $0.blocksLaunch })
        #expect(read(newConfig.appending(path: "dictum.jsonc")) == "{ \"old\": 1 }")
        #expect(read(newConfig.appending(path: "vizier.jsonc")) == "{ \"new\": 1 }")
    }

    // What the app does with each outcome: a launch stops on a failure or a conflict, so nothing
    // new is created beside data that did not move, and the next launch tries again.

    @Test func onlyAMoveOrAnEmptyOldFolderLetsTheAppStart() {
        #expect(!UserDataMigration.Outcome.moved(from: "a", to: "b").blocksLaunch)
        #expect(!UserDataMigration.Outcome.oldEmpty(old: "a", new: "b").blocksLaunch)
        #expect(UserDataMigration.Outcome.bothPresent(old: "a", new: "b").blocksLaunch)
        #expect(UserDataMigration.Outcome.failed(from: "a", to: "b", errno: EACCES).blocksLaunch)
    }

    /// Runs `body` with `folder` read-only, so a rename into or out of it fails, then restores it.
    private func readOnly(_ folder: URL, _ body: () throws -> Void) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        try body()
    }

    @Test func aFolderThatCannotMoveBlocksTheLaunchAndMovesOnTheNextOne() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeOldLayout()
        let parent = home.appending(path: ".config")
        try readOnly(parent) {
            let outcomes = UserDataMigration.run(home: home)
            #expect(outcomes == [
                .moved(from: "Library/Application Support/Dictum", to: "Library/Application Support/Vizier"),
                .failed(from: ".config/dictum", to: ".config/vizier", errno: EACCES),
            ])
            #expect(outcomes.contains { $0.blocksLaunch })
            // The settings stay where they were, untouched, and nothing was made at the new path.
            #expect(read(oldConfig.appending(path: "dictum.jsonc")) == "{ \"mode\": \"apple\" }")
            #expect(!exists(newConfig))
        }
        // The next launch, with the folder writable again, finishes the job.
        #expect(UserDataMigration.run(home: home) == [
            .moved(from: ".config/dictum", to: ".config/vizier"),
            .moved(from: ".config/vizier/dictum.jsonc", to: ".config/vizier/vizier.jsonc"),
        ])
        #expect(read(newConfig.appending(path: "vizier.jsonc")) == "{ \"mode\": \"apple\" }")
    }

    @Test func aSettingsFileThatCannotBeRenamedBlocksTheLaunchAndIsRenamedOnTheNextOne() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try write("{ \"mode\": \"scribe\" }", to: newConfig.appending(path: "dictum.jsonc"))
        try readOnly(newConfig) {
            let outcomes = UserDataMigration.run(home: home)
            #expect(outcomes == [.failed(from: ".config/vizier/dictum.jsonc", to: ".config/vizier/vizier.jsonc", errno: EACCES)])
            #expect(outcomes.contains { $0.blocksLaunch })
            #expect(!exists(newConfig.appending(path: "vizier.jsonc")))
        }
        #expect(UserDataMigration.run(home: home) == [.moved(from: ".config/vizier/dictum.jsonc", to: ".config/vizier/vizier.jsonc")])
        #expect(read(newConfig.appending(path: "vizier.jsonc")) == "{ \"mode\": \"scribe\" }")
    }

    @Test func anEmptyOldFolderBesideTheNewOneIsNoConflict() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try PrivateFiles.makeDirectory(oldData)
        try write("Finder", to: oldData.appending(path: ".DS_Store"))
        try write("new history", to: newData.appending(path: "history.sqlite"))
        try PrivateFiles.makeDirectory(oldConfig)
        try write("{ \"mode\": \"scribe\" }", to: newConfig.appending(path: "dictum.jsonc"))
        let outcomes = UserDataMigration.run(home: home)
        #expect(outcomes == [
            .oldEmpty(old: "Library/Application Support/Dictum", new: "Library/Application Support/Vizier"),
            .oldEmpty(old: ".config/dictum", new: ".config/vizier"),
            // The new settings folder is the one in use, so its dictum.jsonc still gets its new name.
            .moved(from: ".config/vizier/dictum.jsonc", to: ".config/vizier/vizier.jsonc"),
        ])
        #expect(!outcomes.contains { $0.blocksLaunch })
        #expect(exists(oldData.appending(path: ".DS_Store")) && exists(oldConfig))
        #expect(read(newData.appending(path: "history.sqlite")) == "new history")
    }

    @Test func anOldFolderWithAnythingInItIsAConflict() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try write("one take", to: oldData.appending(path: "Takes/x.caf"))
        try write("new history", to: newData.appending(path: "history.sqlite"))
        let outcomes = UserDataMigration.run(home: home)
        #expect(outcomes == [.bothPresent(old: "Library/Application Support/Dictum", new: "Library/Application Support/Vizier")])
        #expect(outcomes.contains { $0.blocksLaunch })
    }
}
#endif
