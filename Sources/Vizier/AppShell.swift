import AVFoundation
import AppKit
import VizierEngine
import SwiftUI

/// The chrome every Vizier window shares: a dark window whose content runs up under a transparent
/// title bar, so the 50px `WindowHeader` sits in the title bar's row beside the traffic lights.
/// The empty unified toolbar makes that row tall enough to centre the traffic lights on the header
/// (about 26pt down) instead of leaving them in the top 32pt.
enum WindowChrome {
    static func style(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "vizier.window")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Board.color(0x121212)
    }

    /// The window's root view: the content drawn from the window's top edge, not below the title bar.
    static func root<Content: View>(_ content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: .top)
    }

    /// How far a window keeps from the top and bottom of the screen's visible area when it is
    /// sized or moved to fit.
    static let screenMargin: CGFloat = 16

    /// The frame that gives a window `size` while keeping its top-left corner where it is, so a
    /// Settings pane of another height grows or shrinks the window downward. Inside `visible` (the
    /// screen's visible frame) the window is never taller than the screen allows, and a window that
    /// would cross the bottom moves up instead; the content scrolls for the rest.
    static func frame(_ frame: NSRect, fitting size: CGSize, within visible: NSRect? = nil) -> NSRect {
        var height = size.height
        var top = frame.maxY
        if let visible {
            height = min(height, visible.height - 2 * screenMargin)
            top = min(top, visible.maxY)
            if top - height < visible.minY + screenMargin { top = visible.minY + screenMargin + height }
        }
        return NSRect(x: frame.minX, y: top - height, width: size.width, height: height)
    }
}

/// The size a window's content would like, when it differs from the size it is laid out at: a
/// view that scrolls part of itself reports its unscrolled height here.
struct WindowIdealSize: PreferenceKey {
    static let defaultValue: CGSize? = nil
    static func reduce(value: inout CGSize?, nextValue: () -> CGSize?) { value = nextValue() ?? value }
}

extension View {
    /// Asks the window for `size` (nil asks nothing); see `WindowIdealSize`.
    func windowIdealSize(_ size: CGSize?) -> some View { preference(key: WindowIdealSize.self, value: size) }
}

/// Keeps a window the size its SwiftUI content asks for, from the window's top-left corner and
/// inside the screen. The content asks through `windowIdealSize`, or else by the size it lays out
/// at (a fixed-size view). The hosting view's own constraints would size the window for the content
/// plus the title bar's safe area and leave AppKit to choose which edge moves, so it gets none.
final class WindowSizer {
    private weak var window: NSWindow?
    /// The area the window must stay inside; nil leaves it unbounded.
    var visibleFrame: (NSWindow) -> NSRect? = { ($0.screen ?? NSScreen.main)?.visibleFrame }
    private var asked: CGSize?
    private var initial: CGSize = .zero

    /// The hosting view for `content`, measured once while it can still size itself.
    func host<Content: View>(_ content: Content) -> NSView {
        let host = NSHostingView(rootView: WindowChrome.root(content)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in self?.laidOut(size) }
            .onPreferenceChange(WindowIdealSize.self) { [weak self] size in self?.ask(size) })
        initial = host.fittingSize
        host.sizingOptions = []
        return host
    }

    /// Starts sizing `window`, whose content view is the hosting view from `host`.
    func attach(_ window: NSWindow) {
        self.window = window
        fit(asked ?? initial)
    }

    private func laidOut(_ size: CGSize) {
        if asked == nil { fit(size) }
    }

    private func ask(_ size: CGSize?) {
        guard let size else { return }
        asked = size
        fit(size)
    }

    private func fit(_ size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        let frame = WindowChrome.frame(window.frame, fitting: size, within: visibleFrame(window))
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
}

/// A titled dark window around a SwiftUI view that is released on close but kept by the shell so
/// it reopens where it was. `WindowSizer` keeps it the view's size.
final class ShellWindowController: NSWindowController, NSWindowDelegate {
    /// Runs when the window closes, by any route.
    var onClose: () -> Void = {}
    private let sizer: WindowSizer

