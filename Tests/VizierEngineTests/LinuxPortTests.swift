import Foundation
import Testing
@testable import VizierEngine

#if !canImport(os)
/// The Logger stand-in must keep the privacy rule `os.Logger` gives: a value is private unless the
/// call marks it public (numbers and Bools excepted under the default).
@Suite struct LoggerShimTests {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var all: [String] { lock.withLock { stored } }
        func add(_ line: String) { lock.withLock { stored.append(line) } }
    }

    private func logger(floor: Logger.Level, _ lines: Lines) -> Logger {
        Logger(subsystem: "net.praxient.dictum", category: "test", floor: floor) { lines.add($0) }
    }

    @Test func interpolatedValuesAreRedactedUnlessMarkedPublic() {
        let lines = Lines()
        let log = logger(floor: .debug, lines)
        let secret = "zorblex quaxil"
        log.notice("text \(secret) public \(secret, privacy: .public) private \(secret, privacy: .private) sensitive \(secret, privacy: .sensitive)")
        log.notice("count \(42) flag \(true) seconds \(1.26, format: .fixed(precision: 1)) err \(String(describing: secret))")
        let text = lines.all.joined(separator: "\n")
        #expect(lines.all.count == 2)
        #expect(text.contains("text <private> public zorblex quaxil private <private> sensitive <private>"))
        #expect(text.contains("count 42 flag true seconds 1.3 err <private>"))
        #expect(text.components(separatedBy: "zorblex quaxil").count == 2, "the secret appears once, where it is public")
    }

    @Test func theLevelFloorDropsQuieterMessages() {
        let lines = Lines()
        let log = logger(floor: .error, lines)
        log.debug("a")
        log.info("b")
        log.notice("c")
        log.warning("d")
        log.error("e")
        log.fault("f")
        #expect(lines.all.count == 2)
        #expect(lines.all.first?.hasSuffix("error: e") == true)
    }

    @Test func theFloorNameParsesWithNoticeAsTheDefault() {
        #expect(Logger.Level.parse(nil) == .notice)
        #expect(Logger.Level.parse("garbage") == .notice)
        #expect(Logger.Level.parse("DEBUG") == .debug)
        #expect(Logger.Level.parse("warning") == .warning)
    }
}
#endif

#if !canImport(Speech)
/// Apple's speech engines do not exist on Linux.
@Suite struct LinuxConfigTests {
    private func settings(engine: String, in slot: String) -> String {
        let transcriber = slot == "transcriber" ? engine : "gemini-live"
        let fallback = slot == "fallback" ? #", "fallback": {"engine": "\#(engine)", "model": "m", "mode": "general"}"# : ""
        let offline = slot == "offline" ? #", "offline_fallback": {"engine": "\#(engine)", "model": "m", "mode": "general"}"# : ""
        return """
        {"mode": "a", "modes": [{"id": "a", "name": "A",
          "transcriber": {"engine": "\(transcriber)", "model": "m", "mode": "SMART", "languages": ["en"], "final_timeout_ms": 1000}\(fallback)\(offline)}]}
        """
    }

    @Test func appleEnginesAreRejectedInEverySlotWithAMessageNamingLinux() {
        for engine in ["apple-speech", "apple-speech-batch"] {
            for slot in ["transcriber", "fallback", "offline"] {
                if engine == "apple-speech", slot != "transcriber" { continue }  // not a batch engine anywhere else
                do {
                    _ = try ConfigStore.parseSettings(settings(engine: engine, in: slot))
                    Issue.record("\(engine) in \(slot) was accepted")
                } catch {
                    #expect(error.description.contains("Linux"), "\(engine) in \(slot): \(error.description)")
                    #expect(error.description.contains(engine), "\(engine) in \(slot): \(error.description)")
                }
            }
        }
    }

    @Test func noBuiltInModeUsesAnAppleEngine() throws {
        let builtIn = VizierConfig.Settings().modes
        #expect(builtIn.map(\.id) == ["local", "scribe", "gemini-clean", "gemini-smart"])
        for mode in builtIn {
            let engines = [mode.transcriber.engine] + mode.batchChain.map(\.engine) + [mode.offlineFallback?.engine].compactMap { $0 }
            #expect(engines.allSatisfy { !ConfigStore.appleEngines.contains($0) }, "\(mode.id): \(engines)")
        }
    }

    @Test func theStarterFileIsTheDefaultAndParsesWithoutAppleEngines() throws {
        let parsed = try ConfigStore.parseSettings(ConfigStore.starterSettings(language: "de-DE"))
        #expect(parsed.modes.map(\.id) == ["local", "scribe", "gemini-clean", "gemini-smart"])
        #expect(parsed.mode == "local")
        #expect(parsed == VizierConfig.Settings(mode: "local", modes: parsed.modes))
        #expect(parsed.modes[1].transcriber.languages == ["de-DE"])
    }

