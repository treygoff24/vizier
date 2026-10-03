import AppKit
import VizierEngine
import SwiftUI

/// The History window: an ordinary window the app owns. Opening it activates Vizier; the paste
/// decision holds any take that finishes while Vizier has focus, so nothing lands in here.
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    let model: HistoryModel

    init(model: HistoryModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "History"
        WindowChrome.style(window)
        window.minSize = NSSize(width: 880, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WindowChrome.root(HistoryView(model: model)))
        window.center()
        window.setFrameAutosaveName("DictumHistory") // a UserDefaults key, kept from before the rename
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows the window, on one take when `id` is given.
    func show(selecting id: String? = nil) {
        model.reload()
        if let id { model.reveal(id) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.player.stop()
    }
}

struct HistoryView: View {
    @Bindable var model: HistoryModel
    @FocusState private var focus: Field?

    enum Field { case search, list }

    var body: some View {
        VStack(spacing: 0) {
            header
            Ink.rule.frame(height: 1)
            GeometryReader { geometry in
                let detailWidth = max(360, geometry.size.width / 2.3)
                HStack(spacing: 0) {
                    board.frame(width: geometry.size.width - detailWidth - 1)
                    Ink.rule.frame(width: 1)
                    HistoryDetail(model: model).frame(width: detailWidth)
                }
            }
        }
        .background(Ink.window)
        .foregroundStyle(Ink.enamel)
        .font(Face.body)
        .onAppear { focus = .list }
    }

    private var header: some View {
        WindowHeader("History") {
            searchBox
            FlapSegments(options: [(HistoryFilter.all, "All"), (.problems, "Problems"), (.cancelled, "Cancelled")], selection: $model.filter)
            Text(countLine).font(Face.row).foregroundStyle(Ink.ink3).lineLimit(1).fixedSize()
        }
    }

    private var countLine: String {
        let shown = model.takes.count.formatted(), all = model.total.formatted()
        return "\(model.takes.count == model.total ? all : "\(shown) of \(all)") · \(HistoryBoard.bytes(model.totalBytes))"
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            BoardIcon.search.view(14).foregroundStyle(focus == .search ? Ink.ink2 : Ink.ink3)
            TextField("", text: $model.query, prompt: Text("FIND A TAKE").font(Face.control).foregroundStyle(Ink.ink3))
                .textFieldStyle(.plain)
                .font(Face.body)
                .focused($focus, equals: .search)
                .frame(width: 180)
                .onKeyPress(.escape) {
                    if model.query.isEmpty { focus = .list } else { model.query = "" }
                    return .handled
                }
                .onKeyPress(.downArrow) { focus = .list; return .handled }
                .accessibilityLabel("Search history")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 2).fill(Ink.raise))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(focus == .search ? Ink.edgeFocus : Ink.rule2, lineWidth: 1))
    }

    private var board: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BoardLabel("Time").frame(width: 56, alignment: .leading)
                BoardLabel("To").frame(width: 72, alignment: .leading)
                BoardLabel("Plat").frame(width: 30, alignment: .leading)
                BoardLabel("Words").frame(width: 44, alignment: .leading)
                BoardLabel("Status").frame(width: 92, alignment: .leading)
                BoardLabel("Text")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            Ink.rule.frame(height: 1)
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.days, id: \.start) { day in
                        Section {
                            ForEach(day.takes) { take in
                                HistoryRow(model: model, take: take, selected: take.id == model.selectedID)
                                    .id(take.id)
                                    .onTapGesture { model.selectedID = take.id; focus = .list }
                            }
                        } header: {
                            HStack {
                                BoardLabel(day.label)
                                Spacer()
                                Text(day.takes.count.formatted()).font(Face.label).foregroundStyle(Ink.ink3)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(Ink.window)
                        }
                    }
                    if model.loaded && model.days.isEmpty { emptyState }
                }
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focused($focus, equals: .list)
            .focusEffectDisabled()
            .overlay { if focus == .list { Rectangle().strokeBorder(Ink.enamel, lineWidth: 2).allowsHitTesting(false) } }
            .onKeyPress(.downArrow) { model.move(by: 1); return .handled }
            .onKeyPress(.upArrow) { model.move(by: -1); return .handled }
            .onKeyPress(.space) { if let take = model.selected { model.player.toggle(take) }; return .handled }
            .onKeyPress(characters: ["/"]) { _ in focus = .search; return .handled }
            .onCopyCommand { model.selected?.bestText.map { [NSItemProvider(object: $0 as NSString)] } ?? [] }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(nil) { proxy.scrollTo(id) }
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(nil) { proxy.scrollTo(target.id, anchor: .center) }
            }
        }
        .accessibilityLabel("Takes")
    }

    @ViewBuilder private var emptyState: some View {
        let text: String = if let error = model.loadError { "History could not be read: \(error)" }
            else if !model.query.isEmpty { "Nothing matches “\(model.query)”." }
            else { "No takes in this view." }
        Text(text).font(Face.body).foregroundStyle(Ink.ink3).padding(.vertical, 44).frame(maxWidth: .infinity)
    }
}