    init<Content: View>(title: String, autosaveName: String, content: Content, sizer: WindowSizer = WindowSizer()) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = title
        WindowChrome.style(window)
        window.isReleasedWhenClosed = false
        self.sizer = sizer
        window.contentView = sizer.host(content)
        sizer.attach(window)
        window.center()
        // The autosave names are UserDefaults keys, so they keep their Dictum-era spelling.
        window.setFrameAutosaveName(autosaveName)
        super.init(window: window)
        // The saved frame may be from a pane of another height, or from another screen.
        sizer.attach(window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func present() {
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Owns what the menu bar app needs beyond dictation itself: the preferences, the dock rule, and
/// the Settings and Onboarding windows. The app delegate makes one and calls `start()`.
final class AppShell {
    let preferences: AppPreferences
    let dock: DockController
    private let shortcuts: RecordingShortcutManager
    private let takes: TakeController
    private let config: ConfigStore
    private let speech: SpeechModelModel
    private let permissions: PermissionsModel
    private let accounts: [AccountKeyModel]
    private var settingsWindow: ShellWindowController?
    private var settingsModel: SettingsModel?
    private var onboardingWindow: ShellWindowController?

    /// True when onboarding has not been done and the history shows no earlier use.
    let needsOnboarding: Bool

    init(
        shortcuts: RecordingShortcutManager, takes: TakeController, history: HistoryStore?, config: ConfigStore = .standard, preferences: AppPreferences = .standard,
        speechSource: (any SpeechModelSource)? = nil
    ) {
        self.shortcuts = shortcuts
        self.takes = takes
        self.config = config
        self.preferences = preferences
        permissions = PermissionsModel(probe: SystemPermissions())
        speech = SpeechModelModel(source: speechSource ?? SpeechModelSources.live(config: config))
        accounts = [Engines.KeyAccount.elevenLabs, .gemini].map {
            AccountKeyModel(provider: $0, store: KeychainKeyStore(), tester: NetworkKeyTester())
        }
        dock = DockController(preferences: preferences)
        // An install with takes in its history predates onboarding: mark it done rather than nag.
        let takeCount = history.flatMap { try? $0.count() }
        if !preferences.onboardingDone, OnboardingPolicy.isExistingUser(takeCount: takeCount) { preferences.onboardingDone = true }
        needsOnboarding = OnboardingPolicy.shouldOfferAtLaunch(onboardingDone: preferences.onboardingDone, takeCount: takeCount)
        shortcuts.hotkey = preferences.hotkey
        preferences.didChange = { [weak self] setting in
            switch setting {
            case .hotkey: self?.shortcuts.hotkey = self?.preferences.hotkey ?? .rightCommand
            case .showInDock: self?.dock.refresh()
            case .soundsEnabled, .onboardingDone: break
            }
        }
    }

    func start() {
        dock.start()
        if needsOnboarding { showOnboarding() }
    }

    func showSettings() {
        let controller = settingsWindow ?? makeSettings()
        settingsWindow = controller
        // Re-read the mode, login state, and speech model each time the window comes up.
        if let model = settingsModel { Task { await model.refresh() } }
        controller.present()
        dock.refresh()
        NSApp.activate()
    }

    /// Brings the open guide forward, or starts a new one from the Welcome step.
    func showOnboarding() {
        if let open = onboardingWindow, open.window?.isVisible == true {
            open.present()
            NSApp.activate()
            return
        }
        let model = OnboardingModel(permissions: permissions, speech: speech, preferences: preferences, accounts: accounts)
        let controller = ShellWindowController(title: "Set up Vizier", autosaveName: "DictumOnboarding", content: OnboardingView(model: model))
        model.onFinish = { [weak controller] in controller?.close() }
        // The grant happens in System Settings; bring the guide back over it so the GRANTED plate
        // is the next thing the person sees.
        model.onAccessibilityGranted = { [weak controller] in
            controller?.window?.orderFrontRegardless()
            NSApp.activate()
        }
        model.setPracticeSink = { [weak takes] sink in takes?.practiceSink = sink }
        controller.onClose = { [weak model] in model?.windowClosed() }
        onboardingWindow = controller
        permissions.refresh()
        controller.present()
        dock.refresh()
        NSApp.activate()
    }

    private func makeSettings() -> ShellWindowController {
        let model = SettingsModel(preferences: preferences, config: config, speech: speech, accounts: accounts, loginItem: LiveLoginItem())
        model.showOnboarding = { [weak self] in self?.showOnboarding() }
        settingsModel = model
        return ShellWindowController(title: "Vizier Settings", autosaveName: "DictumSettings", content: SettingsView(model: model))
    }
}
