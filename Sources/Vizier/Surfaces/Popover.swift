import AppKit
import VizierEngine
import SwiftUI
import os

/// What the popover shows: the modes and which one the hotkey runs, the last six takes, and
/// today's facts. Read fresh each time the popover opens and whenever history changes.
@Observable
final class PopoverModel {
    let history: HistoryStore?
    let config: ConfigStore

    private(set) var modes: [VizierConfig.Mode] = []
    private(set) var activeModeID = ""
    private(set) var modeNote: String?
    private(set) var recent: [TakeRecord] = []
    private(set) var today: [TakeRecord] = []
    private(set) var mic = ""
    /// The take the alert square was lit for, when it is still among the recent ones.
    private(set) var alertTake: TakeRecord?
    var copiedID: String?
    /// Whether Check for Updates can run; set each time the popover opens.
    var canCheckForUpdates = false

    @ObservationIgnored private var snapshot: ConfigStore.SettingsSnapshot?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: "net.praxient.dictum", category: "popover")

    init(history: HistoryStore?, config: ConfigStore) {
        self.history = history
        self.config = config
        if let history {
            observer = NotificationCenter.default.addObserver(forName: HistoryStore.didChange, object: history, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadTakes() }
            }
        }
    }

    func refresh(alertWasLit: Bool) {
        copiedID = nil
        loadModes()
        reloadTakes()
        alertTake = alertWasLit ? recent.first { $0.outcome == .held || $0.outcome == .failed } : nil
        let device = try? HALCapture.defaultInputDevice()
        mic = device.flatMap(HALCapture.deviceName) ?? "No input device"
    }

    private func loadModes() {
        do {
            let snapshot = try config.settingsSnapshot()
            self.snapshot = snapshot
            modes = snapshot.settings.modes
            activeModeID = snapshot.settings.mode
            modeNote = nil
        } catch {
            // A broken file keeps the last good config running; the menu shows it read-only.
            let load = config.load()
            snapshot = nil
            modes = load.config.settings.modes
            activeModeID = load.config.activeMode.id
            modeNote = "The settings file has an error, so modes can't be switched here. Vizier is running the last good settings."
        }
    }

    private func reloadTakes() {
        guard let history else { return }
        do {
            recent = try history.recent(limit: 6)
            let midnight = Calendar.current.startOfDay(for: .now)
            today = try history.recent(limit: 2_000).filter { $0.startedAt >= midnight }
        } catch {
            log.error("could not read recent takes: \(String(describing: error), privacy: .private)")
        }
    }

    /// Writes `id` as the mode in vizier.jsonc, changing only that value. If the file changed since
    /// the popover opened, the switch is retried once on the fresh file: the edit touches nothing
    /// else, so it cannot erase what changed.
    func activate(_ id: String) {
        guard id != activeModeID else { return }
        guard let snapshot else { return }
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
            modeNote = nil
        } catch {
            log.error("could not switch mode: \(String(describing: error), privacy: .private)")
            modeNote = "Could not switch: \(error)."
        }
    }

    var todayLine: String {
        let takes = today.filter { $0.outcome != .cancelled }
        guard !takes.isEmpty else { return "No takes yet today." }
        let words = takes.reduce(0) { $0 + ($1.words ?? 0) }
        let latencies = takes.compactMap(\.pasteMs).sorted()
        let median = latencies.isEmpty ? "" : ", median \(HistoryBoard.seconds(latencies[latencies.count / 2])) after stop"
        return "\(takes.count.formatted()) takes, \(words.formatted()) words\(median)"
    }

    var engineLine: String {
        guard let last = recent.first(where: { $0.outcome != .cancelled && $0.outcome != .recording && $0.outcome != .finalizing }) else {
            return "No takes yet."
        }
        let time = HistoryBoard.clock(last.startedAt)
        switch last.outcome {
        case .failed: return "Nothing came back at \(time). Audio saved."
        case .held: return "Held at \(time). The text went to the clipboard."
        default:
            let after = last.pasteMs.map { ", \(HistoryBoard.seconds($0)) after stop" } ?? ""
            return "Answered at \(time)\(after)."
        }
    }
}

/// The panel under the status item. It can take key (so its buttons and hover work) without
/// activating Vizier, and it closes the moment a take starts, so a paste never lands in it.
final class PopoverController: NSObject, NSWindowDelegate {
    let model: PopoverModel
    var openHistory: (String?) -> Void = { _ in }
    /// Opens History on the newest take with saved audio, its Re-run modes showing.
    var openRerun: () -> Void = {}
    /// Opens the Settings window.
    var openSettings: () -> Void = {}
    /// Opens the setup guide (onboarding) again.
    var openOnboarding: () -> Void = {}
    /// Runs Sparkle's check; `canCheckForUpdates` is asked each time the popover opens.
    var checkForUpdates: () -> Void = {}
    var canCheckForUpdates: () -> Bool = { false }
    /// Called when the popover closes itself (a click outside, a door); the status item ends its
    /// expanded-interface session in response.
    var onDismiss: () -> Void = {}

