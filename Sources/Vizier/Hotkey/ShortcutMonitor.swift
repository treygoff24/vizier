// Adapted from VoiceInk v2.20 (https://github.com/Beingpax/VoiceInk, tag v2.20):
//   VoiceInk/Features/Shortcuts/Coordination/ShortcutMonitor.swift
// VoiceInk is licensed under the GNU General Public License v3.0.
// Modified 2026-09/10 by Trey Goff.
//
// Kept from upstream: a session event tap at the head of the queue; the locked-screen guard;
// re-enabling the tap when macOS disables it; handing the shortcut to the main queue so the tap
// returns at once.
// Changed for Vizier: one shortcut, a right-hand modifier (Right Command unless the user chose another), which fires the moment the key goes down
// (Right Command is reserved for dictation), so upstream's clean-release
// check, interruption tracking, and pressed-key tracking are gone. Escape goes to a handler that may
// swallow it; a typed Cmd+V is only reported, and always passes.

import AppKit
import Carbon.HIToolbox
import VizierEngine
import os

final class ShortcutMonitor {
    enum EscapeEvent {
        case down(isRepeat: Bool)
        case up
    }

    private var hotkey = RightModifierKey()
    /// The modifier that starts and stops a take. Changing it forgets the old key's state.
    var modifier: HotkeyModifier {
        get { hotkey.modifier }
        set { hotkey = RightModifierKey(newValue) }
    }
    private var onPress: ((_ pressedAt: TimeInterval) -> Void)?
    private var onEscape: ((EscapeEvent, TimeInterval) -> Bool)?
    private var onPaste: ((TimeInterval) -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let log = Logger(subsystem: "net.praxient.dictum", category: "hotkey")

    var isInstalled: Bool { eventTap != nil }

    /// Installs the tap. Returns false when macOS refuses it, which means Accessibility
    /// ("Device Control and Data Access") is not granted yet.
    /// `onEscape` runs inside the tap and must answer at once: true swallows the event.
    /// `onPaste` hears each typed Cmd+V press inside the tap and cannot block it.
    func start(
        onPress: @escaping (_ pressedAt: TimeInterval) -> Void,
        onEscape: @escaping (EscapeEvent, TimeInterval) -> Bool,
        onPaste: @escaping (TimeInterval) -> Void
    ) -> Bool {
        stop()
        self.onPress = onPress
        self.onEscape = onEscape
        self.onPaste = onPaste
        return installEventTap()
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        resetState()
        onPress = nil
        onEscape = nil
        onPaste = nil
    }

    private func installEventTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // The run loop source lives on the main run loop, so the tap is called on the main thread.
            let swallow = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("event tap refused; Accessibility is not granted")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            log.error("event tap run loop source failed")
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.notice("event tap installed")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.notice("event tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public); re-enabling")
            resetState()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            if keyCode == UInt16(kVK_Escape), let onEscape, UserSessionInputPolicy.allowsShortcutHandling {
                return onEscape(.down(isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0), now)
            }
            if keyCode == UInt16(kVK_ANSI_V), event.flags.contains(.maskCommand), !Self.isViziersOwn(event),
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0, let onPaste {
                onPaste(now)
            }
        case .keyUp:
            if keyCode == UInt16(kVK_Escape), let onEscape {
                return onEscape(.up, now)
            }
        case .flagsChanged:
            if hotkey.isPress(keyCode: keyCode, flags: event.flags.rawValue), UserSessionInputPolicy.allowsShortcutHandling {
                DispatchQueue.main.async { [onPress] in onPress?(now) }
            }
        default:
            break
        }
        return false
    }

    private static func isViziersOwn(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == Paster.eventTag
    }

    private func resetState() {
        hotkey.reset()
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown, .keyUp, .flagsChanged,
    ].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
}
