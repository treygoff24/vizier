import Foundation

/// The parsed contents of `~/.config/vizier/`: `vizier.jsonc` plus `vocabulary.txt` and
/// `replacements.txt`, which are line files so people and scripts can edit them one entry at a time.
public struct VizierConfig: Sendable, Equatable {
    public var settings: Settings
    public var vocabulary: [String]
    public var replacements: [ReplacementRule]

    public init(settings: Settings = Settings(), vocabulary: [String] = [], replacements: [ReplacementRule] = []) {
        self.settings = settings
        self.vocabulary = vocabulary
        self.replacements = replacements
    }

    /// The mode takes run through: the one `mode` names.
    public var activeMode: Mode {
        settings.modes.first { $0.id == settings.mode } ?? settings.modes[0]
    }

    /// `vizier.jsonc`, read as JSON5 so it can carry comments and trailing commas. Keys are
    /// snake_case in the file.
    public struct Settings: Codable, Sendable, Equatable {
        public var mode: String
        public var modes: [Mode]

        public init(mode: String = Mode.apple.id, modes: [Mode] = [.apple, .scribe, .geminiClean, .geminiSmart]) {
            self.mode = mode
            self.modes = modes
        }
    }

    public struct Mode: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var transcriber: Transcriber
        public var fallback: Fallback?
        /// A text pass over whichever transcript arrives, live or batch, before word replacements.
        public var cleanup: Cleanup?
        /// Deletes "um", "uh", and cut-off fragments after any cleanup pass (`FillerFilter`), in English takes only.
        public var removeFillers: Bool?
        /// The last batch engine a take tries, after the fallback: Apple's on-device recognizer in
        /// every built-in mode, so a take made with no network, or with no key, still gets its text.
        public var offlineFallback: Fallback?

        public init(id: String, name: String, transcriber: Transcriber, fallback: Fallback? = nil, cleanup: Cleanup? = nil,
                    removeFillers: Bool? = nil, offlineFallback: Fallback? = nil) {
            self.id = id
            self.name = name
            self.transcriber = transcriber
            self.fallback = fallback
            self.cleanup = cleanup
            self.removeFillers = removeFillers
            self.offlineFallback = offlineFallback
        }

        /// A mode whose transcriber is a batch engine has no live stream: the take is recorded,
        /// then its saved audio is transcribed once, after the stop.
        public var isBatchOnly: Bool { ConfigStore.batchEngines.contains(transcriber.engine) }

        /// The batch engines a take tries in order: the transcriber itself in a batch-only mode,
        /// then the fallback, then the offline fallback.
        public var batchChain: [Fallback] {
            (isBatchOnly ? [Fallback(engine: transcriber.engine, model: transcriber.model, mode: transcriber.mode, url: transcriber.url)] : [])
                + [fallback, offlineFallback].compactMap { $0 }
        }

        /// Apple's on-device recognizer: live words, no key, nothing leaves this Mac. The built-in
        /// default. No language-model cleanup (it dropped real words in testing); the filler rule
        /// takes out "um", "uh", and comma-set-off "you know", "I mean", and "like". The batch link
        /// answers when the live stream fails.
        public static var apple: Mode { apple(locale: AppleSpeechModel.preferredLocale()) }

        public static func apple(locale: Locale) -> Mode {
            Mode(
                id: "apple",
                name: "Apple",
                transcriber: Transcriber(engine: "apple-speech", model: "speech-transcriber", mode: "general", languages: [locale.identifier], finalTimeoutMs: 3_000),
                fallback: Fallback(engine: "apple-speech-batch", model: "speech-transcriber", mode: "general"),
                removeFillers: true)
        }

        /// The offline last resort of the cloud modes: Apple's on-device recognizer on the saved audio.
        public static let appleOffline = Fallback(engine: "apple-speech-batch", model: "speech-transcriber", mode: "general")

        /// The language the built-in modes listen for: the system's, as the Apple mode has it. The
        /// cloud modes' offline fallback reads it too, so it uses the model onboarding downloaded.
        static var systemLanguage: String { AppleSpeechModel.preferredLocale().identifier }

