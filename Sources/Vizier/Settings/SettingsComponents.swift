import AppKit
import VizierEngine
import SwiftUI

/// Small Departures pieces shared by the settings window and onboarding.

/// One setting: a label in the board's label column, then the control with its explanation under
/// it. Rows sit on Row Rule hairlines.
struct SettingRow<Control: View>: View {
    var label: String
    var hint: String?
    var divider: Bool
    @ViewBuilder var control: Control

    init(_ label: String, hint: String? = nil, divider: Bool = true, @ViewBuilder control: () -> Control) {
        self.label = label
        self.hint = hint
        self.divider = divider
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            // The label shares a baseline with the control's first line of text, whether that is a
            // button's title, a segment, or a sentence.
            BoardLabel(label)
                .frame(width: SettingRowMetrics.labelWidth, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                control
                if let hint {
                    Text(hint).font(Face.body).foregroundStyle(Ink.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { if divider { Ink.rowRule.frame(height: 1) } }
    }
}

enum SettingRowMetrics {
    static let labelWidth: CGFloat = 128
}

/// A two-segment ON / OFF flap, the board's switch.
struct OnOffSegments: View {
    @Binding var isOn: Bool
    var body: some View {
        FlapSegments(options: [(true, "On"), (false, "Off")], selection: $isOn)
    }
}

/// A result: a small status plate that names the state, and one plain sentence. The tone lives in
/// the plate's fill (DESIGN.md, the Tone-by-Fill Rule); the sentence stays in the reading ink.
struct ResultLine: View {
    var plate: String
    var tone: FlapTone
    var text: String

    init(_ plate: String, _ tone: FlapTone, _ text: String) {
        self.plate = plate
        self.tone = tone
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusPlate(text: plate.uppercased(), tone: tone, small: true)
            Text(text).font(Face.body).foregroundStyle(Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A wider warning (DESIGN.md, Notes and Banners): a faint wash of the tone's hue with a 1px inset,
/// 7px corners, its plate, the fact, and an action.
struct Banner<Actions: View>: View {
    var plate: String
    var text: String
    @ViewBuilder var actions: Actions

    init(plate: String, text: String, @ViewBuilder actions: () -> Actions) {
        self.plate = plate
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusPlate(text: plate.uppercased(), tone: .red, small: true)
                Text(text).font(Face.body).foregroundStyle(Ink.enamel).fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 10, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Ink.hex(0xc8102e, 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.hex(0xc8102e, 0.45), lineWidth: 1))
    }
}

/// A link (DESIGN.md, Buttons): Enamel White text over an Edge Hover underline 3px below, which
/// turns Enamel White on hover.
struct BoardLink: View {
    var title: String
    var url: URL
    @State private var hovering = false

    var body: some View {
        Link(destination: url) {
            Text(title).font(Face.body).foregroundStyle(Ink.enamel)
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) { (hovering ? Ink.enamel : Ink.edgeHover).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.absoluteString)
    }
}

/// A single-line input in the board's well.
struct BoardFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(Face.body)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 2).fill(Ink.raise))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Ink.rule2, lineWidth: 1))
    }
}

/// One provider's key: a field, Save, Test, and what happened. A saved key is never shown.
struct AccountKeyRow: View {
    @Bindable var model: AccountKeyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.provider.name).font(Face.bodyStrong)
                if model.hasSavedKey { StatusPlate(text: "SAVED", tone: .plain, small: true) }
                Spacer(minLength: 14)
                if let url = AccountCopy.keyPage(model.provider) { BoardLink(title: "Get a key", url: url) }
            }
            Text(AccountCopy.use(model.provider)).font(Face.body).foregroundStyle(Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("", text: $model.draft, prompt: Text(model.hasSavedKey ? "Paste a new key to replace the saved one" : "Paste your \(model.provider.name) key").foregroundStyle(Ink.ink3))
                    .textFieldStyle(BoardFieldStyle())
                    .onSubmit { model.save() }
                    .accessibilityLabel("\(model.provider.name) key")
                FlapButton(title: "Save", primary: model.canSave, height: 30) { model.save() }.disabled(!model.canSave)
                FlapButton(title: model.test == .testing ? "Testing" : "Test", height: 30) {
                    Task { await model.runTest() }
                }
                .disabled(!model.canTest)
            }
            if let error = model.saveError {
                ResultLine("Not saved", .red, error)
            } else if model.test == .testing {
                ResultLine("Checking", .plain, "Asking \(model.provider.name) whether the key works.")
            } else if case .finished(let result) = model.test {
                switch result {
                case .passed: ResultLine("Works", .plain, result.message)
                case .rejected: ResultLine("Rejected", .red, result.message)
                case .lacksPermission: ResultLine("Unconfirmed", .white, result.message)
                case .unreachable: ResultLine("No answer", .white, result.message)
                }
            }
        }
    }
}

