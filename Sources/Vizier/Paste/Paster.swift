// Adapted from VoiceInk v2.20 (https://github.com/Beingpax/VoiceInk, tag v2.20):
//   VoiceInk/Infrastructure/SystemIntegration/Paste/CursorPaster.swift
//   VoiceInk/Infrastructure/SystemIntegration/Paste/ClipboardManager.swift
// VoiceInk is licensed under the GNU General Public License v3.0.
// Modified 2026-09/10 by Trey Goff.
//
// Kept from upstream: the clipboard write tagged with org.nspasteboard.source, the 0.10 s pause
// before pasting, and Cmd+V as key codes 0x37 and 0x09 from a private event source posted at the
// HID tap with 10 ms between events. Changed for Vizier: the text stays on the clipboard (no
// restore), and AppleScript is chosen automatically when the current layout doesn't put V on key
// code 9 under Command, instead of by a setting. Removed: auto-learn, auto-send, and the
// transient and session pasteboard types.

import AppKit
import Carbon
import VizierEngine
import os

enum Paster {
    enum Outcome: CustomStringConvertible {
        case keystroke
        case appleScript
        case withdrawn
        case held(String)
        case failed(String)

        var description: String {
            switch self {
            case .keystroke: "keystroke"
            case .appleScript: "AppleScript"
            case .withdrawn: "withdrawn before the paste"
            case .held(let reason): "held: \(reason)"
            case .failed(let reason): "failed: \(reason)"
            }
        }

        /// A fixed code for the public log. The held and failed reasons can name the app that had
        /// focus or carry an AppleScript error, so they stay out of it.
        var logCode: String {
            switch self {
            case .keystroke: "keystroke"
            case .appleScript: "applescript"
            case .withdrawn: "withdrawn"
            case .held(let reason):
                switch reason {
                case PasteDecision.vizierHadFocus: "held-vizier-focus"
                case PasteDecision.focusMoved: "held-focus-moved"
                case PasteDecision.secureField: "held-secure-field"
                case PasteDecision.secureInput: "held-secure-input"
                case PasteDecision.clipboardChanged: "held-clipboard-changed"
                default: "held-no-target"
                }
            case .failed: failedForAccessibility ? "failed-accessibility" : "failed"
            }
        }

        var failedForAccessibility: Bool {
            if case .failed(let reason) = self { return reason == Paster.accessibilityMissing }
            return false
        }
    }

    /// The failure when Vizier lacks Accessibility access, which it needs to post Cmd+V.
    static let accessibilityMissing = "Accessibility is not granted"
    /// The failure when the text could not be put on the clipboard at all.
    static let clipboardWriteFailed = "could not write the clipboard"
    static let prePasteDelay: Duration = .milliseconds(100)
    static let keyEventGap: Duration = .milliseconds(10)
    /// Marks Vizier's own Cmd+V events, so the event tap never mistakes them for a typed Cmd+V.
    static let eventTag: Int64 = 0x4449_4354
    private static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    /// A hung app cannot stall the paste past this; a timed-out focus query holds the take.
    private static let focusQueryTimeout: Float = 0.3
    private static let log = Logger(subsystem: "net.praxient.dictum", category: "paste")

    struct Dependencies {
        let pasteboard: NSPasteboard
        let checkTarget: (ContinuousClock.Instant, pid_t?) -> PasteDecision
        let finalCheck: (pid_t?) -> PasteDecision
        let hasAccessibility: () -> Bool
        let prepareShortcut: () -> Shortcut

        static var system: Self {
            Self(pasteboard: .general, checkTarget: Paster.checkTarget, finalCheck: Paster.finalCheck,
                 hasAccessibility: AXIsProcessTrusted, prepareShortcut: Paster.prepareShortcut)
        }
    }

    enum Shortcut {
        case commandV((CommandVEvent) -> Void)
        case appleScript
        case unavailable
    }

    enum CommandVEvent { case commandDown, vDown, vUp, commandUp }

