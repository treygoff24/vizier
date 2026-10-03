import AVFoundation
import AppKit
import VizierEngine
import os

@main
enum VizierApp {
    static func main() {
        if let code = VersionCommand.run(CommandLine.arguments) { exit(code) }
        if let code = KeyCommand.run(CommandLine.arguments) { exit(code) }
        if let code = ImportCommand.run(CommandLine.arguments) { exit(code) }
        if let code = TranscribeAppleCommand.run(CommandLine.arguments) { exit(code) }
        if let code = RenderUICommand.run(CommandLine.arguments) { exit(code) }
        let app = NSApplication.shared
        let delegate: NSApplicationDelegate
        if let flag = CommandLine.arguments.firstIndex(of: "--preview-surfaces") {
            let folder = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : ""
            guard !folder.isEmpty, !folder.hasPrefix("-") else {
                FileHandle.standardError.write(Data("usage: Vizier --preview-surfaces <empty or earlier preview folder>\n".utf8))
                exit(64)
            }
            delegate = PreviewDelegate(folder: URL(filePath: folder, directoryHint: .isDirectory))
        } else if let stop = StartupGate.checkLive() {
            // Another copy is running, or the Dictum-era folders did not move cleanly: say so and
            // quit, before anything is moved, recovered, opened, or created.
            delegate = StoppedLaunchDelegate(stop)
        } else {
            // The gate has moved the Dictum-era folders (only the app itself does this; the
            // one-shot commands above leave them alone), so the stores below open the new paths.
            delegate = AppDelegate()
        }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        MainMenu.install()
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let localModels = LocalModels()
    private var statusItem: StatusItemController?
    private var strip: StripController?
    private var takes: TakeController?
    private var shortcuts: RecordingShortcutManager?
    private var surfaces: Surfaces?
    private var shell: AppShell?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = StatusItemController()
        let strip = StripController()
        // History down must not stop dictation: the takes run with no store and the alert is lit.
        let history: HistoryStore?
        do {
            history = try HistoryStore.openStandard()
        } catch {
            Logger(subsystem: "net.praxient.dictum", category: "history").error("history is unavailable; takes will not be recorded: \(String(describing: error), privacy: .private)")
            statusItem.alert = true
            history = nil
        }
        surfaces = Surfaces(statusItem: statusItem, history: history, config: .standard)
        let takes = TakeController(statusItem: statusItem, strip: strip, history: history)
        let shortcuts = RecordingShortcutManager(takes: takes)
        self.statusItem = statusItem
        self.strip = strip
        self.takes = takes
        self.shortcuts = shortcuts
        let shell = AppShell(shortcuts: shortcuts, takes: takes, history: history)
        self.shell = shell
        surfaces?.popover.openSettings = { [weak shell] in shell?.showSettings() }
        surfaces?.popover.openOnboarding = { [weak shell] in shell?.showOnboarding() }
        surfaces?.popover.checkForUpdates = { Updater.shared.checkForUpdates() }
        surfaces?.popover.canCheckForUpdates = { Updater.shared.canCheckForUpdates }

        // The starter file names Apple's language, so the lookup finishes first (a few milliseconds, off the main thread).
        Task {
            await AppleSpeechModel.resolvePreferredLocale()
            do {
                try ConfigStore.standard.writeStarterFilesIfMissing()
            } catch {
                Logger(subsystem: "net.praxient.dictum", category: "config").error("could not write starter config files: \(String(describing: error), privacy: .private)")
            }
        }
        takes.recoverUnfinishedTakes()
        // Ask for the microphone now, at a calm moment, rather than in the middle of a first take.
        // On a first launch onboarding asks instead, at its Microphone step.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            takes.warmUpCapture()
        case .notDetermined where !shell.needsOnboarding:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                guard granted else { return }
                Task { @MainActor in takes.warmUpCapture() }
            }
        default:
            break
        }
        shortcuts.start(promptForAccessibility: !shell.needsOnboarding)
        shell.start()
        LoginItem.applyDefaultOnce()
        LoginItem.repointIfMoved()
        localModels.start()
        Updater.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        localModels.stop()
    }
}

/// The popover and the History window, wired to the status item. History down leaves the popover
/// with modes and facts but no takes, and no History door target.
final class Surfaces {
    let popover: PopoverController
    private var historyWindow: HistoryWindowController?
    private let historyModel: HistoryModel?

    init(statusItem: StatusItemController, history: HistoryStore?, config: ConfigStore) {
        historyModel = history.map { HistoryModel(store: $0, config: config) }
        popover = PopoverController(model: PopoverModel(history: history, config: config))
        popover.openHistory = { [weak self] id in self?.showHistory(selecting: id) }
        popover.openRerun = { [weak self] in self?.showRerun() }
        statusItem.popover = popover
    }

    func showHistory(selecting id: String?) {
        guard let historyModel else { return }
        let controller = historyWindow ?? HistoryWindowController(model: historyModel)
        historyWindow = controller
        controller.show(selecting: id)
    }

    /// History on the newest take that can be re-run, with its mode row open; plain History when
    /// no take has saved audio.
    func showRerun() {
        guard let historyModel else { return }
        let id = historyModel.newestRerunnable()
        showHistory(selecting: id)
        if let id { historyModel.choosingModeFor = id }
    }
}

/// An accessory app has no visible menu bar, but its key equivalents still route through the main
/// menu, and text fields need Edit's items for Cut, Copy, Paste, and Select All. There is no
/// Quit here: a habitual Cmd+Q in the History window must not stop dictation. Quit is in the popover.
enum MainMenu {
    static func install() {
        let main = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for menu in [NSMenu(title: "Vizier"), edit, window] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }
}
