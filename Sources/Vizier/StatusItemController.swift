import AppKit
import QuartzCore

/// The menu bar status item. Built with the macOS 27 SDK and running on macOS 27, the popover opens
/// through the expanded interface, which lets the item take part in menu bar keyboard navigation and
/// menu tracking. Otherwise the button's action toggles it, and it closes itself on a click
/// outside. Opening the popover clears the alert square; a take starting closes the popover.
final class StatusItemController: NSObject {
    enum Phase { case idle, arming, recording, finalizing }

    var phase: Phase = .idle { didSet { if phase != oldValue { phaseChanged() } } }
    var alert = false { didSet { if alert != oldValue { redraw() } } }
    /// Set once history and config exist; until then a click opens nothing.
    var popover: PopoverController? {
        didSet {
            #if canImport(AppKit, _version: 2775)
            if #available(macOS 27, *) {
                popover?.onDismiss = { [weak self] in self?.item.expandedInterfaceSession?.cancel() }
                return
            }
            #endif
            // The expanded interface kept the button lit while the popover was open; a plain
            // status button lights only during the press, so this does it by hand.
            popover?.onDismiss = { [weak self] in self?.item.button?.highlight(false) }
        }
    }

    private let item = NSStatusBar.system.statusItem(withLength: StatusGlyph.size.width + 6)
    private var fold = 0.0
    private var foldFrom = 0.0, foldTo = 0.0, foldStart: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var appearanceObservation: NSKeyValueObservation?
    private static let foldDuration: CFTimeInterval = 0.150

    override init() {
        super.init()
        item.button?.imagePosition = .imageOnly
        if !useExpandedInterface() {
            item.button?.target = self
            item.button?.action = #selector(clicked)
        }
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        redraw()
    }

    /// Hands the item to the expanded interface when it can be used: compiled against the macOS 27
    /// SDK (AppKit 2775 is that SDK's; the 26 SDK lacks the API, so a Command Line Tools 26 build
    /// takes the button path everywhere) and running on macOS 27. Returns whether it did.
    private func useExpandedInterface() -> Bool {
        #if canImport(AppKit, _version: 2775)
        if #available(macOS 27, *) {
            item.expandedInterfaceDelegate = self
            return true
        }
        #endif
        return false
    }

    /// The button action, used when the expanded interface is not. `anchorWindow` is set here and
    /// nowhere else, so under the expanded interface the popover's outside-click monitor exempts
    /// nothing and behaves as that interface expects.
    @objc private func clicked() {
        let wasLit = alert
        alert = false
        guard let popover, phase == .idle, let button = item.button, let window = button.window else { return }
        if popover.isShown {
            popover.dismiss()
            return
        }
        popover.anchorWindow = window
        popover.show(under: window.convertToScreen(button.convert(button.bounds, to: nil)), alertWasLit: wasLit)
        button.highlight(true)
    }

    private func phaseChanged() {
        // A take is starting: the popover can take key, so it must not be up when the paste comes.
        if phase != .idle, popover?.isShown == true { popover?.dismiss() }
        let target = phase == .finalizing ? 1.0 : 0.0
        if target != foldTo || displayLink == nil { animateFold(to: target) }
        redraw()
    }

    private func animateFold(to target: Double) {
        displayLink?.invalidate()
        displayLink = nil
        foldTo = target
        guard !Board.reduceMotion, fold != target, let button = item.button else {
            fold = target
            return
        }
        foldFrom = fold
        foldStart = CACurrentMediaTime()
        let link = button.displayLink(target: self, selector: #selector(stepFold(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func stepFold(_ link: CADisplayLink) {
        let progress = min((CACurrentMediaTime() - foldStart) / Self.foldDuration, 1)
        fold = foldFrom + (foldTo - foldFrom) * Board.ease(progress)
        if progress >= 1 {
            link.invalidate()
            displayLink = nil
        }
        redraw()
    }

    private func redraw() {
        guard let button = item.button else { return }
        let lamp: StatusGlyph.Lamp = switch phase {
        case .recording: .live
        case .arming: .arming
        case .idle, .finalizing: .off
        }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = StatusGlyph(lamp: lamp, fold: fold, alert: alert).image(dark: dark)
        let label = switch phase {
        case .recording: "Vizier, recording"
        case .finalizing: "Vizier, finishing"
        case .idle, .arming: alert ? "Vizier, last take needs attention" : "Vizier, ready"
        }
        button.setAccessibilityLabel(label)
    }
}

#if canImport(AppKit, _version: 2775)
@available(macOS 27, *)
extension StatusItemController: NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        let wasLit = alert
        alert = false
        guard let popover, phase == .idle, let button = item.button, let window = button.window else {
            expandedInterfaceSession.cancel()
            return
        }
        popover.show(under: window.convertToScreen(button.convert(button.bounds, to: nil)), alertWasLit: wasLit)
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        popover?.close()
    }
}
#endif
