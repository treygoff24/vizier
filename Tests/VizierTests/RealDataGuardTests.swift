import Foundation
import Testing
@testable import Vizier

@Suite struct RealDataGuardTests {
    private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    private func refuses(_ path: String) -> Bool {
        RealDataGuard.refuses(URL(filePath: path, directoryHint: .isDirectory), home: home)
    }

    @Test func theRealDataFoldersAndTheHomeFolderAreRefused() {
        #expect(refuses("/Users/someone"))
        #expect(refuses("/Users/someone/Library/Application Support/Vizier"))
        #expect(refuses("/Users/someone/.config/vizier"))
    }

    @Test func theDictumEraFoldersAreRefusedUntilTheyMove() {
        // Vizier was called Dictum until 2026-10-03; the data stays there until the new build first runs.
        #expect(refuses("/Users/someone/Library/Application Support/Dictum"))
        #expect(refuses("/Users/someone/.config/dictum"))
        #expect(refuses("/Users/someone/Library/Application Support/Dictum/Takes"))
        #expect(!refuses("/Users/someone/.config/dictum2"))
    }

    @Test func anythingInsideTheRealDataFoldersIsRefused() {
        #expect(refuses("/Users/someone/Library/Application Support/Vizier/Takes"))
        #expect(refuses("/Users/someone/.config/vizier/preview/config"))
    }

    @Test func aSiblingWithTheSamePrefixIsNotMistakenForTheRealFolder() {
        #expect(!refuses("/Users/someone/Library/Application Support/Vizier-preview"))
        #expect(!refuses("/Users/someone/.config/vizier2"))
    }

    @Test func otherFoldersAreAllowed() {
        #expect(!refuses("/tmp/vizier-preview"))
        #expect(!refuses("/Users/someone/Desktop/preview"))
    }
}

/// The nested destinations, on a real temporary tree: a fake home whose data folder stands in for
/// the real one, and a preview folder beside it.
@Suite struct RealDataGuardChildTests {
    private let home: URL
    private let data: URL
    private let preview: URL
    private let children = ["config", "Takes", "history.sqlite", "history.sqlite-wal", "shot.png"]

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vizier-guard-\(UUID().uuidString)")
        home = root.appending(path: "home")
        data = home.appending(path: "Library/Application Support/Vizier")
        preview = home.appending(path: "Desktop/preview")
        try FileManager.default.createDirectory(at: data.appending(path: "Takes/2026-09"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        try Data("stand-in".utf8).write(to: data.appending(path: "history.sqlite"))
    }

    private func refused() -> String? {
        RealDataGuard.refusedChild(in: preview, writing: children, home: home)
    }

    private func link(_ child: String, to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: preview.appending(path: child), withDestinationURL: target)
    }

    @Test func plainChildrenAndMissingOnesAreAllowed() throws {
        #expect(refused() == nil, "nothing there yet")
        try FileManager.default.createDirectory(at: preview.appending(path: "Takes/2026-09"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: preview.appending(path: "Takes/2026-09/a.flac"))
        try Data("x".utf8).write(to: preview.appending(path: "history.sqlite"))
        #expect(refused() == nil)
    }

    @Test func aSymlinkedChildIsRefusedWhereverItPoints() throws {
        try link("history.sqlite", to: data.appending(path: "history.sqlite"))
        #expect(refused() == "history.sqlite")
        try FileManager.default.removeItem(at: preview.appending(path: "history.sqlite"))
        try link("shot.png", to: home.appending(path: "Desktop/elsewhere.png"))
        #expect(refused() == "shot.png", "a dangling link would be written through too")
    }

    @Test func aSymlinkDeepInsideAChildFolderIsRefused() throws {
        try FileManager.default.createDirectory(at: preview.appending(path: "Takes"), withIntermediateDirectories: true)
        try link("Takes/2026-09", to: data.appending(path: "Takes/2026-09"))
        #expect(refused() == "Takes/2026-09")
    }

    @Test func aHardLinkToAFileIsRefused() throws {
        try FileManager.default.linkItem(at: data.appending(path: "history.sqlite"), to: preview.appending(path: "history.sqlite"))
        #expect(refused() == "history.sqlite")
    }
}
