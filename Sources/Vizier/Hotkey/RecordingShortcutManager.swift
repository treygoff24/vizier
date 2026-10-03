// Adapted from VoiceInk v2.20 (https://github.com/Beingpax/VoiceInk, tag v2.20):
//   VoiceInk/Features/Shortcuts/Coordination/RecordingShortcutManager.swift
//   (RecordingShortcutModeHandler)
// VoiceInk is licensed under the GNU General Public License v3.0.
// Modified 2026-09/10 by Trey Goff.
//
// Reduced to toggle only: a press of the chosen right-hand modifier starts or stops a take. Kept from upstream:
// the 0.5 s cooldown between presses, and ignoring the shortcut while a take is finishing.
// Added for Vizier: the Escape gate, and retrying the tap until Accessibility is granted.

import AppKit
import ApplicationServices
import VizierEngine
import os

final class RecordingShortcutManager {
    private let monitor = ShortcutMonitor()
    private let takes: TakeController
    private var escapeGate = EscapeGate()
    private var lastShortcutPressTime: TimeInterval?
    private let shortcutPressCooldown: TimeInterval = 0.5
    private var retryTimer: Timer?
    private let log = Logger(subsystem: "net.praxient.dictum", category: "hotkey")

    init(takes: TakeController) {
        self.takes = takes
    }

    /// The modifier that starts and stops a take; takes effect at once.
    var hotkey: HotkeyModifier {
        get { monitor.modifier }
        set { monitor.modifier = newValue }
    }

    /// `promptForAccessibility` is false while onboarding is up: its Accessibility step asks at the
    /// right moment, with an explanation, and the retry timer below picks the grant up either way.
    func start(promptForAccessibility: Bool = true) {
        if install() { return }
        // Ask once; macOS shows its own prompt pointing at System Settings. Then keep trying so the
        // grant takes effect without relaunching.
        if promptForAccessibility {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryInstall() }
        }
    }

    private func retryInstall() {
        guard install() else { return }
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func install() -> Bool {
        monitor.start(
            onPress: { [weak self] pressedAt in self?.handlePress(at: pressedAt) },
            onEscape: { [weak self] event, time in self?.handleEscape(event, at: time) ?? false },
            onPaste: { [weak self] time in self?.handlePaste(at: time) }
        )
    }

    private func handlePress(at pressedAt: TimeInterval) {
        if let last = lastShortcutPressTime, pressedAt - last < shortcutPressCooldown {
            log.debug("tap ignored: inside the press cooldown")
            return
        }
        guard takes.acceptsToggle else {
            log.notice("tap ignored: a take is finishing")
            return
        }
        lastShortcutPressTime = pressedAt
        takes.toggle(at: pressedAt)
    }

    /// A typed Cmd+V near a take's own paste. Logs every one within a few seconds of a stop, so a
    /// second copy of a take with a typed Cmd+V in the log came from the keyboard or another app's
    /// synthetic press, and one without points at the target app.
    private func handlePaste(at time: TimeInterval) {
        if let note = takes.pasteWatch.note(at: time) {
            log.notice("\(note, privacy: .public)")
        }
    }

    private func handleEscape(_ event: ShortcutMonitor.EscapeEvent, at time: TimeInterval) -> Bool {
        let decision: EscapeGate.Decision = switch event {
        case .down(let isRepeat): escapeGate.keyDown(at: time, isRepeat: isRepeat, takeIsCancelable: takes.isCancelable)
        case .up: escapeGate.keyUp()
        }
        switch decision {
        case .pass: return false
        case .swallow: return true
        case .swallowAndCancel:
            DispatchQueue.main.async { [takes] in takes.cancel() }
            return true
        }
    }
}