        /// Better accuracy than the Gemini live modes: across 34 test takes Scribe changed the
        /// meaning of about 9 where Gemini Live changed about 14, and its final came a median
        /// 85 ms after the audio ended against Gemini's 473 ms. Scribe keeps fillers, so the filter
        /// takes them out; no model touches the text. The 4 s final timeout leaves a repair of a
        /// short last segment 3 s (see `ScribeRealtimeSession`); a normal final takes about 0.1 s.
        public static var scribe: Mode { Mode(
            id: "scribe",
            name: "Scribe",
            transcriber: Transcriber(engine: "elevenlabs-scribe-realtime", model: "scribe_v2_realtime", mode: "verbatim", languages: [systemLanguage], finalTimeoutMs: 4_000),
            fallback: Fallback(engine: "gemini-batch", model: "gemini-3.5-transcribe", mode: "verbatim"),
            removeFillers: true,
            offlineFallback: appleOffline) }

        /// VERBATIM kept every word on nine hard takes where SMART dropped content from four, and
        /// Flash-Lite cleans it for about 0.8 s more. It was the default mode before Scribe.
        public static var geminiClean: Mode { Mode(
            id: "gemini-clean",
            name: "Gemini Clean",
            transcriber: Transcriber(engine: "gemini-live", model: "gemini-3.5-transcribe-live", mode: "VERBATIM", languages: [systemLanguage], finalTimeoutMs: 5_000),
            fallback: Fallback(engine: "gemini-batch", model: "gemini-3.5-transcribe", mode: "verbatim"),
            cleanup: Cleanup(engine: "gemini-generate", model: "gemini-3.5-flash-lite", thinkingLevel: "MINIMAL", timeoutMs: 4_000),
            offlineFallback: appleOffline) }

        public static var geminiSmart: Mode { Mode(
            id: "gemini-smart",
            name: "Gemini SMART",
            transcriber: Transcriber(engine: "gemini-live", model: "gemini-3.5-transcribe-live", mode: "SMART", languages: [systemLanguage], finalTimeoutMs: 5_000),
            fallback: Fallback(engine: "gemini-batch", model: "gemini-3.5-transcribe", mode: "smart"),
            offlineFallback: appleOffline) }

        /// Whisper large-v3-turbo on this Mac, then the filler filter: nothing leaves the machine.
        /// In a dictation benchmark it ranked as the best local engine.
        public static let local = Mode(
            id: "local",
            name: "Local",
            transcriber: Transcriber(engine: "local-whisper", model: "large-v3-turbo", mode: "verbatim", languages: ["en"], finalTimeoutMs: 4_000),
            removeFillers: true)
    }

    public struct Transcriber: Codable, Sendable, Equatable {
        public var engine: String
        public var model: String
        public var mode: String
        public var languages: [String]
        /// How long to wait for the live final after the stop tap before the saved audio goes to batch.
        public var finalTimeoutMs: Int
        /// A local engine's server, when not its default. Must be on this Mac.
        public var url: String? = nil
    }

    public struct Fallback: Codable, Sendable, Equatable {
        public var engine: String
        public var model: String
        public var mode: String
        /// A local engine's server, when not its default. Must be on this Mac.
        public var url: String? = nil
    }

    public struct Cleanup: Codable, Sendable, Equatable {
        public var engine: String
        public var model: String
        public var thinkingLevel: String?
        /// Past this, the raw transcript pastes instead.
        public var timeoutMs: Int
        /// A local engine's server, when not its default. Must be on this Mac.
        public var url: String?

        public init(engine: String, model: String, thinkingLevel: String?, timeoutMs: Int, url: String? = nil) {
            self.engine = engine
            self.model = model
            self.thinkingLevel = thinkingLevel
            self.timeoutMs = timeoutMs
            self.url = url
        }
    }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible, Sendable {
    case settings(String)
    case vocabulary(String)
    case replacements(String)

    public var description: String {
        switch self {
        case .settings(let reason): "vizier.jsonc: \(reason)"
        case .vocabulary(let reason): "vocabulary.txt: \(reason)"
        case .replacements(let reason): reason
        }
    }

    /// What a public log may say: the file, and for replacements the line number. The detailed
    /// reason can quote a variant, a vocabulary term, or a setting value, so it stays out of logs.
    public var publicSummary: String {
        switch self {
        case .settings: return "vizier.jsonc has an error"
        case .vocabulary: return "vocabulary.txt has an error"
        case .replacements(let reason):
            let prefix = "replacements.txt line "
            guard reason.hasPrefix(prefix) else { return "replacements.txt has an error" }
            let digits = reason.dropFirst(prefix.count).prefix { $0.isNumber }
            return digits.isEmpty ? "replacements.txt has an error" : "replacements.txt has an error on line \(digits)"
        }
    }
}