/// One 33px board row: time in modules, destination, platform, words, status, then the text.
struct HistoryRow: View {
    let model: HistoryModel
    let take: TakeRecord
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ModuleCells(text: HistoryBoard.clock(take.startedAt), cell: CGSize(width: 10, height: 15), font: Face.module, colonWidth: 6)
                .frame(width: 56, alignment: .leading)
            Text((take.destination ?? "—").uppercased()).font(Face.row).lineLimit(1).frame(width: 72, alignment: .leading)
            Text(model.modeCode(take.modeID)).font(Face.row).frame(width: 30, alignment: .leading)
            Text(take.words.map { $0.formatted() } ?? "—").font(Face.row).frame(width: 44, alignment: .leading)
            StatusPlate(take.outcome, small: true).frame(width: 92, alignment: .leading)
            Text(rowText).font(Face.rowText).foregroundStyle(take.bestText == nil && take.rerunText == nil ? Ink.ink3 : Ink.ink2).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 33)
        .background(selected ? Ink.rowSelected : hovering ? Ink.rowHover : Color.clear)
        .overlay(alignment: .leading) { if selected { Ink.enamel.frame(width: 1) } }
        .overlay(alignment: .bottom) { Ink.rowRule.frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var rowText: String {
        if let text = take.bestText ?? take.rerunText { return text.replacingOccurrences(of: "\n", with: " ") }
        return switch take.outcome {
        case .cancelled: "Cancelled before any words."
        case .recording, .finalizing: "In progress."
        default: "No text."
        }
    }
}

/// The right side: the take's clock, facts, audio, and text.
struct HistoryDetail: View {
    let model: HistoryModel
    @State private var copied = false

