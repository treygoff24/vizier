import VizierEngine
import SwiftUI

/// The settings window's content: the shared window header with the pane tabs at its right, a
/// Rule, and one pane. The window asks to be as tall as the pane, so no pane sits over empty
/// board; when the screen is too short for that (a long mode list, a long error), the pane scrolls
/// under the header, which stays put.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    @State private var headerHeight: CGFloat = 51
    @State private var paneHeight: CGFloat?

    static let width: CGFloat = 640

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                WindowHeader("Settings") {
                    FlapSegments(options: SettingsModel.Pane.allCases.map { ($0, $0.rawValue) }, selection: $model.pane)
                }
                Ink.rule.frame(height: 1)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
            ScrollView {
                pane
                    .padding(EdgeInsets(top: 4, leading: 22, bottom: 14, trailing: 22))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { paneHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .windowIdealSize(paneHeight.map { CGSize(width: Self.width, height: headerHeight + $0) })
        .background(Ink.window)
        .foregroundStyle(Ink.enamel)
        .font(Face.body)
        .task { await model.refresh() }
    }

    @ViewBuilder private var pane: some View {
        switch model.pane {
        case .general: GeneralPane(model: model)
        case .transcription: TranscriptionPane(model: model)
        case .accounts: AccountsPane(model: model)
        case .words: WordsPane(model: model)
        case .about: AboutPane(model: model)
        }
    }
}

private struct GeneralPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        @Bindable var preferences = model.preferences
        VStack(spacing: 0) {
            SettingRow("Hotkey", hint: "Press it once to start a take and again to stop. Escape cancels a take.") {
                HotkeyPicker(preferences: model.preferences)
            }
            SettingRow("Open at login", hint: loginHint) {
                OnOffSegments(isOn: Binding(get: { model.loginState == .on || model.loginState == .needsApproval }, set: { model.setOpenAtLogin($0) }))
                    .disabled(model.loginState == .notInstalled)
            }
            SettingRow("Show in Dock", hint: "Vizier lives in the menu bar and shows a Dock icon only while one of its windows is open. Turn this on to keep the icon.") {
                OnOffSegments(isOn: $preferences.showInDock)
            }
            SettingRow("Sounds", hint: "A short cue when a take starts, stops, is cancelled, or runs into a problem.", divider: false) {
                OnOffSegments(isOn: $preferences.soundsEnabled)
            }
        }
    }

    private var loginHint: String {
        switch model.loginState {
        case .on, .off: "Start Vizier when you log in to this Mac."
        case .needsApproval: "macOS is waiting for your approval in System Settings, General, Login Items."
        case .notInstalled: "Available once Vizier is in your Applications folder."
        }
    }
}

private struct TranscriptionPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow("Mode", hint: modeHint) {
                VStack(alignment: .leading, spacing: 2) {
                    if model.modePicker.modes.isEmpty, let note = model.modePicker.note {
                        Banner(plate: "Broken file", text: note) {
                            HStack(spacing: 8) {
                                FlapButton(title: "Open vizier.jsonc", icon: .open, height: 26) { model.words.openSettings() }
                                FlapButton(title: "Read it again", height: 26) { model.modePicker.reload() }
                            }
                        }
                    }
                    ForEach(model.modePicker.modes, id: \.id) { mode in
                        ModeChoice(mode: mode, selected: mode.id == model.modePicker.activeModeID, hotkey: model.preferences.hotkey) {
                            Task { await model.selectMode(mode.id) }
                        }
                    }
                    if !model.modePicker.modes.isEmpty, let note = model.modePicker.note {
                        ResultLine("Not switched", .red, note).padding(.top, 8)
                    }
                }
            }
            SettingRow("Apple speech", hint: "Runs on this Mac with no account or key. The model is for the active mode’s language, or your system language when the mode names none.", divider: false) {
                SpeechModelStatusView(model: model.speechModel)
            }
        }
    }

    private var modeHint: String {
        "Which mode your \(model.preferences.hotkey.displayName) key runs. Modes are defined in vizier.jsonc."
    }
}

