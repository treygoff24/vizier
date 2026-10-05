import Foundation
import VizierEngine

/// A way to paste: a clipboard writer and the key sender that goes with it.
public struct PasteRoute: Sendable {
    public var writer: any ClipboardWriter
    public var sender: any KeySender

    public init(writer: any ClipboardWriter, sender: any KeySender) {
        self.writer = writer
        self.sender = sender
    }
}

/// The usable clipboard writers and key senders of a session, chosen independently: a desktop with
/// a working clipboard writer but no working sender still gets the text published (the user can
/// paste it), and a failed writer does not take the sender that would have followed it along.
public struct PastePlan: Sendable {
    public var writers: [any ClipboardWriter]
    public var senders: [any KeySender]

    public init(writers: [any ClipboardWriter], senders: [any KeySender]) {
        self.writers = writers
        self.senders = senders
    }

    /// True when nothing at all can be done: no way to publish.
    public var isEmpty: Bool { writers.isEmpty }
}

public enum DesktopRoutes {
    /// The adapters this session can use, each probed: a tool that is installed but that the
    /// session cannot use (wtype on GNOME) is not in the list (A16: never choose by "installed").
    /// `ydotool` is the default on COSMIC; elsewhere it is an opt-in fallback and comes last. Writers and senders are probed and
    /// kept independently of each other. COSMIC retains its sender for late socket recovery.
    public static func make(session: DesktopSession, env: HelperEnvironment = HelperEnvironment(), allowYdotool: Bool = false) async -> PastePlan {
        var writers: [any ClipboardWriter] = []
        var senders: [any KeySender] = []
        switch session.display {
        case .x11:
            writers = X11ClipboardWriter.allInstalled(env: env)
            if writers.isEmpty { writers = [X11ClipboardWriter(tool: .xclip, env: env)] }  // so doctor can report it missing
            senders = [XdotoolKeySender(env: env)]
        case .wayland:
            writers = [WlCopyClipboardWriter(session: session, env: env)]
            senders = session.family == .cosmic
                ? [CosmicKeySender(env: env)] : [WtypeKeySender(session: session, env: env)]
        case .none:
            return PastePlan(writers: [], senders: [])
        }
        if allowYdotool && !(session.display == .wayland && session.family == .cosmic) { senders.append(YdotoolKeySender(env: env)) }
        var usableWriters: [any ClipboardWriter] = []
        for writer in writers where await writer.probe().available { usableWriters.append(writer) }
        var usableSenders: [any KeySender] = []
        for sender in senders {
            let keepForRecovery = session.display == .wayland && session.family == .cosmic
            let available = await sender.probe().available
            if keepForRecovery || available {
                usableSenders.append(sender)
            }
        }
        return PastePlan(writers: usableWriters, senders: usableSenders)
    }

    /// Every adapter's probe for `vizier doctor`, usable or not.
    public static func probes(session: DesktopSession, env: HelperEnvironment = HelperEnvironment()) async -> [AdapterProbe] {
        var result: [AdapterProbe] = []
        switch session.display {
        case .x11:
            for tool in [X11ClipboardWriter.Tool.xclip, .xsel] { result.append(await X11ClipboardWriter(tool: tool, env: env).probe()) }
            result.append(await XdotoolKeySender(env: env).probe())
        case .wayland:
            result.append(await WlCopyClipboardWriter(session: session, env: env).probe())
            result.append(await WtypeKeySender(session: session, env: env).probe())
        case .none: break
        }
        result.append(await YdotoolKeySender(env: env).probe())
        return result
    }
}

/// Pastes on Linux: publishes the text to the clipboard, then sends the paste chord.
///
/// - The clipboard is published first, trying each writer in order (each writer proves its
///   publication by reading the selection back); if every writer fails the outcome is `.failed`
///   with `onClipboard` false and nothing is sent. With no usable sender the text is still
///   published and the outcome is `.failed` with `onClipboard` true.
/// - The chord is Ctrl+Shift+V when the focused app is known to be a terminal, else Ctrl+V.
/// - Immediately before the chord the clipboard is read back again; if it no longer holds the text
///   (another app took the selection during the pause) nothing is sent and `onClipboard` is false.
/// - A sender that cannot start permits the next sender to be tried. A helper that started
///   and failed reports uncertain delivery; no other sender is tried (A16).
/// - `stillWanted` is read right before the keystroke; false means `.withdrawn`, with the text
///   left on the clipboard.
///
/// Weaker than macOS: there is no secure-field or secure-input check (Linux has no general
/// equivalent), and the focused app is known on X11, sway, Hyprland and COSMIC (COSMIC supplies no PID). The one check kept is
/// the focus move: when the pid was known at the stop and is known and different now, the paste
/// is held (`PasteDecision.focusMoved`). If either pid is unknown, the paste goes ahead.
@MainActor
public final class LinuxPaster: PasteService {
    private let writers: [any ClipboardWriter]
    private let senders: [any KeySender]
    private let focus: FocusReader
    private let prePasteDelay: Duration