/// What each key is for and where to get one.
enum AccountCopy {
    static func use(_ provider: Engines.KeyAccount) -> String {
        provider == .elevenLabs
            ? "For the Scribe modes: ElevenLabs’ speech engine, with live words as you talk."
            : "For the Gemini modes, and for cleanup that tidies a take before it pastes."
    }

    static func keyPage(_ provider: Engines.KeyAccount) -> URL? {
        switch provider {
        case .elevenLabs: URL(string: "https://elevenlabs.io/app/developers/api-keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        default: nil
        }
    }
}

/// A download's progress as a plain bar, no animation.
struct ProgressBar: View {
    var fraction: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Ink.raise2)
                Rectangle().fill(Ink.enamel).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .clipShape(RoundedRectangle(cornerRadius: 1))
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// The Apple speech model: language, state, and the download button. Used by the Transcription
/// pane and the onboarding download step.
struct SpeechModelStatusView: View {
    var model: SpeechModelModel
    var showLanguage = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showLanguage {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    BoardLabel("Language")
                    Text(model.languageName).font(Face.fieldValue)
                }
            }
            switch model.state {
            case .checking:
                ResultLine("Checking", .plain, "Looking for the model on this Mac.")
            case .installed:
                ResultLine("Installed", .plain, "The model is on this Mac and ready.")
            case .unsupported:
                ResultLine("Unsupported", .white, "Apple’s on-device speech doesn’t cover this language yet, so the Apple mode can’t transcribe it. Scribe and Gemini cover many more languages: add a key under Accounts, then choose that mode under Transcription.")
            case .notInstalled:
                FlapButton(title: "Download speech model", primary: true, height: 30) { Task { await model.download() } }
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        StatusPlate(text: "DOWNLOADING", tone: .plain, small: true)
                        Text("\(Int((fraction * 100).rounded()))%").font(Face.row).foregroundStyle(Ink.ink2)
                    }
                    ProgressBar(fraction: fraction).frame(maxWidth: 360)
                }
            case .failed(let message):
                ResultLine("Failed", .red, "The download stopped: \(message)")
                FlapButton(title: "Try again", height: 30) { Task { await model.download() } }
            }
        }
    }
}

/// The hotkey choice as segments, for the settings window.
struct HotkeyPicker: View {
    @Bindable var preferences: AppPreferences
    var body: some View {
        FlapSegments(options: HotkeyModifier.allCases.map { ($0, $0.displayName) }, selection: $preferences.hotkey)
    }
}

/// The hotkey choice as three keycaps, for onboarding: the chosen key takes the white faces.
struct HotkeyKeycaps: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        HStack(spacing: 10) {
            ForEach(HotkeyModifier.allCases, id: \.self) { key in
                let chosen = preferences.hotkey == key
                Button { preferences.hotkey = key } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(key.keycap).font(.system(size: 22, weight: .medium))
                        Spacer(minLength: 0)
                        Text(key.displayName.uppercased()).font(Face.control).tracking(0.92)
                    }
                    .foregroundStyle(chosen ? Ink.board : Ink.enamel)
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 11, trailing: 12))
                    .frame(width: 150, height: 78, alignment: .leading)
                    .background(chosen
                        ? FlapFace(top: Ink.hex(0xeeebe4), bottom: Ink.hex(0xe4e1d9), split: Ink.hex(0xc9c6be), radius: 3)
                        : FlapFace.tone(.module, radius: 3))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.displayName)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
}

/// The app's icon: whatever icon the running bundle carries.
struct AppIconView: View {
    var size: CGFloat
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