/// A mode as a radio row (DESIGN.md, Popover): platform code, name, route, and the hotkey's bound
/// tag on the active one.
private struct ModeChoice: View {
    var mode: VizierConfig.Mode
    var selected: Bool
    var hotkey: HotkeyModifier
    var choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                PlatformCode(code: HistoryBoard.platformCode(mode.name))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.name).font(Face.bodyStrong)
                    Text(EngineNames.route(mode)).font(Face.small).foregroundStyle(Ink.ink2)
                }
                Spacer(minLength: 10)
                if selected { BoundTag(text: hotkey.legend.uppercased()) }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected || hovering ? Ink.raise : Color.clear))
            .overlay { if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.rule2, lineWidth: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AccountsPane: View {
    var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keys are optional: the Apple mode needs none. A key turns on the cloud modes that use it. Vizier keeps keys in your Keychain and never shows one again.")
                .font(Face.body).foregroundStyle(Ink.ink2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 14).padding(.bottom, 16)
            ForEach(model.accounts) { account in
                AccountKeyRow(model: account)
                    .padding(.vertical, 16)
                    .overlay(alignment: .top) { Ink.rowRule.frame(height: 1) }
            }
        }
    }
}

private struct WordsPane: View {
    var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            SettingRow("Vocabulary", hint: "Names and terms the cloud modes should listen for, one per line. Apple’s on-device recognizer does not use them; Replacements work in every mode.") {
                FlapButton(title: "Open vocabulary.txt", icon: .open, height: 30) { model.words.openVocabulary() }
            }
            SettingRow("Replacements", hint: "Fixes applied to every take, one rule per line, such as “gonna -> going to”. Whole words, any case.", divider: false) {
                FlapButton(title: "Open replacements.txt", icon: .open, height: 30) { model.words.openReplacements() }
            }
            Text("Both open in your default text editor. Changes apply to the next take.")
                .font(Face.small).foregroundStyle(Ink.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, SettingRowMetrics.labelWidth + 14)
                .padding(.bottom, 4)
        }
    }
}

private struct AboutPane: View {
    var model: SettingsModel

    static let licenseURL = URL(string: "https://github.com/treygoff24/vizier/blob/main/LICENSE")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                AppIconView(size: 72)
                VStack(alignment: .leading, spacing: 6) {
                    Text("VIZIER").font(Face.mark).tracking(3.04)
                    Text(SettingsModel.versionLine).font(Face.row).foregroundStyle(Ink.ink2)
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Ink.rowRule.frame(height: 1) }
            SettingRow("License") {
                // GPL section 5(d): the Appropriate Legal Notices an interactive interface shows.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Copyright © 2026 Trey Goff and the Vizier contributors.")
                        .font(Face.body).fixedSize(horizontal: false, vertical: true)
                    Text("This program comes with ABSOLUTELY NO WARRANTY. It is free software: you may redistribute it under the GNU General Public License, version 3 only.")
                        .font(Face.body).foregroundStyle(Ink.ink2).fixedSize(horizontal: false, vertical: true)
                    BoardLink(title: "Read the license", url: AboutPane.licenseURL)
                }
            }
            SettingRow("Credits") {
                Text("Audio capture, hotkey, paste, and word replacement code adapted from VoiceInk (GPL-3.0). The Archivo typeface, by the Archivo Project Authors (SIL Open Font License). Updates by Sparkle (MIT).")
                    .font(Face.body).foregroundStyle(Ink.ink2).fixedSize(horizontal: false, vertical: true)
            }
            SettingRow("Updates", hint: model.updates.canCheckForUpdates ? nil : UpdateHint.unsigned) {
                FlapButton(title: "Check for updates", height: 30) { model.updates.checkForUpdates() }
                    .disabled(!model.updates.canCheckForUpdates)
            }
            SettingRow("Setup", hint: "Walk through permissions, the speech model, and a practice take again.", divider: false) {
                FlapButton(title: "Open setup guide", height: 30) { model.showOnboarding() }
            }
        }
    }
}
