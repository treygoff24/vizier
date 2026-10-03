import VizierEngine
import SwiftUI

/// The onboarding window's content: the shared window header with the route of steps at its
/// right, one step, and the footer with Back and the primary button. The window keeps one size
/// for every step so the footer's buttons never move under the pointer.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    static let size = CGSize(width: 640, height: 584)
    /// The step's column lines up under the window title, 96px in.
    static let column: CGFloat = 96

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader("Set up Vizier") {
                if !model.isFirst {
                    StepRoute(current: model.step)
                    BoardLabel(model.position)
                }
            }
            Ink.rule.frame(height: 1)
            Group {
                if model.step == .welcome {
                    WelcomeStep()
                } else {
                    stepContent
                        .padding(EdgeInsets(top: 30, leading: Self.column, bottom: 20, trailing: 56))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Ink.rule.frame(height: 1)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Ink.window)
        .foregroundStyle(Ink.enamel)
        .font(Face.body)
        .task { await model.speech.refresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.pollPermissions()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !model.isFirst { FlapButton(title: "Back", height: 30) { model.back() } }
            Spacer()
            if model.step != .welcome, !model.isLast {
                QuietButton(title: "Finish later") { model.finish() }
                    .help("Close the guide. Settings, About, reopens it.")
            }
            FlapButton(title: primaryTitle, primary: model.isSatisfied, height: 30) { model.next() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(EdgeInsets(top: 14, leading: 22, bottom: 16, trailing: 22))
    }

    private var primaryTitle: String {
        if model.isLast { return "Finish" }
        if model.step == .welcome { return "Get started" }
        return model.isSatisfied ? "Continue" : "Skip this step"
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .microphone: MicrophoneStep(permissions: model.permissions)
        case .accessibility: AccessibilityStep(permissions: model.permissions)
        case .speechModel: SpeechModelStep(speech: model.speech)
        case .hotkey: HotkeyStep(preferences: model.preferences)
        case .accuracy: AccuracyStep(accounts: model.accounts)
        case .practice: PracticeStep(model: model)
        }
    }
}

/// The walk drawn as a line diagram (DESIGN.md, Shapes): a 2px Line Track through one stop per
/// step. Passed stops are filled, the current one is filled inside a Window Black gap and an
/// Enamel ring, and the ones ahead are open rings.
private struct StepRoute: View {
    var current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                if step.rawValue > 0 { Ink.hex(0x3a3935).frame(width: 10, height: 2) }
                stop(step)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(current.title), step \(current.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
    }

    @ViewBuilder private func stop(_ step: OnboardingModel.Step) -> some View {
        if step == current {
            ZStack {
                Circle().strokeBorder(Ink.enamel, lineWidth: 1).frame(width: 14, height: 14)
                Circle().fill(Ink.enamel).frame(width: 8, height: 8)
            }
            .frame(width: 14, height: 14)
        } else if step.rawValue < current.rawValue {
            Circle().fill(Ink.enamel).frame(width: 10, height: 10)
        } else {
            Circle().strokeBorder(Ink.enamel, lineWidth: 2).frame(width: 10, height: 10)
        }
    }
}

/// A text-only control for a way out that should not compete with the primary button.
private struct QuietButton: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title.uppercased()).font(Face.control).tracking(0.92)
                .foregroundStyle(hovering ? Ink.enamel : Ink.ink2)
                .padding(.horizontal, 8).frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A step's title and lead.
private struct StepTitle: View {
    var title: String
    var lead: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Face.font(26, 600, 80)).tracking(0.13)
                .accessibilityAddTraits(.isHeader)
            Text(lead).font(Face.reading).foregroundStyle(Ink.ink2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A short ruled list: a label column and one plain sentence per row.
private struct FactRows: View {
    var rows: [(String, String)]
    var labelWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    BoardLabel(row.0).frame(width: labelWidth, alignment: .leading)
                    Text(row.1).font(Face.body).foregroundStyle(Ink.ink2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Ink.rowRule.frame(height: 1) }
            }
        }
        .overlay(alignment: .bottom) { Ink.rowRule.frame(height: 1) }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            AppIconView(size: 128)
            Text("Say it. It types.")
                .font(Face.font(34, 640, 80)).tracking(0.17)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text("Press your hotkey, talk, and press it again. Vizier turns your speech into text and pastes it where your cursor is, in any app.")
                .font(Face.reading).foregroundStyle(Ink.ink2).lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 10) {
                FactRows(rows: [
                    ("Microphone", "To hear you, only while a take runs."),
                    ("Accessibility", "To notice your hotkey and paste the words."),
                    ("Speech model", "A one-time download from Apple."),
                ])
                Text("Setup is quick, plus a one-time model download. No account needed.")
                    .font(Face.small).foregroundStyle(Ink.ink3)
            }
            .frame(width: 400)
            .padding(.top, 30)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
    }
}

