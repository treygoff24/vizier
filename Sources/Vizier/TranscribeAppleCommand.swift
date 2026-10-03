import AVFoundation
import VizierEngine
import Foundation
import Speech

/// `Vizier --transcribe-apple <audio file> [locale]`: runs one file through the `apple-speech-batch`
/// engine alone, with no fallback to any other engine and no look at the active mode, and prints
/// which engine answered. It exists to prove Apple speech works from the signed, hardened bundle
/// (build/Vizier.app/Contents/MacOS/Vizier). It exits before the app starts, so it never touches
/// the running Vizier's hotkey, Keychain items, or history.
enum TranscribeAppleCommand {
    static func run(_ arguments: [String]) -> Int32? {
        if let flag = arguments.firstIndex(of: "--install-apple-model") {
            return install(Locale(identifier: arguments.dropFirst(flag + 1).first { !$0.hasPrefix("-") } ?? "en-US"))
        }
        guard let flag = arguments.firstIndex(of: "--transcribe-apple") else { return nil }
        let rest = arguments.dropFirst(flag + 1).filter { !$0.hasPrefix("-") }
        guard let path = rest.first else {
            return fail("usage: Vizier --transcribe-apple <audio file> [locale, default en-US]", code: 64)
        }
        let locale = Locale(identifier: rest.dropFirst().first ?? "en-US")
        let url = URL(filePath: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return fail("cannot read \(path)", code: 66) }

        // Blocks the main thread while a detached task does the work, so no main-actor hop is needed.
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            outcome.set(await transcribe(url, locale: locale))
            done.signal()
        }
        done.wait()
        return outcome.value
    }

    /// `Vizier --install-apple-model [locale]`: downloads the Apple speech model, printing progress.
    /// The same call onboarding makes; here so the signed bundle can be tested without the UI.
    nonisolated private static func install(_ locale: Locale) -> Int32 {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let started = ContinuousClock.now
            let last = Progress()
            do {
                try await AppleSpeechModel.install(for: locale) { fraction in
                    guard last.advance(to: fraction) else { return }
                    print("installing \(locale.identifier): \(Int(fraction * 100))%")
                }
                let seconds = (ContinuousClock.now - started).components.seconds
                print("status after install: \(await AppleSpeechModel.status(for: locale)), \(seconds) s")
                outcome.set(0)
            } catch {
                outcome.set(fail("install failed: \(error)", code: 1))
            }
            done.signal()
        }
        done.wait()
        return outcome.value
    }

    nonisolated private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var shown = -1
        /// True when the whole percent changed, so a stream of tiny updates prints once per percent.
        func advance(to fraction: Double) -> Bool {
            lock.withLock {
                let percent = Int(fraction * 100)
                defer { shown = max(shown, percent) }
                return percent > shown
            }
        }
    }

    nonisolated private static func transcribe(_ url: URL, locale: Locale) async -> Int32 {
        print("engine requested: apple-speech-batch (no fallback)")
        print("speech recognition authorization: \(describe(SFSpeechRecognizer.authorizationStatus())) (not requested; the SpeechTranscriber path asks for none)")
        let status = await AppleSpeechModel.status(for: locale)
        print("model for \(locale.identifier): \(status)")
        guard status == .installed else {
            return fail("the Apple speech model for \(locale.identifier) is \(status == .notInstalled ? "not installed" : "unsupported"); nothing was transcribed", code: 69)
        }
        do {
            let report = try await AppleSpeechBatchTranscriber(locale: locale).transcribeReporting(url)
            print("engine answered: apple-speech-batch")
            print("seconds: \(String(format: "%.2f", report.transcriptionSeconds))")
            print("words: \(report.wordCount)")
            print("transcript: \(report.transcript)")
            return 0
        } catch {
            return fail("apple-speech-batch failed: \(error)", code: 1)
        }
    }

    nonisolated private static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }

    nonisolated private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var code: Int32 = 1
        func set(_ value: Int32) { lock.withLock { code = value } }
        var value: Int32 { lock.withLock { code } }
    }

    nonisolated private static func fail(_ message: String, code: Int32) -> Int32 {
        FileHandle.standardError.write(Data("Vizier: \(message)\n".utf8))
        return code
    }
}
