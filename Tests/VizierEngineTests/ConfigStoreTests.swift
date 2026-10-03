import Foundation
import Testing
@testable import VizierEngine

@Suite struct ConfigStoreTests {
    private let store: ConfigStore

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vizier-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigStore(directory: dir)
    }

    private func write(_ url: URL, _ text: String) throws {
        try Data(text.utf8).write(to: url)
    }

    @Test func missingFilesMeanDefaultsAndNoErrors() {
        let load = store.load()
        #expect(load.errors.isEmpty)
        #expect(load.config == VizierConfig())
        #expect(load.config.activeMode == .apple)
        #expect(load.config.settings.modes.map(\.id) == ["apple", "scribe", "gemini-clean", "gemini-smart"])
    }

    @Test func theStarterFilesParseToTheDefaults() throws {
        try store.writeStarterFilesIfMissing()
        let load = store.load()
        #expect(load.errors.isEmpty)
        #expect(load.config == VizierConfig())
    }

    @Test func starterFilesNeverOverwriteEdits() throws {
        try write(store.vocabularyURL, "Zorblex\n")
        try store.writeStarterFilesIfMissing()
        #expect(try String(contentsOf: store.vocabularyURL, encoding: .utf8) == "Zorblex\n")
    }

    @Test func readsCommentsTrailingCommasAndSnakeCaseKeys() throws {
        try write(store.settingsURL, """
        // comment
        { "mode": "b", "modes": [
          { "id": "a", "name": "A", "transcriber": { "engine": "gemini-live", "model": "m", "mode": "SMART", "languages": [], "final_timeout_ms": 900, }, },
          { "id": "b", "name": "B", "transcriber": { "engine": "gemini-live", "model": "m2", "mode": "VERBATIM", "languages": ["en-GB"], "final_timeout_ms": 1200 } },
        ] }
        """)
        let load = store.load()
        #expect(load.errors.isEmpty)
        #expect(load.config.activeMode.id == "b")
        #expect(load.config.activeMode.transcriber.finalTimeoutMs == 1200)
        #expect(load.config.activeMode.fallback == nil)
    }

    @Test func aBrokenFileKeepsTheLastGoodConfig() throws {
        try write(store.vocabularyURL, "Zorblex\nQuaxil\n")
        try write(store.replacementsURL, "zorbex -> Zorblex\n")
        let good = store.load()
        #expect(good.errors.isEmpty)

        try write(store.settingsURL, "{ \"mode\": \"gemini-smart\", \"modes\": [ ")
        try write(store.vocabularyURL, "Changed\n")
        let broken = store.load()
        #expect(broken.errors.count == 1)
        #expect(broken.config == good.config)

        try FileManager.default.removeItem(at: store.settingsURL)
        try write(store.replacementsURL, "no arrow here\n")
        let brokenAgain = store.load()
        #expect(brokenAgain.errors == [.replacements("replacements.txt line 1: missing \"->\" between the words and their replacement")])
        #expect(brokenAgain.config == good.config)

        try write(store.replacementsURL, "zorbex -> Zorblex\n")
        let fixed = store.load()
        #expect(fixed.errors.isEmpty)
        #expect(fixed.config.vocabulary == ["Changed"])
    }

    @Test func aBrokenFirstLoadFallsBackToDefaults() throws {
        try write(store.settingsURL, "not json")
        let load = store.load()
        #expect(load.errors.count == 1)
        #expect(load.config == VizierConfig())
    }

    @Test func rejectsAModeNameWithNoMatchingMode() throws {
        try write(store.settingsURL, #"{ "mode": "nope", "modes": [ { "id": "a", "name": "A", "transcriber": { "engine": "gemini-live", "model": "m", "mode": "SMART", "languages": [], "final_timeout_ms": 900 } } ] }"#)
        #expect(store.load().errors == [.settings("\"mode\" names \"nope\", which no entry in \"modes\" has as its id")])
    }

    @Test func rejectsEnginesThisBuildCannotRun() throws {
        let live = #"{ "engine": "gemini-live", "model": "m", "mode": "SMART", "languages": [], "final_timeout_ms": 900 }"#
        let typo = #"{ "engine": "gemini-lvie", "model": "m", "mode": "SMART", "languages": [], "final_timeout_ms": 900 }"#
        try write(store.settingsURL, #"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": \#(typo) } ] }"#)
        #expect(store.load().errors == [.settings("mode \"a\" names transcriber engine \"gemini-lvie\"; this build knows \"gemini-live\", \"elevenlabs-scribe-realtime\", \"apple-speech\", \"gemini-batch\", \"elevenlabs-scribe-batch\", \"local-whisper\", \"apple-speech-batch\"")])
        try write(store.settingsURL, #"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": \#(live), "fallback": { "engine": "scribe", "model": "m", "mode": "x" } } ] }"#)
        #expect(store.load().errors == [.settings("mode \"a\" names fallback engine \"scribe\"; this build knows \"gemini-batch\", \"elevenlabs-scribe-batch\", \"local-whisper\", \"apple-speech-batch\"")])
    }

    @Test func acceptsScribeBatchAsAFallbackOnlyInVerbatim() throws {
        let live = #"{ "engine": "elevenlabs-scribe-realtime", "model": "m", "mode": "verbatim", "languages": ["en"], "final_timeout_ms": 900 }"#
        try write(store.settingsURL, #"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": \#(live), "fallback": { "engine": "elevenlabs-scribe-batch", "model": "scribe_v2", "mode": "verbatim" } } ] }"#)
        let load = store.load()
        #expect(load.errors == [])
        #expect(load.config.activeMode.fallback?.engine == "elevenlabs-scribe-batch")
        try write(store.settingsURL, #"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": \#(live), "fallback": { "engine": "elevenlabs-scribe-batch", "model": "scribe_v2", "mode": "smart" } } ] }"#)
        #expect(store.load().errors == [.settings("mode \"a\" gives Scribe batch the mode \"smart\"; Scribe batch knows \"verbatim\"")])
    }

    @Test func readsACleanupPassAndLeavesItOptional() throws {
        let live = #"{ "engine": "gemini-live", "model": "m", "mode": "VERBATIM", "languages": [], "final_timeout_ms": 900 }"#
        try write(store.settingsURL, #"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": \#(live), "cleanup": { "engine": "gemini-generate", "model": "lite", "thinking_level": "MINIMAL", "timeout_ms": 3000 } } ] }"#)
        #expect(store.load().config.activeMode.cleanup == .init(engine: "gemini-generate", model: "lite", thinkingLevel: "MINIMAL", timeoutMs: 3000))
        try write(store.settingsURL, #"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": \#(live), "cleanup": { "engine": "gemini-generate", "model": "lite", "timeout_ms": 3000 } } ] }"#)
        #expect(store.load().config.activeMode.cleanup?.thinkingLevel == nil)
    }

    @Test func rejectsACleanupThisBuildCannotRunOrThatNeverWaits() throws {
        let live = #"{ "engine": "gemini-live", "model": "m", "mode": "VERBATIM", "languages": [], "final_timeout_ms": 900 }"#
        try write(store.settingsURL, #"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": \#(live), "cleanup": { "engine": "gpt", "model": "x", "timeout_ms": 3000 } } ] }"#)
        #expect(store.load().errors == [.settings("mode \"a\" names cleanup engine \"gpt\"; this build knows \"gemini-generate\", \"local-cleanup\"")])
        try write(store.settingsURL, #"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": \#(live), "cleanup": { "engine": "gemini-generate", "model": "x", "timeout_ms": 0 } } ] }"#)
        #expect(store.load().errors == [.settings("mode \"a\" has a cleanup timeout_ms of 0")])
    }

    @Test func readsALocalModeWithNoLiveStreamAndAnOfflineFallback() throws {
        let local = #"{ "engine": "local-whisper", "model": "large-v3-turbo", "mode": "verbatim", "languages": ["en"], "final_timeout_ms": 4000 }"#
        let cleanup = #"{ "engine": "local-cleanup", "model": "q", "timeout_ms": 8000, "url": "http://[::1]:9000/v1/chat/completions" }"#
        try write(store.settingsURL, #"{ "mode": "l", "modes": [ { "id": "l", "name": "Local", "transcriber": \#(local), "cleanup": \#(cleanup) } ] }"#)
        let load = store.load()
        #expect(load.errors == [])
        #expect(load.config.activeMode.isBatchOnly)
        #expect(load.config.activeMode.batchChain.map(\.engine) == ["local-whisper"])
        #expect(load.config.activeMode.cleanup?.url == "http://[::1]:9000/v1/chat/completions")

        let scribe = #"{ "engine": "elevenlabs-scribe-realtime", "model": "m", "mode": "verbatim", "languages": ["en"], "final_timeout_ms": 900 }"#
        let fallback = #"{ "engine": "elevenlabs-scribe-batch", "model": "scribe_v2", "mode": "verbatim" }"#
        let offline = #"{ "engine": "local-whisper", "model": "large-v3-turbo", "mode": "verbatim" }"#
        try write(store.settingsURL, #"{ "mode": "s", "modes": [ { "id": "s", "name": "S", "transcriber": \#(scribe), "fallback": \#(fallback), "offline_fallback": \#(offline) } ] }"#)
        let chained = store.load()
        #expect(chained.errors == [])
        #expect(!chained.config.activeMode.isBatchOnly)
        #expect(chained.config.activeMode.batchChain.map(\.engine) == ["elevenlabs-scribe-batch", "local-whisper"])
    }

    @Test func aLocalEngineCanOnlyBePointedAtThisMac() throws {
        func local(_ url: String) -> String {
            #"{ "mode": "l", "modes": [ { "id": "l", "name": "L", "transcriber": { "engine": "local-whisper", "model": "t", "mode": "verbatim", "languages": [], "final_timeout_ms": 900, "url": "\#(url)" } } ] }"#
        }
        try write(store.settingsURL, local("http://127.0.0.1:8738/v1/audio/transcriptions"))
        #expect(store.load().errors == [])
        for away in ["https://api.example.com/v1/audio/transcriptions", "http://192.168.1.5:8738/x", "http://127.0.0.1.example.com/x", "http://localhost:8738/x"] {
            try write(store.settingsURL, local(away))
            #expect(store.load().errors == [.settings("mode \"l\" points \"local-whisper\" at \(away); a local engine must use http on 127.0.0.1 or [::1]")])
        }
        let live = #"{ "engine": "gemini-live", "model": "m", "mode": "SMART", "languages": [], "final_timeout_ms": 900, "url": "http://127.0.0.1:1/x" }"#
        try write(store.settingsURL, #"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": \#(live) } ] }"#)
        #expect(store.load().errors == [.settings("mode \"a\" gives \"gemini-live\" a url; only a local engine takes one")])
        let cloudOffline = #"{ "engine": "gemini-batch", "model": "m", "mode": "verbatim" }"#
        try write(store.settingsURL, #"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": { "engine": "gemini-live", "model": "m", "mode": "SMART", "languages": [], "final_timeout_ms": 900 }, "offline_fallback": \#(cloudOffline) } ] }"#)
        #expect(store.load().errors == [.settings("mode \"a\" names offline_fallback engine \"gemini-batch\"; it must run on this Mac, and this build knows \"local-whisper\", \"apple-speech-batch\"")])
    }

    @Test func readsAScribeModeWithTheFillerFilter() throws {
        let scribe = #"{ "engine": "elevenlabs-scribe-realtime", "model": "scribe_v2_realtime", "mode": "verbatim", "languages": ["en"], "final_timeout_ms": 3000 }"#
        try write(store.settingsURL, #"{ "mode": "s", "modes": [ { "id": "s", "name": "S", "transcriber": \#(scribe), "remove_fillers": true } ] }"#)
        let load = store.load()
        #expect(load.errors.isEmpty)
        #expect(load.config.activeMode.transcriber.engine == "elevenlabs-scribe-realtime")
        #expect(load.config.activeMode.removeFillers == true)
        let gemini = #"{ "engine": "gemini-live", "model": "m", "mode": "VERBATIM", "languages": [], "final_timeout_ms": 900 }"#
        try write(store.settingsURL, #"{ "mode": "g", "modes": [ { "id": "g", "name": "G", "transcriber": \#(gemini) } ] }"#)
        #expect(store.load().config.activeMode.removeFillers == nil)
    }

    @Test func rejectsAScribeModeScribeDoesNotHave() throws {
        let scribe = #"{ "engine": "elevenlabs-scribe-realtime", "model": "scribe_v2_realtime", "mode": "SMART", "languages": ["en"], "final_timeout_ms": 3000 }"#
        try write(store.settingsURL, #"{ "mode": "s", "modes": [ { "id": "s", "name": "S", "transcriber": \#(scribe) } ] }"#)
        #expect(store.load().errors == [.settings("mode \"s\" gives Scribe the mode \"SMART\"; Scribe knows \"verbatim\", \"no_verbatim\"")])
    }

    @Test func namesAMissingKeyInTheFilesOwnSpelling() throws {
        try write(store.settingsURL, #"{ "mode": "a", "modes": [ { "id": "a", "name": "A", "transcriber": { "engine": "gemini-live", "model": "m", "mode": "SMART", "languages": [] } } ] }"#)
        #expect(store.load().errors == [.settings("missing \"final_timeout_ms\" at modes[0].transcriber")])
    }

    @Test func vocabularySkipsCommentsBlanksAndRepeats() throws {
        try write(store.vocabularyURL, "# terms\nZorblex\n\n  Quaxil  \nzorblex\n")
        #expect(store.load().config.vocabulary == ["Zorblex", "Quaxil"])
    }

    @Test func vocabularyOverTheLimitIsRejected() throws {
        try write(store.vocabularyURL, (0...1_000).map { "term\($0)" }.joined(separator: "\n"))
        #expect(store.load().errors == [.vocabulary("1001 terms; Gemini accepts at most 1000")])
    }

    // MARK: setActiveMode

    @Test func switchingTheModeRewritesOneValueAndKeepsTheComments() throws {
        try store.writeStarterFilesIfMissing()
        let before = try store.settingsSnapshot()
        let after = try store.setActiveMode("gemini-clean", expected: before)
        #expect(after.settings.mode == "gemini-clean")
        let text = try String(contentsOf: store.settingsURL, encoding: .utf8)
        #expect(text == ConfigStore.starterSettings.replacingOccurrences(of: "\"mode\": \"apple\",", with: "\"mode\": \"gemini-clean\","))
        #expect(store.load().config.activeMode.id == "gemini-clean")
        #expect(try store.settingsSnapshot() == after)
    }

    @Test func anUnknownModeIsRefusedAndTheFileIsUntouched() throws {
        try store.writeStarterFilesIfMissing()
        let before = try store.settingsSnapshot()
        #expect(throws: ModeWriteError.unknownMode("nope")) { try store.setActiveMode("nope", expected: before) }
        #expect(try Data(contentsOf: store.settingsURL) == before.bytes)
    }

    @Test func aFileChangedSinceTheSnapshotIsNotOverwritten() throws {
        try store.writeStarterFilesIfMissing()
        let before = try store.settingsSnapshot()
        let edited = ConfigStore.starterSettings + "// an agent's note\n"
        try write(store.settingsURL, edited)
        #expect(throws: ModeWriteError.changedOnDisk) { try store.setActiveMode("gemini-clean", expected: before) }
        #expect(try String(contentsOf: store.settingsURL, encoding: .utf8) == edited)
    }

    @Test func aBrokenFileHasNoSnapshotToEdit() throws {
        try write(store.settingsURL, "{ \"mode\": \"scribe\" ")
        #expect(throws: ConfigError.self) { try store.settingsSnapshot() }
    }

    @Test func aMissingFileHasNoSnapshotToEdit() {
        #expect { try store.settingsSnapshot() } throws: { error in
            if case ModeWriteError.io = error { return true }
            return false
        }
    }

    @Test func aFileThatIsNotUTF8IsNeverRewritten() throws {
        // A lossy decode would replace the bad byte with U+FFFD and write that back, changing a
        // comment the editor was supposed to leave alone.
        var bytes = Data(ConfigStore.starterSettings.utf8)
        bytes.insert(contentsOf: [0x2F, 0x2F, 0xFF, 0x0A], at: 0)
        try bytes.write(to: store.settingsURL)
        #expect(throws: ModeWriteError.edit("the settings file is not UTF-8")) { try store.settingsSnapshot() }
        #expect(try Data(contentsOf: store.settingsURL) == bytes)
    }
}
