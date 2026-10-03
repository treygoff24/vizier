import AppKit
import VizierEngine
import SwiftUI

/// `Vizier --render-ui <folder>` renders every onboarding step and every settings pane to PNGs in
/// `folder` and exits, for building and reviewing the screens without running the app. It runs
/// before any app setup: no status item, no hotkey, no Keychain, no real preferences or config. The
/// views get a fake speech model source, fake permissions, an in-memory key store, a throwaway
/// preferences domain, and a config folder inside `folder`.
enum RenderUICommand {
    struct RefusedDestination: Error, CustomStringConvertible {
        let child: String
        var description: String { "refusing to write \(child): it is a link, a hard link, or real Vizier data" }
    }

    static func run(_ arguments: [String]) -> Int32? {
        guard let flag = arguments.firstIndex(of: "--render-ui") else { return nil }
        let folder = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        guard !folder.isEmpty, !folder.hasPrefix("-") else {
            FileHandle.standardError.write(Data("usage: Vizier --render-ui <folder>\n".utf8))
            return 64
        }
        let url = URL(filePath: folder, directoryHint: .isDirectory).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().path
        if RealDataGuard.refuses(url) {
            FileHandle.standardError.write(Data("refusing to render in \(resolved): that is real Vizier data\n".utf8))
            return 64
        }
        if let child = RealDataGuard.refusedChild(in: url, writing: ["config", "config-broken"]) {
            FileHandle.standardError.write(Data("refusing to render in \(resolved): \(child) is a link, a hard link, or real Vizier data\n".utf8))
            return 64
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            _ = NSApplication.shared
            let written = try renderAll(into: url)
            for path in written { print(path) }
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    private static func renderAll(into folder: URL) throws -> [String] {
        let suite = "net.praxient.dictum.render-ui.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let config = ConfigStore(directory: folder.appending(path: "config"))
        try config.writeStarterFilesIfMissing()

        func accounts(saved: Bool, tested: Bool, geminiResult: KeyTestResult? = nil) -> [AccountKeyModel] {
            let store = InMemoryKeyStore(keys: saved ? ["elevenlabs": "x"] : [:])
            let models = [Engines.KeyAccount.elevenLabs, .gemini].map {
                AccountKeyModel(provider: $0, store: store, tester: FakeKeyTester(result: $0 == .gemini ? geminiResult ?? .passed : .passed),
                                readSaved: { _ in "x" })
            }
            if tested { settle { await models[0].runTest() } }
            if geminiResult != nil {
                models[1].draft = "not-a-real-key"
                settle { await models[1].runTest() }
            }
            return models
        }

        var written: [String] = []
        func emit<V: View>(_ name: String, _ view: V, screen: NSRect? = nil, after: (() -> Void)? = nil) throws {
            let file = folder.appending(path: "\(name).png")
            if let child = RealDataGuard.refusedChild(in: folder, writing: [file.lastPathComponent]) { throw RefusedDestination(child: child) }
            try snapshot(view, screen: screen, after: after).write(to: file)
            written.append(file.path)
        }

        // Onboarding: every step in its first state, then the states that change the picture.
        func onboarding(_ step: OnboardingModel.Step, mic: PermissionState = .notAsked, accessibility: Bool = false,
                        speech: SpeechModelModel? = nil, practice: String = "", accountModels: [AccountKeyModel]? = nil) -> OnboardingView {
            let model = OnboardingModel(
                permissions: PermissionsModel(probe: FakePermissions(mic: mic, accessibility: accessibility)),
                speech: speech ?? SpeechModelModel(source: FakeSpeechModelSource(status: .notInstalled), state: .notInstalled),
                preferences: preferences, accounts: accountModels ?? accounts(saved: false, tested: false))
            var sink: ((String) -> Void)?
            model.setPracticeSink = { sink = $0 }
            model.step = step
            if !practice.isEmpty { sink?(practice) }
            return OnboardingView(model: model)
        }
        try emit("onboarding-1-welcome", onboarding(.welcome))
        try emit("onboarding-2-microphone", onboarding(.microphone))
        try emit("onboarding-2-microphone-granted", onboarding(.microphone, mic: .granted))
        try emit("onboarding-2-microphone-denied", onboarding(.microphone, mic: .denied))
        try emit("onboarding-3-accessibility", onboarding(.accessibility, mic: .granted))
        try emit("onboarding-3-accessibility-granted", onboarding(.accessibility, mic: .granted, accessibility: true))
        try emit("onboarding-4-speech-model", onboarding(.speechModel, mic: .granted, accessibility: true))
        try emit("onboarding-4-speech-model-downloading", onboarding(
            .speechModel, mic: .granted, accessibility: true,
            speech: SpeechModelModel(source: FakeSpeechModelSource(status: .notInstalled), state: .downloading(0.42))))
        try emit("onboarding-4-speech-model-installed", onboarding(
            .speechModel, mic: .granted, accessibility: true,
            speech: SpeechModelModel(source: FakeSpeechModelSource(status: .installed), state: .installed)))
        // A failure lands after the step appeared (and refreshed the model), as it does for real.
        let failing = SpeechModelModel(source: FakeSpeechModelSource(
            status: .notInstalled, installError: RenderFailure(description: "the network connection was lost.")))
        try emit("onboarding-4-speech-model-failed", onboarding(.speechModel, mic: .granted, accessibility: true, speech: failing),
                 after: { settle { await failing.download() } })
        try emit("onboarding-5-hotkey", onboarding(.hotkey, mic: .granted, accessibility: true))
        try emit("onboarding-6-accuracy", onboarding(.accuracy, mic: .granted, accessibility: true))
        try emit("onboarding-6-accuracy-tested", onboarding(.accuracy, mic: .granted, accessibility: true, accountModels: accounts(saved: true, tested: true)))
        try emit("onboarding-7-practice", onboarding(.practice, mic: .granted, accessibility: true))
        try emit("onboarding-7-practice-done", onboarding(.practice, mic: .granted, accessibility: true,
                                                          practice: "Move the standup to three and tell the team the demo slips a day."))

        // Settings: every pane.
        // A config folder whose vizier.jsonc no longer parses, for the broken-file banner.
        let brokenConfig = ConfigStore(directory: folder.appending(path: "config-broken"))
        try brokenConfig.writeStarterFilesIfMissing()
        try Data("{ \"mode\": \"scribe\", \"modes\": [ \n".utf8).write(to: brokenConfig.settingsURL)

        func settings(_ pane: SettingsModel.Pane, speech: SpeechModelModel? = nil, accountModels: [AccountKeyModel]? = nil,
                      login: LoginItemState = .off, canCheckUpdates: Bool = true, configStore: ConfigStore? = nil) -> SettingsView {
            let model = SettingsModel(
                preferences: preferences, config: configStore ?? config,
                speech: speech ?? SpeechModelModel(source: FakeSpeechModelSource(status: .installed), state: .installed),
                accounts: accountModels ?? accounts(saved: false, tested: false), loginItem: FakeLoginItem(state: login),
                opener: FakeFileOpener(), updates: FakeUpdater(canCheck: canCheckUpdates))
            model.pane = pane
            return SettingsView(model: model)
        }
        try emit("settings-general", settings(.general))
        try emit("settings-general-not-installed", settings(.general, login: .notInstalled))
        try emit("settings-transcription", settings(.transcription))
        try emit("settings-transcription-not-installed", settings(
            .transcription, speech: SpeechModelModel(source: FakeSpeechModelSource(status: .notInstalled), state: .notInstalled)))
        // A screen too short for the pane: the window stops at the screen and the pane scrolls.
        try emit("settings-transcription-short-screen", settings(.transcription), screen: NSRect(x: 0, y: 0, width: 1440, height: 340))
        try emit("settings-accounts", settings(.accounts))
        try emit("settings-transcription-broken-file", settings(.transcription, configStore: brokenConfig))
        try emit("settings-accounts-saved-tested", settings(.accounts, accountModels: accounts(saved: true, tested: true)))
        try emit("settings-accounts-rejected", settings(.accounts, accountModels: accounts(saved: true, tested: true, geminiResult: .rejected)))
        try emit("settings-words", settings(.words))
        try emit("settings-about", settings(.about))
        try emit("settings-about-unsigned", settings(.about, canCheckUpdates: false))
        return written
    }

    /// Runs an async step to completion from synchronous code by spinning the main run loop.
    private static func settle(_ work: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in
            await work()
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    }

    /// The view as PNG data at 2x, drawn in an off-screen window with the same chrome and sizing as
    /// `ShellWindowController` and captured from the window's frame view, so the picture includes the
    /// traffic lights beside the header.
    private static func snapshot<V: View>(_ view: V, screen: NSRect? = nil, after: (() -> Void)? = nil) throws -> Data {
        let sizer = WindowSizer()
        sizer.visibleFrame = { _ in screen }
        let host = sizer.host(view.environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        WindowChrome.style(window)
        window.contentView = host
        sizer.attach(window)
        let frameView = host.superview ?? host
        frameView.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its first pass (fonts, tasks) before drawing.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        if let after {
            after()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        }
        let bounds = frameView.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw RenderError.noBitmap }
        rep.size = bounds.size
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw RenderError.noBitmap }
        return png
    }

    enum RenderError: Error { case noBitmap }

    struct RenderFailure: Error, CustomStringConvertible { var description: String }
}

/// A login item that reports a fixed state, for `--render-ui` and tests.
final class FakeLoginItem: LoginItemControlling {
    private(set) var state: LoginItemState
    private(set) var requests: [Bool] = []

    init(state: LoginItemState) { self.state = state }

    func setEnabled(_ on: Bool) {
        requests.append(on)
        if state != .notInstalled { state = on ? .on : .off }
    }
}