    private var panel: PopoverPanel?
    private var anchor: NSRect = .zero
    private var monitors: [Any] = []

    init(model: PopoverModel) {
        self.model = model
        super.init()
    }

    var isShown: Bool { panel?.isVisible == true }

    /// Shows the popover under `anchor`, a rect in screen coordinates (the status item's button).
    func show(under anchor: NSRect, alertWasLit: Bool) {
        self.anchor = anchor
        model.refresh(alertWasLit: alertWasLit)
        model.canCheckForUpdates = canCheckForUpdates()
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
    }

    func close() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    private func makePanel() -> PopoverPanel {
        let panel = PopoverPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        let host = NSHostingController(rootView: PopoverView(model: model, openHistory: { [weak self] id in
            self?.dismiss()
            self?.openHistory(id)
        }, openRerun: { [weak self] in
            self?.dismiss()
            self?.openRerun()
        }, openSettings: { [weak self] in
            self?.dismiss()
            self?.openSettings()
        }, openOnboarding: { [weak self] in
            self?.dismiss()
            self?.openOnboarding()
        }, checkForUpdates: { [weak self] in
            self?.dismiss()
            self?.checkForUpdates()
        }))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        return panel
    }

    /// Top edge 6pt under the item, left edge at the item, kept on the item's screen.
    private func place(_ panel: NSPanel) {
        let size = panel.contentViewController?.preferredContentSize ?? panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.minX - 8
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(anchor.minY - 6, visible.maxY)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        // The content grew or shrank (a banner, a note): keep the top edge pinned under the item.
        guard let panel, panel.isVisible else { return }
        let frame = panel.frame, top = anchor.minY - 6
        if abs(frame.maxY - top) > 0.5 { panel.setFrameOrigin(NSPoint(x: frame.minX, y: top - frame.height)) }
    }