    var body: some View {
        if let take = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    head(take)
                    if let reason = Self.reason(take) {
                        Text(reason).font(Face.remarks).foregroundStyle(Ink.ink2).frame(maxWidth: 480, alignment: .leading)
                            .padding(.top, -6)
                    }
                    fields(take)
                    wave(take)
                    text(take)
                    reruns(take)
                }
                .padding(EdgeInsets(top: 20, leading: 22, bottom: 24, trailing: 22))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: take.id) {
                copied = false
            }
        } else {
            Text(model.loaded ? "Select a take." : "").font(Face.body).foregroundStyle(Ink.ink3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func head(_ take: TakeRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ModuleCells(text: HistoryBoard.clock(take.startedAt), cell: CGSize(width: 27, height: 40), font: Face.clock,
                        gap: 2, colonWidth: 13, radius: 3)
            Text(HistoryBoard.dayLabel(take.startedAt) + dateSuffix(take.startedAt)).font(Face.body).foregroundStyle(Ink.ink2)
                .frame(maxHeight: 40, alignment: .bottom)
            Spacer(minLength: 8)
            StatusPlate(take.outcome)
        }
    }

    private func dateSuffix(_ date: Date) -> String {
        let label = HistoryBoard.dayLabel(date)
        guard label == "Today" || label == "Yesterday" else { return "" }
        return ", " + date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func fields(_ take: TakeRecord) -> some View {
        let values: [(String, String)] = [
            ("To", (take.destination ?? "—").uppercased()),
            ("Plat", model.modeName(take.modeID)),
            ("Words", take.words.map { $0.formatted() } ?? "—"),
            ("Length", HistoryBoard.length(take.durationMs)),
            ("After stop", HistoryBoard.seconds(take.pasteMs)),
            ("Via", (take.route ?? "—").uppercased()),
            ("Audio", HistoryBoard.bytes(take.audioBytes)),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 14, alignment: .topLeading), count: 4),
                         alignment: .leading, spacing: 12) {
            ForEach(values, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 4) {
                    BoardLabel(label)
                    Text(value).font(Face.fieldValue).lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }

    private func wave(_ take: TakeRecord) -> some View {
        let hasAudio = take.audioPath.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let playing = model.player.playingID == take.id
        let running = model.rerunning[take.id]
        let choosingMode = model.choosingModeFor == take.id
        return VStack(alignment: .leading, spacing: 10) {
            WaveformBars(bars: model.bars[take.id] ?? [], playing: playing, player: model.player)
                .frame(height: 60)
            HStack(spacing: 8) {
                FlapButton(title: playing ? "Stop" : "Play", icon: playing ? .stop : .play) { model.player.toggle(take) }
                    .disabled(!hasAudio)
                    .help("Space")
                FlapButton(title: copied ? "Copied" : "Copy", icon: copied ? .check : .copy) {
                    guard let text = take.bestText else { return }
                    HistoryModel.copy(text)
                    copied = true
                }
                .disabled(take.bestText == nil)
                FlapButton(title: running == nil ? "Re-run" : "Re-running", icon: .rerun, primary: choosingMode) {
                    model.choosingModeFor = choosingMode ? nil : take.id
                }
                .disabled(!model.canRerun(take) || running != nil || model.modeList.isEmpty)
                .help("Send the saved audio through a mode again. Nothing is pasted.")
                if !hasAudio {
                    Text("No audio was saved for this take.").font(Face.small).foregroundStyle(Ink.ink3)
                }
            }
            if choosingMode && running == nil {
                modePicker(take)
            }
            if let running {
                Text("Re-running through \(running)…").font(Face.small).foregroundStyle(Ink.ink2)
            } else if let notice = model.rerunNotice[take.id] {
                Text(notice).font(Face.small).foregroundStyle(Ink.ink2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 3).fill(Ink.well))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Ink.hex(0x202020), lineWidth: 1))
    }

    @ViewBuilder private func text(_ take: TakeRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BoardLabel(Self.textHeading(take))
            Text(take.bestText ?? "No text was pasted.")
                .font(Face.reading)
                .lineSpacing(15 * 0.5 - 4)
                .foregroundStyle(take.bestText == nil ? Ink.ink3 : Ink.enamel)
                .textSelection(.enabled)
                .frame(maxWidth: 560, alignment: .leading)
            if let raw = take.rawTranscript, let best = take.bestText, raw != best {
                BoardLabel("Raw transcript").padding(.top, 10)
                Text(raw)
                    .font(Face.reading)
                    .lineSpacing(15 * 0.5 - 4)
                    .foregroundStyle(Ink.ink2)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
    }

    /// One flap per mode; the take's own mode first.
    private func modePicker(_ take: TakeRecord) -> some View {
        let ordered = model.modeList.filter { $0.id == take.modeID } + model.modeList.filter { $0.id != take.modeID }
        let buttons = ForEach(ordered, id: \.id) { mode in
            FlapButton(title: mode.name, icon: nil) {
                model.choosingModeFor = nil
                model.rerun(take, through: mode)
            }
            .fixedSize()
            .disabled(mode.fallback == nil)
            .help(mode.fallback.map { "\(EngineNames.name($0.engine)), then this mode's cleanup and replacements"
                                      + (mode.id == take.modeID ? ". The mode this take used." : ".") }
                  ?? "\(mode.name) has no batch engine, so it cannot re-run saved audio.")
        }
        return VStack(alignment: .leading, spacing: 8) {
            BoardLabel("Re-run through")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
        }
        .padding(.top, 2)
    }

    /// Every re-run of the take, newest first, each with its own copy button.
    @ViewBuilder private func reruns(_ take: TakeRecord) -> some View {
        let attempts = (model.reruns[take.id] ?? []).reversed()
        if !attempts.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(attempts)) { attempt in
                    RerunView(model: model, attempt: attempt)
                }
            }
            .padding(.top, 4)
        }
    }

    static func textHeading(_ take: TakeRecord) -> String {
        switch take.outcome {
        case .pasted, .rerouted: "Pasted"
        case .held: "Held on the clipboard"
        case .failed: take.bestText == nil ? "Not pasted" : "Not pasted: what was heard"
        case .cancelled: "Cancelled"
        case .recording, .finalizing: "In progress"
        }
    }

    /// One plain sentence for why a take did not simply paste, from its stored reason.
    static func reason(_ take: TakeRecord) -> String? {
        guard let reason = take.outcomeReason, !reason.isEmpty else { return nil }
        switch reason {
        case "batch": return "The live stream dropped, so the saved audio went through batch."
        case "settled words": return "The live transcript did not finish, so the settled words were pasted."
        case "raw text": return "The cleanup pass did not finish or was not trusted, so the raw transcript was pasted."
        case "interrupted before delivery": return "Vizier stopped before this take finished. The audio is saved."
        case "paste failed": return "The paste did not go through. The text went to the clipboard."
        case "accessibility not granted": return "Vizier did not have Accessibility access, so nothing was pasted. The text went to the clipboard."
        case PasteDecision.vizierHadFocus, PasteDecision.legacyDictumHadFocus: return "Vizier itself had focus, so nothing was pasted. The text went to the clipboard."
        case PasteDecision.secureField: return "A password field had focus, so nothing was pasted. The text went to the clipboard."
        case PasteDecision.secureInput: return "Secure input was on and the focused field could not be read, so nothing was pasted. The text went to the clipboard."
        default:
            if take.outcome == .held { return "No text field had focus, so nothing was pasted. The text went to the clipboard." }
            return reason
        }
    }
}

