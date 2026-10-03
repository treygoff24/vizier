import AppKit
import QuartzCore

/// The menu bar status item. Clicking it toggles the popover, which closes itself on a click
/// outside. Opening the popover clears the alert square; a take starting closes the popover.
final class StatusItemController: NSObject {
    enum Phase { case idle, arming, recording, finalizing }

    var phase: Phase = .idle { didSet { if phase != oldValue { phaseChanged() } } }
    var alert = false { didSet { if alert != oldValue { redraw() } } }
    /// Set once history and config exist; until then a click opens nothing.
    var popover: PopoverController?

    private let item = NSStatusBar.system.statusItem(withLength: StatusGlyph.size.width + 6)
    private var fold = 0.0
    private var foldFrom = 0.0, foldTo = 0.0, foldStart: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var appearanceObservation: NSKeyValueObservation?
    private static let foldDuration: CFTimeInterval = 0.150

    override init() {
        super.init()
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(clicked)
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        redraw()
    }

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