    func dismiss() {
        close()
        onDismiss()
    }

    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown {
                // Escape closes the popover only while it is key; the event tap owns Escape during a take.
                if event.keyCode == 53, event.window === panel { self.dismiss(); return nil }
                return event
            }
            if event.window !== panel { self.dismiss() }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct PopoverView: View {
    @Bindable var model: PopoverModel
    var openHistory: (String?) -> Void
    var openRerun: () -> Void
    var openSettings: () -> Void = {}
    var openOnboarding: () -> Void = {}
    var checkForUpdates: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if let take = model.alertTake { alertBanner(take) }
            section { modes }
            section { board }
            section { facts }
            doors
        }
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.window))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.rule2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(Ink.enamel)
        .font(Face.body)
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Ink.rule.frame(height: 1)
            content().padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private var head: some View {
        HStack {
            Text("VIZIER").font(Face.mark).tracking(3.04)
            Spacer()
            TimelineView(.everyMinute) { context in
                ModuleCells(text: HistoryBoard.clock(context.date), cell: CGSize(width: 13, height: 19), font: Face.font(13, 700, 72), colonWidth: 8)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
    }

    private func alertBanner(_ take: TakeRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            StatusPlate(take.outcome, small: true)
            Text(take.outcome == .held ? "The \(HistoryBoard.clock(take.startedAt)) take had nowhere to paste."
                                       : "The \(HistoryBoard.clock(take.startedAt)) take did not paste.")
                .font(Face.remarks).foregroundStyle(Ink.ink2).lineLimit(2)
            Spacer(minLength: 4)
            if let text = take.bestText {
                FlapButton(title: model.copiedID == take.id ? "Copied" : "Copy", icon: model.copiedID == take.id ? .check : .copy) {
                    HistoryModel.copy(text)
                    model.copiedID = take.id
                }
            }
            FlapButton(title: "Open", icon: .open) { openHistory(take.id) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(take.outcome == .failed ? Ink.hex(0xc8102e, 0.13) : Ink.raise)
    }

    private var modes: some View {
        VStack(alignment: .leading, spacing: 8) {
            BoardLabel("\(AppPreferences.standard.hotkey.legend) departs on")
            VStack(spacing: 2) {
                ForEach(model.modes, id: \.id) { mode in
                    ModeRow(mode: mode, on: mode.id == model.activeModeID) { model.activate(mode.id) }
                }
            }
            if let note = model.modeNote {
                Text(note).font(Face.small).foregroundStyle(Ink.signalRed).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BoardLabel("Time").frame(width: 56, alignment: .leading)
                BoardLabel("To").frame(width: 70, alignment: .leading)
                BoardLabel("Plat").frame(width: 32, alignment: .leading)
                BoardLabel("Words").frame(width: 44, alignment: .leading)
                BoardLabel("Status")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            if model.recent.isEmpty {
                Text(model.history == nil ? "History is unavailable." : "No takes yet.").font(Face.body).foregroundStyle(Ink.ink3)
                    .padding(.horizontal, 6).padding(.vertical, 8)
            }
            ForEach(model.recent) { take in
                RecentRow(take: take, code: code(take.modeID), copied: model.copiedID == take.id,
                          open: { openHistory(take.id) },
                          copy: {
                              guard let text = take.bestText else { return }
                              HistoryModel.copy(text)
                              model.copiedID = take.id
                          })
            }
        }
    }

    private func code(_ modeID: String) -> String {
        if let mode = model.modes.first(where: { $0.id == modeID }) { return HistoryBoard.platformCode(mode.name) }
        if modeID == VoiceInkImport.modeID { return "VI" }
        return modeID == "unknown" ? "—" : HistoryBoard.platformCode(modeID)
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 6) {
            fact("Mic", model.mic)
            fact("Engine", model.engineLine)
            fact("Today", model.todayLine)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            BoardLabel(label).frame(width: 58, alignment: .leading)
            // A no-break space keeps "0.44 s" on one line.
            Text(value.replacingOccurrences(of: " s ", with: "\u{00A0}s ").replacingOccurrences(of: " s.", with: "\u{00A0}s."))
                .font(Face.font(12.5, 400, 100, tabular: true)).foregroundStyle(Ink.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var doors: some View {
        VStack(spacing: 0) {
            Ink.rule.frame(height: 1)
            HStack(spacing: 6) {
                Button { openHistory(nil) } label: { Text("History").frame(maxWidth: .infinity) }
                    .buttonStyle(FlapButtonStyle(height: 30))
                Button { openRerun() } label: {
                    HStack(spacing: 6) {
                        BoardIcon.rerun.view(12)
                        Text("Re-run")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(FlapButtonStyle(height: 30))
                .disabled(model.history == nil)
                .help("Open History on your latest take, ready to re-run")
                Button { openSettings() } label: { Text("Settings…").frame(maxWidth: .infinity) }
                    .buttonStyle(FlapButtonStyle(height: 30))
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(FlapButtonStyle(height: 30))
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 6, trailing: 16))
            HStack(spacing: 16) {
                Button { openOnboarding() } label: {
                    Text("Setup guide…").font(Face.small).foregroundStyle(Ink.ink3)
                }
                Button { checkForUpdates() } label: {
                    Text("Check for updates…").font(Face.small).foregroundStyle(Ink.ink3)
                }
                .disabled(!model.canCheckForUpdates)
                .help(model.canCheckForUpdates ? "" : UpdateHint.unsigned)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
    }
}

private struct ModeRow: View {
    let mode: VizierConfig.Mode
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PlatformCode(code: HistoryBoard.platformCode(mode.name))
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.name).font(Face.bodyStrong).foregroundStyle(Ink.enamel)
                    Text(EngineNames.route(mode)).font(Face.small).foregroundStyle(Ink.ink3)
                }
                Spacer(minLength: 4)
                if on { BoundTag(text: AppPreferences.standard.hotkey.legend.uppercased()) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(on || hovering ? Ink.raise : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Ink.rule2 : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityLabel("\(mode.name), \(EngineNames.route(mode))\(on ? ", on \(AppPreferences.standard.hotkey.displayName)" : "")")
    }
}

private struct RecentRow: View {
    let take: TakeRecord
    let code: String
    let copied: Bool
    let open: () -> Void
    let copy: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    ModuleCells(text: HistoryBoard.clock(take.startedAt), cell: CGSize(width: 10, height: 15), font: Face.module, colonWidth: 6)
                        .frame(width: 56, alignment: .leading)
                    Text((take.destination ?? "—").uppercased()).font(Face.row).lineLimit(1).frame(width: 70, alignment: .leading)
                    Text(code).font(Face.row).frame(width: 32, alignment: .leading)
                    Text(take.words.map { $0.formatted() } ?? "—").font(Face.row).frame(width: 44, alignment: .leading)
                    StatusPlate(take.outcome, small: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in History")
            Button(action: copy) {
                (copied ? BoardIcon.check : BoardIcon.copy).view(14)
                    .foregroundStyle(copied ? Ink.enamel : hovering ? Ink.ink2 : Ink.ink3)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(take.bestText == nil)
            .opacity(take.bestText == nil ? 0 : 1)
            .help("Copy the text")
            .accessibilityLabel("Copy the text")
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 3).fill(hovering ? Ink.raise : .clear))
        .onHover { hovering = $0 }
    }
}
