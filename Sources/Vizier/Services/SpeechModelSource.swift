import VizierEngine
import Foundation
import Observation

enum SpeechModelStatus: Sendable, Equatable {
    case installed, notInstalled, unsupportedLocale
}

/// What the app needs of Apple's on-device speech model: which language it would use, whether the
/// model is on this Mac, and a download with progress. The engine's `AppleSpeechModel` provides the
/// live implementation (the same three calls); the settings window and onboarding take this
/// protocol by injection, so tests and screenshots use `FakeSpeechModelSource`.
nonisolated protocol SpeechModelSource: Sendable {
    func preferredLocale() -> Locale
    func status(for locale: Locale) async -> SpeechModelStatus
    func install(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Stands in for the engine's `AppleSpeechModel` until the app is wired to it: reports the model as
/// not installed and refuses to install. Replace `SpeechModelSources.live` with the real adapter.
nonisolated struct UnwiredSpeechModelSource: SpeechModelSource {
    struct NotWired: Error, CustomStringConvertible {
        var description: String { "Apple speech is not available in this build." }
    }

    func preferredLocale() -> Locale { Locale.current }
    func status(for locale: Locale) async -> SpeechModelStatus { .notInstalled }
    func install(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws { throw NotWired() }
}

/// The engine's `AppleSpeechModel`, behind the app's protocol.
/// The language is the one the saved active mode transcribes in (`Engines.speechModelLocale`), so
/// Settings shows and downloads the model a take will use, not just the system language's.
nonisolated struct AppleSpeechModelSource: SpeechModelSource {
    var config: ConfigStore = .standard

    func preferredLocale() -> Locale { Engines.speechModelLocale(config.load().config) }
    func status(for locale: Locale) async -> SpeechModelStatus {
        switch await AppleSpeechModel.status(for: locale) {
        case .installed: .installed
        case .notInstalled: .notInstalled
        case .unsupportedLocale: .unsupportedLocale
        }
    }
    func install(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await AppleSpeechModel.install(for: locale, progress: progress)
    }
}

enum SpeechModelSources {
    /// The one place the real source is chosen.
    static var live: any SpeechModelSource { AppleSpeechModelSource() }
    static func live(config: ConfigStore) -> any SpeechModelSource { AppleSpeechModelSource(config: config) }
}

/// A scripted source for tests and `--render-ui`: it answers a fixed status, and an install walks
/// the progress through the given steps and then flips the status to installed (or throws).
final class FakeSpeechModelSource: SpeechModelSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SpeechModelStatus
    let locale: Locale
    let progressSteps: [Double]
    let installError: (any Error)?
    private var installs = 0

    init(status: SpeechModelStatus, locale: Locale = Locale(identifier: "en_US"), progressSteps: [Double] = [0.25, 0.5, 1], installError: (any Error)? = nil) {
        current = status
        self.locale = locale
        self.progressSteps = progressSteps
        self.installError = installError
    }

    var installCount: Int { lock.withLock { installs } }

    func preferredLocale() -> Locale { locale }
    func status(for locale: Locale) async -> SpeechModelStatus { lock.withLock { current } }
    func install(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { installs += 1 }
        for step in progressSteps { progress(step) }
        if let installError { throw installError }
        lock.withLock { current = .installed }
    }
}

/// The Apple speech model's state as the UI shows it. Shared by the Transcription pane and the
/// onboarding download step.
@Observable
final class SpeechModelModel {
    enum State: Equatable {
        case checking
        case installed
        case notInstalled
        case unsupported
        case downloading(Double)
        case failed(String)
    }

    private(set) var state: State = .checking
    private(set) var locale: Locale
    @ObservationIgnored private let source: any SpeechModelSource

    init(source: any SpeechModelSource, state: State = .checking) {
        self.source = source
        locale = source.preferredLocale()
        self.state = state
    }

    /// The language Apple speech will use, in the user's own language ("English (United States)").
    var languageName: String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    var isInstalled: Bool { state == .installed }

    func refresh() async {
        if case .downloading = state { return }
        locale = source.preferredLocale()
        switch await source.status(for: locale) {
        case .installed: state = .installed
        case .notInstalled: state = .notInstalled
        case .unsupportedLocale: state = .unsupported
        }
    }

    /// Downloads the model for the language on screen. When the active mode's language changed
    /// since that was read (a mode switch, a hand edit of vizier.jsonc), nothing downloads: the
    /// state is read again for the new language, and the button reappears if that one is missing.
    func download() async {
        guard state == .notInstalled || isFailed else { return }
        if source.preferredLocale().identifier != locale.identifier {
            await refresh()
            return
        }
        state = .downloading(0)
        let box = ProgressBox { [weak self] value in
            // A report that lands after the download ended must not undo the result.
            guard let self, case .downloading = self.state else { return }
            self.state = .downloading(min(max(value, 0), 1))
        }
        do {
            try await source.install(for: locale) { value in
                Task { @MainActor in box.report(value) }
            }
            state = .installed
        } catch {
            state = .failed(String(describing: error))
        }
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    /// Carries progress back to the main actor.
    private final class ProgressBox: @unchecked Sendable {
        let apply: @MainActor (Double) -> Void
        init(apply: @escaping @MainActor (Double) -> Void) { self.apply = apply }
        @MainActor func report(_ value: Double) { apply(value) }
    }
}