    /// Puts `text` on the clipboard, where it stays, and pastes it into the focused app. The
    /// paste is the only keystroke Vizier sends. The focus check runs inside the pause, so it adds
    /// no time on the common path. `stillWanted` is checked after the pause, so an Escape in that
    /// window stops the paste (the text is already on the clipboard).
    static func paste(_ text: String, appAtStop: pid_t?, using dependencies: Dependencies = .system,
                      stillWanted: () -> Bool) async -> Outcome {
        let pasteboard = dependencies.pasteboard
        guard let written = setClipboard(text, on: pasteboard) else { return .failed(clipboardWriteFailed) }
        func clipboardIsOurs() -> Bool { pasteboard.changeCount == written }
        let changed = Outcome.held(PasteDecision.clipboardChanged)
        let clock = ContinuousClock()
        let checkStarted = clock.now
        let decision = dependencies.checkTarget(checkStarted, appAtStop)
        let remaining = prePasteDelay - (clock.now - checkStarted)
        if remaining > .zero { try? await Task.sleep(for: remaining) }
        guard stillWanted() else { return .withdrawn }
        guard clipboardIsOurs() else { return changed }
        guard dependencies.hasAccessibility() else { return .failed(accessibilityMissing) }
        if case .hold(let reason) = decision { return .held(reason) }
        // The user can switch apps, or move into a password field, during the pause too, so look
        // once more right before the keystroke.
        let final = dependencies.finalCheck(appAtStop)
        guard clipboardIsOurs() else { return changed }
        if case .hold(let reason) = final {
            log.notice("paste held: \(Outcome.held(reason).logCode, privacy: .public), seen just before the keystroke")
            return .held(reason)
        }
        switch dependencies.prepareShortcut() {
        case .commandV(let post): return await postCommandV(post, clipboardIsOurs: clipboardIsOurs)
        case .appleScript: return pasteWithAppleScript(clipboardIsOurs: clipboardIsOurs)
        case .unavailable: return .failed("could not create the Cmd+V events")
        }
    }

    /// The pid, focused-element subrole, and secure event input, read again just before the
    /// keystroke. Only the subrole is asked for, to keep the extra time small.
    private static func finalCheck(appAtStop: pid_t?) -> PasteDecision {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var focus: PasteTargetFacts.FocusQuery?
        if let pid, pid != ProcessInfo.processInfo.processIdentifier {
            focus = focusQuery(AXUIElementCreateApplication(pid), role: false)
        }
        return PasteDecision.finalCheck(frontmostPID: pid, pidAtStop: appAtStop, focus: focus, secureEventInput: IsSecureEventInputEnabled())
    }