private struct MicrophoneStep: View {
    var permissions: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepTitle(
                title: "Let Vizier hear you",
                lead: "Vizier listens only between your two presses of the hotkey. The lamp on its recording strip lights while the microphone is live.")
            switch permissions.microphone {
            case .granted:
                ResultLine("Granted", .plain, "Vizier can use the microphone.")
            case .notAsked:
                VStack(alignment: .leading, spacing: 12) {
                    FlapButton(title: "Allow microphone", primary: true, height: 30) { Task { await permissions.requestMicrophone() } }
                    Text("macOS will ask you to confirm.").font(Face.small).foregroundStyle(Ink.ink3)
                }
            case .denied:
                VStack(alignment: .leading, spacing: 12) {
                    ResultLine("Denied", .red, "Microphone access is off for Vizier. Turn it on in System Settings, under Privacy & Security, Microphone.")
                    FlapButton(title: "Open Microphone settings", icon: .open, primary: true, height: 30) { permissions.openSettings(.microphone) }
                }
            }
        }
    }
}

/// The step where people quit, so it does the most work: it names the exact pane, opens it,
/// watches for the switch once a second, and covers the two ways the list can go wrong.
private struct AccessibilityStep: View {
    var permissions: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepTitle(
                title: "Turn on Accessibility",
                lead: "Vizier needs it to notice your hotkey in other apps and to paste your words. Only you can turn it on, in System Settings.")
            if permissions.accessibility {
                ResultLine("Granted", .plain, "Accessibility is on. Your hotkey and paste will work in every app.")
            } else {
                ResultLine("Waiting", .plain, "Vizier checks every second and will notice the switch by itself.")
                steps
                trouble
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            step(1) {
                FlapButton(title: "Open Accessibility settings", icon: .open, primary: true, height: 30) {
                    permissions.promptAccessibility()
                    permissions.openSettings(.accessibility)
                }
            }
            step(2) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Find Vizier in the list and turn its switch on.").font(Face.body)
                    Text("macOS may ask for your password or Touch ID.").font(Face.small).foregroundStyle(Ink.ink3)
                }
            }
            step(3) {
                Text("Come back here. This page updates on its own.").font(Face.body)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 3).fill(Ink.well))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Ink.hex(0x202020), lineWidth: 1))
    }

    private func step<Content: View>(_ number: Int, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ModuleCells(text: "\(number)", cell: CGSize(width: 18, height: 26), font: Face.font(15, 800, 72))
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 46)
    }

    private var trouble: some View {
        VStack(alignment: .leading, spacing: 0) {
            troubleRow("Not in the list?") {
                Text("Click + under the list and choose Vizier, or drag Vizier into the list from the Finder.")
                FlapButton(title: "Show Vizier in Finder", height: 26) { permissions.revealApp() }
            }
            troubleRow("On, still waiting?") {
                Text("Select Vizier, remove it with −, then add it again. A copy you built yourself needs this after every rebuild.")
            }
        }
        .overlay(alignment: .bottom) { Ink.rowRule.frame(height: 1) }
    }

    private func troubleRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            BoardLabel(label).frame(width: 118, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) { content() }
                .font(Face.small).foregroundStyle(Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Ink.rowRule.frame(height: 1) }
    }
}

private struct SpeechModelStep: View {
    var speech: SpeechModelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepTitle(
                title: "Get the speech model",
                lead: "Vizier’s Apple mode uses Apple’s speech recognition, which runs on this Mac. macOS downloads the model for your language once.")
            SpeechModelStatusView(model: speech)
        }
    }
}

private struct HotkeyStep: View {
    var preferences: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepTitle(
                title: "Pick your hotkey",
                lead: "Press it once to start a take and again to stop. Escape cancels. Choose a key you don’t use on its own.")
            HotkeyKeycaps(preferences: preferences)
            Text("Most people pick Right Command. Mac laptop keyboards have no Right Control. You can change this later in Settings.")
                .font(Face.small).foregroundStyle(Ink.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AccuracyStep: View {
    var accounts: [AccountKeyModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(
                title: "Add a cloud engine, if you like",
                lead: "Optional. Vizier works now with no key. A key from ElevenLabs or Google turns on their modes, which send your audio to that service.")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(accounts) { account in
                    AccountKeyRow(model: account)
                        .padding(.vertical, 14)
                        .overlay(alignment: .top) { Ink.rowRule.frame(height: 1) }
                }
            }
        }
    }
}

private struct PracticeStep: View {
    var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepTitle(
                title: "Try a take",
                lead: "Press \(model.preferences.hotkey.displayName), say a sentence, and press it again. This time the words land here instead of being pasted.")
            Text(model.practiceResult ?? "Your words will appear here.")
                .font(Face.reading)
                .foregroundStyle(model.practiceResult == nil ? Ink.ink3 : Ink.enamel)
                .lineSpacing(3)
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 2).fill(Ink.raise))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Ink.rule2, lineWidth: 1))
                .accessibilityLabel("Practice take result")
                .accessibilityValue(model.practiceResult ?? "Your words will appear here.")
            if model.practiceResult == nil {
                ResultLine("Waiting", .plain, "Nothing yet. Press \(model.preferences.hotkey.displayName) to start.")
            } else {
                ResultLine("Done", .plain, "That’s all there is to it. From now on Vizier waits in the menu bar.")
            }
        }
    }
}