public enum ModeWriteError: Error, Equatable, CustomStringConvertible, Sendable {
    case unknownMode(String)
    case changedOnDisk
    case edit(String)
    case invalidResult(String)
    case io(String)

    public var description: String {
        switch self {
        case .unknownMode(let id): "no mode has the id \"\(id)\""
        case .changedOnDisk: "vizier.jsonc changed on disk since it was read; reload and try again"
        case .edit(let reason): "vizier.jsonc could not be edited in place: \(reason)"
        case .invalidResult(let reason): "the edited vizier.jsonc would not load: \(reason)"
        case .io(let reason): reason
        }
    }
}

/// Loads the config directory, validating every file on every load. A broken file never replaces
/// a working config: the store keeps running the last good one and reports what broke.
public final class ConfigStore: @unchecked Sendable {
    public struct Load: Sendable {
        public var config: VizierConfig
        /// Empty when every file loaded. Otherwise the config is the last good one (or the defaults).
        public var errors: [ConfigError]
    }

    public let directory: URL
    private let lock = NSLock()
    private var lastGood: VizierConfig?

    /// Gemini accepts at most 1,000 vocabulary terms.
    public static let maxVocabularyTerms = 1_000
    /// The engines this build can run. A mode naming anything else is a config error.
    public static let liveEngines = ["gemini-live", "elevenlabs-scribe-realtime", "apple-speech"]
    /// The Scribe transcriber's modes: "no_verbatim" turns on Scribe's own filler and false-start removal.
    public static let scribeModes = ["verbatim", "no_verbatim"]
    public static let batchEngines = ["gemini-batch", "elevenlabs-scribe-batch", "local-whisper", "apple-speech-batch"]
    public static let cleanupEngines = ["gemini-generate", "local-cleanup"]
    /// Engines that run on this Mac: no key, and every URL they are given must be loopback.
    public static let localEngines = ["local-whisper", "local-cleanup", "apple-speech-batch"]
    /// Apple's on-device engines: no key, and no URL to point anywhere.
    public static let appleEngines = ["apple-speech", "apple-speech-batch"]

    public init(directory: URL) {
        self.directory = directory
    }

