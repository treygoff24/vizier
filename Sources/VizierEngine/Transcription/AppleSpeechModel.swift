import Foundation
import Speech

/// Apple's on-device speech model: which language Vizier uses, whether its assets are installed,
/// and installing them with progress. Onboarding and Settings call this; a take only reads it.
public enum AppleSpeechModel {
    public enum Status: Sendable, Equatable {
        case installed
        case notInstalled
        case unsupportedLocale
    }

    /// The system language, as Apple's transcriber names it when it supports the language, once
    /// `resolvePreferredLocale()` has finished. A language Apple does not support stays itself
    /// rather than turning into English: `status(for:)` then answers `unsupportedLocale`, so
    /// Settings and onboarding can say so, and a take fails with that reason instead of
    /// transcribing the speech as English. Until the lookup finishes (the first moments after
    /// launch) it answers the system language as is and starts the lookup; it never blocks.
    public static func preferredLocale() -> Locale {
        if let resolved = resolved.value { return resolved }
        Task.detached { _ = await resolvePreferredLocale() }
        return systemLocale
    }

    /// Looks the system language up in Apple's transcriber list, once per process.
    @discardableResult
    public static func resolvePreferredLocale() async -> Locale {
        if let resolved = resolved.value { return resolved }
        let locale = await resolve(system: systemLocale) { await supportedLocale(equivalentTo: $0) }
        resolved.value = locale
        return locale
    }

    /// Apple's name for `system` when it supports the language, else `system` itself.
    static func resolve(system: Locale, supported: (Locale) async -> Locale?) async -> Locale {
        await supported(system) ?? system
    }

    private static let resolved = LocaleBox()

    private final class LocaleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Locale?
        var value: Locale? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    static var systemLocale: Locale {
        Locale.preferredLanguages.first.map(Locale.init(identifier:)) ?? .current
    }

    /// The locale Apple's transcriber supports that is equivalent to `locale`, or nil when it
    /// supports none. A bare language ("en", as older configs name Scribe's) is first given a
    /// region: the system's when the system speaks that language, else the language's usual one.
    /// Asked about bare "en", Apple answers whichever English it likes (en-ZA, en-IE in probes).
    public static func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await supportedLocale(equivalentTo: locale, system: systemLocale)
    }

    static func supportedLocale(equivalentTo locale: Locale, system: Locale) async -> Locale? {
        let regional = regional(locale, system: system)
        if regional != locale, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: regional) { return supported }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// `locale` with a region: its own, else the system's when the languages match ("en" on an
    /// en-GB Mac is en-GB), else the language's most likely region ("en" is en-US, "de" de-DE).
    static func regional(_ locale: Locale, system: Locale) -> Locale {
        guard locale.language.region == nil, let code = locale.language.languageCode else { return locale }
        let region = system.language.languageCode == code && system.language.region != nil
            ? system.language.region
            : Locale.Language(identifier: locale.language.maximalIdentifier).region
        guard let region else { return locale }
        return Locale(identifier: "\(code.identifier)-\(region.identifier)")
    }

    /// `installed` when the model is on this Mac. Apple's own asset status only says so for locales
    /// an app has already reserved, so a model on disk that this app has not touched yet (one a
    /// different app downloaded) counts too: the analyzer reserves it on first use.
    public static func status(for locale: Locale) async -> Status {
        guard let supported = await supportedLocale(equivalentTo: locale) else { return .unsupportedLocale }
        switch await AssetInventory.status(forModules: [module(for: supported)]) {
        case .installed: return .installed
        case .unsupported: return .unsupportedLocale
        case .supported, .downloading:
            let onDisk = await SpeechTranscriber.installedLocales
            return onDisk.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) } ? .installed : .notInstalled
        @unknown default: return .notInstalled
        }
    }

    /// Downloads and installs the model for `locale`. `progress` gets a fraction from 0 to 1 and
    /// ends at 1 when the install is done. Returns at once when the model is already installed.
    public static func install(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let supported = await supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechError.unsupportedLocale(locale.identifier)
        }
        let module = module(for: supported)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            progress(1)
            return
        }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
            progress(min(max(value.fractionCompleted, 0), 1))
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
        progress(1)
    }

    /// The module the model is checked and installed against. The same preset both engines use,
    /// so one installed model serves live and batch.
    static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }
}

public enum AppleSpeechError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedLocale(String)
    case modelNotInstalled(String)
    case unreadableAudio(String)
    case timedOut(seconds: Int)

    public var description: String {
        switch self {
        case .unsupportedLocale(let id): "Apple speech does not support the language \(id)"
        case .modelNotInstalled(let id): "the Apple speech model for \(id) is not installed"
        case .unreadableAudio(let reason): "the audio could not be read: \(reason)"
        case .timedOut(let seconds): "Apple speech did not finish within \(seconds) s"
        }
    }
}