    /// The app's focused element, with its subrole (to spot a password field) and, when `role`,
    /// its role.
    private static func focusQuery(_ element: AXUIElement, role wantRole: Bool) -> PasteTargetFacts.FocusQuery {
        AXUIElementSetMessagingTimeout(element, focusQueryTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value)
        switch error {
        case .success where value != nil && CFGetTypeID(value) == AXUIElementGetTypeID():
            var role: CFTypeRef?
            var subrole: CFTypeRef?
            let focused = value as! AXUIElement
            AXUIElementSetMessagingTimeout(focused, focusQueryTimeout)
            if wantRole { _ = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role) }
            _ = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
            return .element(role: role as? String, subrole: subrole as? String)
        case .success, .noValue: return .noValue
        default: return .error(error.rawValue)
        }
    }

    /// Asks the frontmost app (not the system-wide element, which answers cannot-complete from
    /// some terminals) for its focused element. Only when that fails does it also count the app's
    /// windows, since each cross-process query costs tens of milliseconds.
    private static func checkTarget(started: ContinuousClock.Instant, appAtStop: pid_t?) -> PasteDecision {
        let app = NSWorkspace.shared.frontmostApplication
        var focus = PasteTargetFacts.FocusQuery.noValue
        var windowCount: Int?
        // Vizier answers accessibility queries on its main thread, so asking itself could only
        // time out; the decision holds on the bundle id alone.
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            focus = focusQuery(element, role: true)
            if case .element = focus {} else {
                var windows: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success {
                    windowCount = (windows as? [AXUIElement])?.count
                }
            }
        }
        let decision = PasteDecision.decide(PasteTargetFacts(
            frontmostApp: app != nil, bundleID: app?.bundleIdentifier, focus: focus,
            isRegularApp: app?.activationPolicy == .regular, windowCount: windowCount,
            frontmostPID: app?.processIdentifier, pidAtStop: appAtStop, secureEventInput: IsSecureEventInputEnabled()))
        let elapsed = ContinuousClock().now - started
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let bundle = app?.bundleIdentifier ?? "none"
        switch (decision, focus) {
        case (.paste, .element(let role, _)):
            log.notice("paste target \(bundle, privacy: .private) focused role \(role ?? "unknown", privacy: .public), checked in \(ms, privacy: .public) ms")
        case (.paste, _):
            log.notice("paste target \(bundle, privacy: .private) focused role none (\(windowCount.map(String.init) ?? "unknown", privacy: .public) windows), checked in \(ms, privacy: .public) ms")
        case (.hold(let reason), _):
            // A held reason can name the app; the public log gets its fixed code.
            log.notice("paste held: \(Outcome.held(reason).logCode, privacy: .public) (\(reason, privacy: .private)), checked in \(ms, privacy: .public) ms")
        }
        return decision
    }

    private static func setClipboard(_ text: String, on pasteboard: NSPasteboard) -> Int? {
        let written = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return nil }
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            pasteboard.setString(bundleIdentifier, forType: sourceType)
        }
        guard pasteboard.string(forType: .string) == text, pasteboard.changeCount == written else { return nil }
        return written
    }

    /// True when key code 9 with Command types "v" in the current layout: QWERTY, and the
    /// "– QWERTY ⌘" layouts that switch to QWERTY while Command is held. Dvorak and Colemak put
    /// another character there, so Cmd plus key code 9 would not paste.
    private static func keyCodeNineIsCommandV() -> Bool {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return true }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout, 9, UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr else { return true }
        return String(utf16CodeUnits: characters, count: length).lowercased() == "v"
    }

    private static func prepareShortcut() -> Shortcut {
        guard keyCodeNineIsCommandV() else { return .appleScript }
        let source = CGEventSource(stateID: .privateState)
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else { return .unavailable }
        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        for event in [commandDown, vDown, vUp, commandUp] {
            event.setIntegerValueField(.eventSourceUserData, value: eventTag)
        }
        return .commandV { key in
            let event = switch key {
            case .commandDown: commandDown
            case .vDown: vDown
            case .vUp: vUp
            case .commandUp: commandUp
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private static func postCommandV(_ post: (CommandVEvent) -> Void, clipboardIsOurs: () -> Bool) async -> Outcome {
        guard clipboardIsOurs() else { return .held(PasteDecision.clipboardChanged) }
        post(.commandDown)
        defer { post(.commandUp) }
        try? await Task.sleep(for: keyEventGap)
        guard clipboardIsOurs() else { return .held(PasteDecision.clipboardChanged) }
        post(.vDown)
        try? await Task.sleep(for: keyEventGap)
        post(.vUp)
        try? await Task.sleep(for: keyEventGap)
        return .keystroke
    }

    /// System Events resolves "v" through the current layout, which key code 9 does not.
    private static func pasteWithAppleScript(clipboardIsOurs: () -> Bool) -> Outcome {
        guard let script = NSAppleScript(source: #"tell application "System Events" to keystroke "v" using command down"#)
        else { return .failed("could not create the AppleScript paste") }
        guard clipboardIsOurs() else { return .held(PasteDecision.clipboardChanged) }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            // The error text can quote other apps' state; it goes to the private log only.
            let number = error[NSAppleScript.errorNumber] as? Int
            log.error("AppleScript paste failed (\(number.map(String.init) ?? "no number", privacy: .public)): \(error[NSAppleScript.errorMessage] as? String ?? String(describing: error), privacy: .private)")
            return .failed("AppleScript paste failed")
        }
        return .appleScript
    }
}
