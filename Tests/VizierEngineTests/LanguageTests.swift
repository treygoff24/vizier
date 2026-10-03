import Foundation
import Testing
@testable import VizierEngine

/// A take in a language other than English: the English filler rules stay out of it, the starter
/// config names the user's language in every mode, a bare "en" resolves to American English, and
/// a language Apple doesn't support is reported as unsupported rather than swapped for English.
@Suite struct LanguageTests {
    private func mode(_ languages: [String], removeFillers: Bool? = true) -> VizierConfig.Mode {
        #if canImport(Speech)
        var mode = VizierConfig.Mode.apple(locale: Locale(identifier: "en-US"))
        #else
        var mode = VizierConfig.Mode.local  // Apple's speech engines do not exist on Linux; this mode needs no key either.
        #endif
        mode.transcriber.languages = languages
        mode.removeFillers = removeFillers
        return mode
    }

    @Test func aGermanTakeSkipsTheEnglishFillerFilter() throws {
        // What the filter would do to German: "um" is a word there, "Ein-" a prefix.
        #expect(FillerFilter.apply(to: "Wir treffen uns um 5 Uhr.") != "Wir treffen uns um 5 Uhr.")
        #expect(FillerFilter.apply(to: "Ein- und Ausgang sind offen.") != "Ein- und Ausgang sind offen.")

        for languages in [["de-DE"], ["de"], ["fr-FR"]] {
            #expect(!FillerFilter.applies(to: mode(languages)), "\(languages)")
        }
        // Re-run plans the same way a live take does.
        let plan = try Rerun.plan(mode: mode(["de-DE"]), config: VizierConfig(), key: { _ in nil })
        #expect(!plan.removeFillers)
    }

    @Test func anEnglishTakeKeepsTheFillerFilter() throws {
        for languages in [["en"], ["en-US"], ["en-GB"], ["en_AU"]] {
            #expect(FillerFilter.applies(to: mode(languages)), "\(languages)")
        }
        #expect(!FillerFilter.applies(to: mode(["en-US"], removeFillers: nil)), "a mode that doesn't ask for it")
        let plan = try Rerun.plan(mode: mode(["en-GB"]), config: VizierConfig(), key: { _ in nil })
        #expect(plan.removeFillers)
    }

    #if canImport(Speech)
    @Test func theStarterFileNamesTheGivenLanguageInEveryMode() async throws {
        let german = try ConfigStore.parseSettings(ConfigStore.starterSettings(language: "de-DE"))
        #expect(german.modes.map(\.id) == ["apple", "scribe", "gemini-clean", "gemini-smart"])
        for mode in german.modes {
            #expect(mode.transcriber.languages == ["de-DE"], "\(mode.id)")
            // The cloud modes' offline fallback listens in German, the model onboarding downloads.
            #expect(Engines.appleLocale(mode.transcriber.languages).identifier(.bcp47) == "de-DE", "\(mode.id)")
            #expect(!FillerFilter.applies(to: mode), "\(mode.id)")
        }
        // The built-in modes, which a missing file falls back to, listen in the system language.
        let system = await AppleSpeechModel.resolvePreferredLocale()
        for mode in VizierConfig.Settings().modes {
            #expect(mode.transcriber.languages == [system.identifier], "\(mode.id)")
        }
    }

    @Test func aBareLanguageTakesTheSystemRegionElseItsUsualOne() {
        let german = Locale(identifier: "de-DE")
        #expect(AppleSpeechModel.regional(Locale(identifier: "en"), system: german).identifier(.bcp47) == "en-US")
        #expect(AppleSpeechModel.regional(Locale(identifier: "en"), system: Locale(identifier: "en-GB")).identifier(.bcp47) == "en-GB")
        #expect(AppleSpeechModel.regional(Locale(identifier: "de"), system: Locale(identifier: "en-US")).identifier(.bcp47) == "de-DE")
        #expect(AppleSpeechModel.regional(Locale(identifier: "en-AU"), system: german).identifier(.bcp47) == "en-AU")
    }

    @Test func appleResolvesBareEnglishToAmericanEnglish() async throws {
        // A Mac with no Apple speech support (GitHub's macOS runner) lists no English at all.
        guard await AppleSpeechModel.supportedLocale(equivalentTo: Locale(identifier: "en-US")) != nil else {
            try Test.cancel("Apple speech lists no en-US on this Mac, so locale resolution can't be exercised")
        }
        // Apple's own lookup answers some other English for a bare "en" (en-ZA, en-IE in probes).
        let resolved = await AppleSpeechModel.supportedLocale(equivalentTo: Locale(identifier: "en"), system: Locale(identifier: "de-DE"))
        #expect(resolved?.identifier(.bcp47) == "en-US")
    }

    @Test func anUnsupportedSystemLanguageStaysItselfAndReportsUnsupported() async throws {
        let hawaiian = Locale(identifier: "haw-US")
        guard await AppleSpeechModel.supportedLocale(equivalentTo: hawaiian) == nil else {
            try Test.cancel("Apple speech supports Hawaiian on this Mac, so it can't stand in for an unsupported language")
        }
        let preferred = await AppleSpeechModel.resolve(system: hawaiian) { await AppleSpeechModel.supportedLocale(equivalentTo: $0) }
        #expect(preferred.identifier(.bcp47) == "haw-US")
        #expect(await AppleSpeechModel.status(for: preferred) == .unsupportedLocale)
        // A supported language resolves to Apple's name for it.
        let english = await AppleSpeechModel.resolve(system: Locale(identifier: "en-US")) { _ in Locale(identifier: "en_US") }
        #expect(english.identifier == "en_US")
    }
    #endif
}

@Suite struct SpeechModelLocaleTests {
    @Test func theModelFollowsTheActiveModesLanguageNotTheSystems() {
        var config = VizierConfig()
        var mode = VizierConfig.Mode.apple(locale: Locale(identifier: "de_DE"))
        mode.id = "german"
        config.settings.modes = [mode]
        config.settings.mode = "german"
        #expect(Engines.speechModelLocale(config).identifier == "de_DE")

        // A cloud mode's offline fallback reads the same first language.
        config.settings.modes[0].transcriber.engine = "elevenlabs-scribe-realtime"
        config.settings.modes[0].transcriber.languages = ["fr-FR"]
        config.settings.modes[0].offlineFallback = VizierConfig.Mode.appleOffline
        #expect(Engines.speechModelLocale(config).identifier == "fr-FR")
    }
}