    /// `prePasteDelay` gives a clipboard server a moment to take the selection before the chord.
    public init(plan: PastePlan, focus: FocusReader, prePasteDelay: Duration = .milliseconds(100)) {
        self.writers = plan.writers
        self.senders = plan.senders
        self.focus = focus
        self.prePasteDelay = prePasteDelay
    }

    /// Writers and senders from paired routes, each distinct name kept once, in order.
    public convenience init(routes: [PasteRoute], focus: FocusReader, prePasteDelay: Duration = .milliseconds(100)) {
        var writers: [any ClipboardWriter] = [], senders: [any KeySender] = []
        for route in routes {
            if !writers.contains(where: { $0.name == route.writer.name }) { writers.append(route.writer) }
            if !senders.contains(where: { $0.name == route.sender.name }) { senders.append(route.sender) }
        }
        self.init(plan: PastePlan(writers: writers, senders: senders), focus: focus, prePasteDelay: prePasteDelay)
    }

    public func paste(_ text: String, focusAtStop: Int32?, stillWanted: @escaping @MainActor () -> Bool) async -> PasteOutcome {
        // 1. Publish. A writer that failed is not asked again.
        var published: (any ClipboardWriter)?
        var failures: [String] = []
        for writer in writers {
            do {
                try await writer.publish(text)
                published = writer
                break
            } catch {
                failures.append("\(writer.name): \(error)")
            }
        }
        guard let published else {
            let why = writers.isEmpty ? "no clipboard writer is usable on this desktop" : "could not write the clipboard (\(failures.joined(separator: "; ")))"
            return PasteOutcome(kind: .failed, method: "", reason: why, onClipboard: false, permissionMissing: false, logCode: "failed-clipboard")
        }
        guard !senders.isEmpty else {
            return PasteOutcome(kind: .failed, method: "", reason: "no key sender is usable on this desktop; the text is on the clipboard", onClipboard: true, permissionMissing: false, logCode: "failed-no-sender")
        }

        // 2. The pause, then the focus checks as close to the keystroke as they can be.
        try? await Task.sleep(for: prePasteDelay)
        let window = await focus.focusedWindow()
        if let before = focusAtStop, let now = window?.pid, before != now {
            return PasteOutcome(kind: .held, method: "", reason: PasteDecision.focusMoved, onClipboard: true, permissionMissing: false, logCode: "held-focus-moved")
        }
        guard stillWanted() else {
            return PasteOutcome(kind: .withdrawn, method: "", reason: nil, onClipboard: true, permissionMissing: false, logCode: "withdrawn")
        }

        // 3. The text must still be what the chord will paste: read the selection back last.
        if let readable = published as? any ClipboardReadable {
            let now = await readable.readBack(maxBytes: text.utf8.count + 16)
            guard now == text else {
                return PasteOutcome(kind: .failed, method: "", reason: "the clipboard changed before the paste key was sent", onClipboard: false, permissionMissing: false, logCode: "failed-clipboard-replaced")
            }
        }

        // 4. Send. Only a sender that could not start is replaced.
        let chord: PasteChord = window?.isTerminal == true ? .ctrlShiftV : .ctrlV
        var sendFailures: [String] = []
        for sender in senders {
            do {
                try await sender.send(chord)
                return PasteOutcome(kind: .pasted, method: sender.name, reason: nil, onClipboard: true, permissionMissing: false, logCode: sender.name)
            } catch let error as KeyDeliveryError {
                return PasteOutcome(kind: .failed, method: sender.name, reason: error.description, onClipboard: true, permissionMissing: false, logCode: "failed-key-helper")
            } catch {
                sendFailures.append("\(sender.name): \(error)")
            }
        }
        return PasteOutcome(kind: .failed, method: "", reason: "could not send the paste key (\(sendFailures.joined(separator: "; ")))", onClipboard: true, permissionMissing: false, logCode: "failed")
    }
}