    @Test func aTakesLanguageFallsBackToTheSystemLocale() {
        #expect(Engines.appleLocale([]) == SystemLocale.fromEnvironment(ProcessInfo.processInfo.environment))
        #expect(Engines.appleLocale(["fr-FR"]).identifier == "fr-FR")
    }
}
#endif

/// The system language on Linux is the POSIX locale's.
@Suite struct SystemLocaleTests {
    @Test func anEnglishLocaleIsEnglishWithItsRegion() {
        let locale = SystemLocale.fromEnvironment(["LANG": "en_US.UTF-8"])
        #expect(locale.identifier == "en_US")
        #expect(locale.language.languageCode == .english)
    }

    @Test func aNonEnglishLocaleIsThatLanguage() {
        let german = SystemLocale.fromEnvironment(["LANG": "de_DE.UTF-8@euro"])
        #expect(german.identifier == "de_DE")
        #expect(german.language.languageCode == .german)
        #expect(SystemLocale.fromEnvironment(["LANG": "fr"]).language.languageCode == .french)
    }

    @Test func cPosixAndUnsetNameNoLanguage() {
        for environment in [["LANG": "C"], ["LANG": "POSIX"], ["LANG": "C.UTF-8"], ["LC_ALL": "C"], ["LANG": ""], [:]] {
            let locale = SystemLocale.fromEnvironment(environment)
            #expect(locale.identifier == "", "\(environment)")
            #expect(locale.language.languageCode == nil, "\(environment)")
        }
    }

    @Test func lcAllOutranksLangAndAnEmptyOneDoesNot() {
        #expect(SystemLocale.fromEnvironment(["LC_ALL": "C", "LANG": "de_DE.UTF-8"]).identifier == "")
        #expect(SystemLocale.fromEnvironment(["LC_ALL": "fr_FR.UTF-8", "LANG": "C"]).identifier == "fr_FR")
        #expect(SystemLocale.fromEnvironment(["LC_ALL": "", "LANG": "de_DE.UTF-8"]).identifier == "de_DE")
    }
}

#if !canImport(Speech)
/// A10 and A11 on Linux: the offline fallback of the cloud modes is local Whisper, and the default
/// local mode listens in the system's language, not English.
@Suite struct LinuxDefaultsTests {
    private static let whisper = VizierConfig.Fallback(engine: "local-whisper", model: "large-v3-turbo", mode: "verbatim")

    @Test func theBuiltInCloudModesFallBackToLocalWhisperOffline() {
        let cloud = VizierConfig.Settings().modes.filter { $0.id != "local" }
        #expect(cloud.map(\.id) == ["scribe", "gemini-clean", "gemini-smart"])
        for mode in cloud { #expect(mode.offlineFallback == Self.whisper, "\(mode.id)") }
    }

    @Test func theStarterFilesCloudModesCarryTheSameOfflineFallback() throws {
        for language in ["en-US", "de-DE", ""] {
            let parsed = try ConfigStore.parseSettings(ConfigStore.starterSettings(language: language))
            for mode in parsed.modes where mode.id != "local" { #expect(mode.offlineFallback == Self.whisper, "\(language) \(mode.id)") }
            #expect(parsed.modes.first { $0.id == "local" }?.offlineFallback == nil)
        }
    }

    @Test func aSystemWithNoLanguageGivesTheCloudModesNoLanguageList() {
        #expect(VizierConfig.Mode.languages(forSystem: "") == [])
        #expect(VizierConfig.Mode.languages(forSystem: "de_DE") == ["de_DE"])
    }

    @Test func theLocalModeListensInTheSystemLanguageWithFillersOnlyWhenThereIsOne() throws {
        let german = VizierConfig.Mode.local(languages: ["de_DE"])
        #expect(german.transcriber.languages == ["de_DE"])
        #expect(german.removeFillers == true)
        #expect(!FillerFilter.applies(to: german), "English filler rules do not run on German")
        let none = VizierConfig.Mode.local(languages: [])
        #expect(none.transcriber.languages == [])
        #expect(none.removeFillers == false)
        #expect(!FillerFilter.applies(to: none))
    }

    @Test func theStarterFileFollowsTheLanguageForEveryMode() throws {
        let german = try ConfigStore.parseSettings(ConfigStore.starterSettings(language: "de-DE"))
        for mode in german.modes {
            #expect(mode.transcriber.languages == ["de-DE"], "\(mode.id)")
            #expect(!FillerFilter.applies(to: mode), "\(mode.id)")
        }
        let none = try ConfigStore.parseSettings(ConfigStore.starterSettings(language: ""))
        for mode in none.modes { #expect(mode.transcriber.languages == [], "\(mode.id)") }
        #expect(none.modes.first { $0.id == "local" }?.removeFillers == false)
        let english = try ConfigStore.parseSettings(ConfigStore.starterSettings(language: "en-US"))
        #expect(english.modes.first { $0.id == "local" }?.removeFillers == true)
        #expect(english.modes.first { $0.id == "local" }?.transcriber.languages == ["en-US"])
    }
}
#endif
