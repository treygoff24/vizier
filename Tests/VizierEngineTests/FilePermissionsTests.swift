#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import VizierEngine

/// Vizier's folders are 0700 and its files 0600, fresh or left by an older build. Everything here
/// is in a temporary folder; the test process's umask (normally 022) is what would leave them open.
@Suite struct FilePermissionsTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "vizier-permissions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        try #require(stat(url.path, &info) == 0, "\(url.lastPathComponent) exists")
        return info.st_mode & 0o777
    }

    private func setMode(_ url: URL, _ mode: mode_t) throws {
        try #require(chmod(url.path, mode) == 0)
    }

    private func draft(_ id: String) -> TakeDraft {
        TakeDraft(id: id, startedAt: .now, destinationAtStart: nil, modeID: "scribe", transcriberEngine: "elevenlabs-scribe-realtime",
                  transcriberModel: "scribe_v2_realtime", fallbackEngine: nil, fallbackModel: nil, cleanerEngine: nil, cleanerModel: nil)
    }

    @Test func aNewHistoryIsPrivateWithItsWALAndSHM() throws {
        let data = root.appending(path: "Vizier")
        let database = data.appending(path: "history.sqlite")
        let store = try HistoryStore(databaseURL: database, takesRoot: data.appending(path: "Takes"))
        try store.begin(draft("2026-09-20T15-00-00.000Z"))
        #expect(try mode(data) == 0o700)
        #expect(try mode(database) == 0o600)
        #expect(try mode(URL(filePath: database.path + "-wal")) == 0o600)
        #expect(try mode(URL(filePath: database.path + "-shm")) == 0o600)
    }

    @Test func anOlderInstallIsTightenedOnOpenAndStillReads() throws {
        let data = root.appending(path: "Vizier")
        let database = data.appending(path: "history.sqlite")
        let takes = TakeStore(root: data.appending(path: "Takes"))
        let month = try takes.files(forID: "2026-09-20T15-00-00.000Z").directory
        do {
            let store = try HistoryStore(databaseURL: database, takesRoot: takes.root)
            try store.begin(draft("2026-09-20T15-00-00.000Z"))
        }
        // As an older build left them: default modes everywhere, the WAL and SHM still on disk.
        // (Created only when missing: the first store may still be open, waiting on its notification.)
        PrivateFiles.createFileIfMissing(URL(filePath: database.path + "-wal"))
        PrivateFiles.createFileIfMissing(URL(filePath: database.path + "-shm"))
        for url in [data, takes.root, month] { try setMode(url, 0o755) }
        for suffix in ["", "-wal", "-shm"] { try setMode(URL(filePath: database.path + suffix), 0o644) }

        let store = try HistoryStore(databaseURL: database, takesRoot: takes.root)
        #expect(try store.count() == 1)
        for url in [data, takes.root, month] { #expect(try mode(url) == 0o700, "\(url.lastPathComponent)") }
        for suffix in ["", "-wal", "-shm"] { #expect(try mode(URL(filePath: database.path + suffix)) == 0o600, "history.sqlite\(suffix)") }
    }

    @Test func takeFoldersArePrivate() throws {
        let takes = TakeStore(root: root.appending(path: "Takes"))
        let take = try takes.files(forID: "2026-09-20T15-00-00.000Z")
        #expect(try mode(takes.root) == 0o700)
        #expect(try mode(take.directory) == 0o700)
    }

    @Test func takeFoldersRecordingsAndFLACsArePrivate() throws {
        let takes = TakeStore(root: root.appending(path: "Takes"))
        let take = try takes.files(forID: "2026-09-20T15-00-00.000Z")
        #expect(try mode(takes.root) == 0o700)
        #expect(try mode(take.directory) == 0o700)
        #if canImport(AVFoundation)
        let file = try TakeStore.createRecording(take)
        #expect(try mode(take.recording) == 0o600)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        try file.write(from: buffer)
        file.close()
        #else
        let file = try TakeStore.createRecordingFile(take)
        #expect(try mode(take.recording) == 0o600, "private before the first sample")
        let silence = [Int16](repeating: 0, count: 8_000)
        try silence.withUnsafeBufferPointer { try file.append($0) }
        try file.close()
        #expect(try mode(take.recording) == 0o600, "and after the header is patched")
        #endif
        try takes.finishAudio(take)
        #expect(try mode(take.flac) == 0o600)
    }

    @Test func configFolderAndFilesArePrivateAndAnOlderOneIsTightened() throws {
        let fresh = ConfigStore(directory: root.appending(path: "config"))
        try fresh.writeStarterFilesIfMissing()
        #expect(try mode(fresh.directory) == 0o700)
        for url in [fresh.settingsURL, fresh.vocabularyURL, fresh.replacementsURL] { #expect(try mode(url) == 0o600, "\(url.lastPathComponent)") }
        let snapshot = try fresh.settingsSnapshot()
        _ = try fresh.setActiveMode("gemini-clean", expected: snapshot)
        #expect(try mode(fresh.settingsURL) == 0o600, "the atomic rewrite keeps the file private")

        let older = ConfigStore(directory: root.appending(path: "older"))
        try FileManager.default.createDirectory(at: older.directory, withIntermediateDirectories: true)
        try Data("# kept\n".utf8).write(to: older.vocabularyURL)
        try setMode(older.directory, 0o755)
        try setMode(older.vocabularyURL, 0o644)
        try older.writeStarterFilesIfMissing()
        #expect(try mode(older.directory) == 0o700)
        #expect(try mode(older.vocabularyURL) == 0o600)
        #expect(try String(contentsOf: older.vocabularyURL, encoding: .utf8) == "# kept\n", "an existing file is never rewritten")
    }
}
