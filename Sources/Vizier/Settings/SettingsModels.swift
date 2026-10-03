import AppKit
import VizierEngine
import Foundation
import os

/// The Transcription pane's mode picker. The only thing the UI writes to `vizier.jsonc` is the
/// top-level `mode` string, through `ConfigStore.setActiveMode`, which leaves every comment and
/// every other byte alone and refuses to write over a file that changed since it was read.
@Observable
final class ModePickerModel {
    private(set) var modes: [VizierConfig.Mode] = []
    private(set) var activeModeID = ""
    /// Why the list is empty or a switch failed, in words for the pane.
    private(set) var note: String?

    @ObservationIgnored private let config: ConfigStore
    @ObservationIgnored private var snapshot: ConfigStore.SettingsSnapshot?
    @ObservationIgnored private let log = Logger(subsystem: "net.praxient.dictum", category: "settings")

    init(config: ConfigStore) {
        self.config = config
        reload()
    }

    func reload() {
        do {
            let snapshot = try config.settingsSnapshot()
            self.snapshot = snapshot
            modes = snapshot.settings.modes
            activeModeID = snapshot.settings.mode
            note = nil
        } catch {
            snapshot = nil
            modes = []
            // The error names the file itself ("vizier.jsonc: …"); the sentence already did.
            let reason = if case ConfigError.settings(let reason) = error { reason } else { "\(error)" }
            note = "Vizier could not read vizier.jsonc: \(reason)"
        }
    }

    /// Makes `id` the mode takes run through. When the file changed on disk since it was read, the
    /// switch is retried once on the fresh file: the edit touches only the `mode` value, so it
    /// cannot erase what changed. A file that no longer parses is left alone. True when the switch
    /// was written.
    @discardableResult
    func select(_ id: String) -> Bool {
        guard id != activeModeID, let snapshot else { return false }
        do {
            let written: ConfigStore.SettingsSnapshot
            do {
                written = try config.setActiveMode(id, expected: snapshot)
            } catch ModeWriteError.changedOnDisk {
                written = try config.setActiveMode(id, expected: try config.settingsSnapshot())
            }
            self.snapshot = written
            modes = written.settings.modes
            activeModeID = written.settings.mode
            note = nil
            return true
        } catch {
            log.error("could not switch mode: \(String(describing: error), privacy: .private)")
            note = "Could not switch: \(error)"
            return false
        }
    }
}

/// Opens a file in the user's default editor.
protocol FileOpening {
    func open(_ url: URL)
}

struct WorkspaceFileOpener: FileOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

final class FakeFileOpener: FileOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

/// The Words pane: vocabulary and replacements are plain text files the user edits in their own
/// editor. Opening one first writes the starter files if they are missing, so the button always
/// has something to open.
struct WordsFiles {
    let config: ConfigStore
    let opener: any FileOpening

    func openVocabulary() { open(config.vocabularyURL) }
    func openReplacements() { open(config.replacementsURL) }
    /// vizier.jsonc, for the Transcription pane's broken-file banner. A missing file gets the starter.
    func openSettings() { open(config.settingsURL) }

    private func open(_ url: URL) {
        try? config.writeStarterFilesIfMissing()
        opener.open(url)
    }
}

/// Everything the settings window shows, built from injected services.
@Observable
final class SettingsModel {
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", transcription = "Transcription", accounts = "Accounts", words = "Words", about = "About"
        var id: String { rawValue }
    }

    var pane: Pane = .general
    let preferences: AppPreferences
    let modePicker: ModePickerModel
    let speechModel: SpeechModelModel
    let accounts: [AccountKeyModel]
    let words: WordsFiles
    let loginItem: any LoginItemControlling
    var loginState: LoginItemState
    let updates: any UpdateChecking
    var showOnboarding: () -> Void = {}

    init(
        preferences: AppPreferences, config: ConfigStore, speech: SpeechModelModel, accounts: [AccountKeyModel],
        loginItem: any LoginItemControlling, opener: any FileOpening = WorkspaceFileOpener(),
        updates: any UpdateChecking = Updater.shared
    ) {
        self.updates = updates
        self.preferences = preferences
        modePicker = ModePickerModel(config: config)
        speechModel = speech
        self.accounts = accounts
        words = WordsFiles(config: config, opener: opener)
        self.loginItem = loginItem
        loginState = loginItem.state
    }

    /// Open at Login's switch; the state is read back, since macOS may ask for approval instead.
    func setOpenAtLogin(_ on: Bool) {
        loginItem.setEnabled(on)
        loginState = loginItem.state
    }

    /// The Transcription pane's mode choice. The speech model shown is the active mode's language,
    /// so a switch that was written reads the model's state again: a mode in another language
    /// needs that language's model.
    func selectMode(_ id: String) async {
        guard modePicker.select(id) else { return }
        await speechModel.refresh()
    }

    func refresh() async {
        modePicker.reload()
        loginState = loginItem.state
        await speechModel.refresh()
    }

    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))"
    }
}