    public static let standard = ConfigStore(directory: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/vizier"))

    public var settingsURL: URL { directory.appending(path: "vizier.jsonc") }
    public var vocabularyURL: URL { directory.appending(path: "vocabulary.txt") }
    public var replacementsURL: URL { directory.appending(path: "replacements.txt") }

    public func load() -> Load {
        var errors: [ConfigError] = []
        var config = VizierConfig()
        do { config.settings = try Self.parseSettings(read(settingsURL)) } catch { errors.append(error) }
        do { config.vocabulary = try Self.parseVocabulary(read(vocabularyURL)) } catch { errors.append(error) }
        do {
            config.replacements = try ReplacementsFile.parse(read(replacementsURL) ?? "")
        } catch {
            errors.append(.replacements(error.description))
        }
        return lock.withLock {
            if errors.isEmpty {
                lastGood = config
                return Load(config: config, errors: [])
            }
            return Load(config: lastGood ?? VizierConfig(), errors: errors)
        }
    }

    /// Writes starter files for any that are missing, so the directory documents itself. The
    /// directory is 0700 and its files 0600 (`PrivateFiles`); ones an older build made are tightened.
    public func writeStarterFilesIfMissing() throws {
        try PrivateFiles.makeDirectory(directory)
        let starters: [(URL, String)] = [
            (settingsURL, Self.starterSettings),
            (vocabularyURL, "# One term per line. Gemini gets up to 1,000 as custom vocabulary; Scribe gets the first 50 of at most 20 characters.\n"),
            (replacementsURL, "# One rule per line: variant, another variant -> replacement\n# Whole words, any case. A line starting with # is a comment.\n"),
        ]
        for (url, text) in starters {
            if FileManager.default.fileExists(atPath: url.path) {
                PrivateFiles.tighten(url)
            } else {
                try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                try PrivateFiles.restrict(url)
            }
        }
    }

    /// The settings file as it was read, so a later write can tell whether anything else changed it.
    public struct SettingsSnapshot: Sendable, Equatable {
        public let bytes: Data
        public let settings: VizierConfig.Settings
    }

    /// The settings file, parsed. Throws the parse error when the file is broken, and `io` when it
    /// is missing, since there is nothing to edit then.
    public func settingsSnapshot() throws -> SettingsSnapshot {
        let bytes: Data
        do { bytes = try Data(contentsOf: settingsURL) } catch { throw ModeWriteError.io(String(describing: error)) }
        let settings = try Self.parseSettings(try Self.utf8(bytes))
        return SettingsSnapshot(bytes: bytes, settings: settings)
    }

    /// The bytes as text, refusing anything that is not UTF-8: a lossy decode would write U+FFFD
    /// over a bad byte somewhere else in the file, which is not "only the mode value changed".
    private static func utf8(_ bytes: Data) throws -> String {
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw ModeWriteError.edit("the settings file is not UTF-8") }
        return text
    }