/// One re-run: its number, mode, and time, then its text or why it failed.
struct RerunView: View {
    let model: HistoryModel
    let attempt: TakeAttempt

    var body: some View {
        let worked = attempt.outcome == TakeAttempt.transcribed && attempt.finalText != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                BoardLabel("Re-run \(attempt.number) · \(model.modeName(attempt.modeID)) · \(HistoryBoard.clock(attempt.createdAt))")
                if !worked { StatusPlate(.failed, small: true) }
                Spacer(minLength: 8)
                if let text = attempt.finalText {
                    let copied = model.copiedAttempt == attempt.id
                    FlapButton(title: copied ? "Copied" : "Copy", icon: copied ? .check : .copy, height: 22) {
                        HistoryModel.copy(text)
                        model.copiedAttempt = attempt.id
                    }
                }
            }
            .frame(maxWidth: 560)
            if let text = attempt.finalText {
                Text(text)
                    .font(Face.reading)
                    .lineSpacing(15 * 0.5 - 4)
                    .foregroundStyle(Ink.enamel)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            if let reason = attempt.outcomeReason {
                Text(reason).font(Face.small).foregroundStyle(worked ? Ink.ink3 : Ink.ink2).frame(maxWidth: 560, alignment: .leading)
            }
            if let seconds = timing { Text(seconds).font(Face.small).foregroundStyle(Ink.ink3) }
        }
    }

    private var timing: String? {
        guard let transcription = attempt.transcriptionMs else { return nil }
        let total = transcription + (attempt.cleanupMs ?? 0)
        return "\(HistoryBoard.seconds(total)) via \(EngineNames.name(attempt.transcriberEngine))"
            + (attempt.cleanerEngine.map { " and \(EngineNames.name($0))" } ?? "")
    }
}

/// The waveform well: 64 bars around the split, played bars in enamel, and the playhead.
struct WaveformBars: View {
    let bars: [Float]
    let playing: Bool
    let player: TakePlayer

    var body: some View {
        TimelineView(.animation(paused: !playing)) { _ in
            let progress = playing ? player.progress : 0
            Canvas { context, size in
                let mid = size.height / 2
                context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(Ink.plateSplit))
                guard !bars.isEmpty else { return }
                let step = size.width / CGFloat(bars.count)
                let width = min(3.2, step * 0.8)
                let played = Int((progress * Double(bars.count)).rounded(.down))
                for (index, value) in bars.enumerated() where value > 0 {
                    let height = max(2, CGFloat(value) * (size.height - 4))
                    let rect = CGRect(x: CGFloat(index) * step + (step - width) / 2, y: mid - height / 2, width: width, height: height)
                    let color = playing && index < played ? Ink.enamel : Ink.waveBar
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(color))
                }
                if playing {
                    let x = size.width * progress
                    context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Ink.enamel))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