    /// Makes `id` the active mode by rewriting only the top-level `"mode"` value in the file: every
    /// comment, key order, trailing comma, and unknown field stays. The result is validated before it
    /// is written, and the write is refused when the file on disk no longer matches `expected`, so
    /// a popover click never erases an edit made since the popover was opened. Returns the snapshot
    /// of what was written. A writer that lands between the compare and the replace is not caught;
    /// the next load reports whatever it wrote.
    public func setActiveMode(_ id: String, expected: SettingsSnapshot) throws -> SettingsSnapshot {
        guard expected.settings.modes.contains(where: { $0.id == id }) else { throw ModeWriteError.unknownMode(id) }
        let text = try Self.utf8(expected.bytes)
        let edited: String
        do {
            edited = try SettingsEditor.replacingTopLevelString(named: "mode", with: id, in: text)
        } catch {
            throw ModeWriteError.edit(error.description)
        }
        let settings: VizierConfig.Settings
        do { settings = try Self.parseSettings(edited) } catch { throw ModeWriteError.invalidResult(error.description) }
        guard settings.mode == id else { throw ModeWriteError.invalidResult("the edited file names \"\(settings.mode)\"") }
        let bytes = Data(edited.utf8)
        return try lock.withLock {
            let onDisk: Data
            do { onDisk = try Data(contentsOf: settingsURL) } catch { throw ModeWriteError.io(String(describing: error)) }
            guard onDisk == expected.bytes else { throw ModeWriteError.changedOnDisk }
            // Foundation's atomic replace keeps the file's 0600 mode (FilePermissionsTests checks it).
            do { try bytes.write(to: settingsURL, options: .atomic) } catch { throw ModeWriteError.io(String(describing: error)) }
            return SettingsSnapshot(bytes: bytes, settings: settings)
        }
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    static func parseSettings(_ text: String?) throws(ConfigError) -> VizierConfig.Settings {
        guard let text else { return VizierConfig.Settings() }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let settings: VizierConfig.Settings
        do {
            settings = try decoder.decode(VizierConfig.Settings.self, from: Data(text.utf8))
        } catch let DecodingError.dataCorrupted(context) {
            throw .settings((context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? context.debugDescription)
        } catch let DecodingError.keyNotFound(key, context) {
            throw .settings("missing \"\(Self.snake(key.stringValue))\" at \(Self.path(context))")
        } catch let DecodingError.typeMismatch(_, context) {
            throw .settings("wrong type at \(Self.path(context))")
        } catch {
            throw .settings(String(describing: error))
        }
        guard !settings.modes.isEmpty else { throw .settings("\"modes\" is empty") }
        guard settings.modes.contains(where: { $0.id == settings.mode }) else {
            throw .settings("\"mode\" names \"\(settings.mode)\", which no entry in \"modes\" has as its id")
        }
        for mode in settings.modes {
            guard mode.transcriber.finalTimeoutMs > 0 else {
                throw .settings("mode \"\(mode.id)\" has a final_timeout_ms of \(mode.transcriber.finalTimeoutMs)")
            }
            guard liveEngines.contains(mode.transcriber.engine) || batchEngines.contains(mode.transcriber.engine) else {
                throw .settings("mode \"\(mode.id)\" names transcriber engine \"\(mode.transcriber.engine)\"; this build knows \(Self.list(liveEngines + batchEngines))")
            }
            if mode.transcriber.engine == "elevenlabs-scribe-realtime", !scribeModes.contains(mode.transcriber.mode) {
                throw .settings("mode \"\(mode.id)\" gives Scribe the mode \"\(mode.transcriber.mode)\"; Scribe knows \(Self.list(scribeModes))")
            }
            if let fallback = mode.fallback, !batchEngines.contains(fallback.engine) {
                throw .settings("mode \"\(mode.id)\" names fallback engine \"\(fallback.engine)\"; this build knows \(Self.list(batchEngines))")
            }
            if let offline = mode.offlineFallback, !localEngines.contains(offline.engine) || !batchEngines.contains(offline.engine) {
                throw .settings("mode \"\(mode.id)\" names offline_fallback engine \"\(offline.engine)\"; it must run on this Mac, and this build knows \(Self.list(localEngines.filter(batchEngines.contains)))")
            }
            // A local engine may only be pointed at this Mac, so a mode chosen for privacy stays private.
            let urls = [(mode.transcriber.engine, mode.transcriber.url)] + mode.batchChain.map { ($0.engine, $0.url) }
                + (mode.cleanup.map { [($0.engine, $0.url)] } ?? [])
            for (engine, url) in urls {
                guard let url else { continue }
                guard localEngines.contains(engine) else {
                    throw .settings("mode \"\(mode.id)\" gives \"\(engine)\" a url; only a local engine takes one")
                }
                guard let parsed = URL(string: url), Loopback.allows(parsed) else {
                    throw .settings("mode \"\(mode.id)\" points \"\(engine)\" at \(url); a local engine must use http on 127.0.0.1 or [::1]")
                }
            }
            // Scribe batch has no mode setting; it transcribes verbatim, and the filler filter runs after.
            if let fallback = mode.fallback, fallback.engine == "elevenlabs-scribe-batch", fallback.mode != "verbatim" {
                throw .settings("mode \"\(mode.id)\" gives Scribe batch the mode \"\(fallback.mode)\"; Scribe batch knows \"verbatim\"")
            }
            if let cleanup = mode.cleanup {
                guard cleanupEngines.contains(cleanup.engine) else {
                    throw .settings("mode \"\(mode.id)\" names cleanup engine \"\(cleanup.engine)\"; this build knows \(Self.list(cleanupEngines))")
                }
                guard cleanup.timeoutMs > 0 else {
                    throw .settings("mode \"\(mode.id)\" has a cleanup timeout_ms of \(cleanup.timeoutMs)")
                }
            }
        }
        return settings
    }

    static func parseVocabulary(_ text: String?) throws(ConfigError) -> [String] {
        guard let text else { return [] }
        var seen = Set<String>()
        var terms: [String] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard line.first != "#" else { continue }
            let term = line.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        guard terms.count <= maxVocabularyTerms else {
            throw .vocabulary("\(terms.count) terms; Gemini accepts at most \(maxVocabularyTerms)")
        }
        return terms
    }

    private static func list(_ names: [String]) -> String {
        names.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    private static func snake(_ key: String) -> String {
        key.reduce(into: "") { out, c in
            if c.isUppercase { out += "_" + c.lowercased() } else { out.append(c) }
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.reduce(into: "") { out, key in
            if let index = key.intValue { out += "[\(index)]" } else { out += (out.isEmpty ? "" : ".") + snake(key.stringValue) }
        }
        return path.isEmpty ? "the top level" : path
    }

    /// The starter `vizier.jsonc`, with every mode in the system language. The cloud modes'
    /// offline fallback reads their language, so it matches the Apple model onboarding downloads.
    static var starterSettings: String { starterSettings(language: AppleSpeechModel.preferredLocale().identifier) }

    static func starterSettings(language: String) -> String {
        """
        // Vizier config. The settings window edits this file, and you can edit it by hand; it is read on every take.
        // JSON with comments. Vocabulary and word replacements live beside it in vocabulary.txt and
        // replacements.txt. A broken file is reported and the last good config keeps running.
        {
          // The mode every take runs through.
          "mode": "apple",
          "modes": [
            {
              // Apple's on-device speech recognizer: live words, no key, nothing leaves this Mac.
              // Its model downloads once, from onboarding or Settings.
              "id": "apple",
              "name": "Apple",
              "transcriber": {
                "engine": "apple-speech",
                "model": "speech-transcriber",
                "mode": "general",
                // The language Apple listens for.
                "languages": ["\(language)"],
                "final_timeout_ms": 3000,
              },
              // The saved audio goes through Apple's file recognizer when the live stream fails.
              "fallback": { "engine": "apple-speech-batch", "model": "speech-transcriber", "mode": "general" },
              // English takes only: deletes "um", "uh", cut-off fragments, and comma-set-off "you know", "I mean", "like".
              // Plain code, not a model: it never adds or changes a word.
              "remove_fillers": true,
            },
            {
              // Better accuracy with an ElevenLabs key (Settings › Accounts).
              "id": "scribe",
              "name": "Scribe",
              "transcriber": {
                "engine": "elevenlabs-scribe-realtime",
                "model": "scribe_v2_realtime",
                // "verbatim" keeps every word; "no_verbatim" lets Scribe drop fillers and false starts itself.
                "mode": "verbatim",
                // [] lets Scribe detect the language.
                "languages": ["\(language)"],
                "final_timeout_ms": 4000,
              },
              "fallback": { "engine": "gemini-batch", "model": "gemini-3.5-transcribe", "mode": "verbatim" },
              // With no network, or no key, Apple's recognizer transcribes the saved audio on this Mac.
              "offline_fallback": { "engine": "apple-speech-batch", "model": "speech-transcriber", "mode": "general" },
              // English takes only: deletes "um", "uh", and cut-off fragments. Plain code, not a model: it never adds or changes a word.
              "remove_fillers": true,
            },
            {
              // Needs a Gemini key (Settings › Accounts).
              "id": "gemini-clean",
              "name": "Gemini Clean",
              "transcriber": {
                "engine": "gemini-live",
                "model": "gemini-3.5-transcribe-live",
                // VERBATIM keeps every word; the cleanup pass below takes the fillers out.
                "mode": "VERBATIM",
                // A hint, not a limit; [] lets Gemini detect the language.
                "languages": ["\(language)"],
                // Wait this long after the stop tap for the live final, then send the saved audio to batch.
                "final_timeout_ms": 5000,
              },
              "fallback": { "engine": "gemini-batch", "model": "gemini-3.5-transcribe", "mode": "verbatim" },
              "offline_fallback": { "engine": "apple-speech-batch", "model": "speech-transcriber", "mode": "general" },
              // Cleans whichever transcript arrives. Past timeout_ms, or on a failure, the raw text pastes.
              "cleanup": { "engine": "gemini-generate", "model": "gemini-3.5-flash-lite", "thinking_level": "MINIMAL", "timeout_ms": 4000 },
            },
            {
              "id": "gemini-smart",
              "name": "Gemini SMART",
              "transcriber": {
                "engine": "gemini-live",
                "model": "gemini-3.5-transcribe-live",
                "mode": "SMART",
                "languages": ["\(language)"],
                "final_timeout_ms": 5000,
              },
              "fallback": { "engine": "gemini-batch", "model": "gemini-3.5-transcribe", "mode": "smart" },
              "offline_fallback": { "engine": "apple-speech-batch", "model": "speech-transcriber", "mode": "general" },
            },
          ],
        }

        """
    }
}
