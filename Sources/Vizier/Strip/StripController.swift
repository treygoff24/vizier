import AppKit
import VizierEngine
import QuartzCore

/// The recording indicator: a borderless panel low on the display with the cursor that never takes
/// focus or the pointer. TakeController tells it what happened; it owns the timing that follows
/// (lamp level, timer, DELAYED, linger, exit).
final class StripController {
    enum Outcome: Equatable {
        case pasted, rerouted(Route), held, failed, cancelled

        /// What a RE-ROUTED take took instead of the usual path: batch for a live final that never
        /// came, the raw transcript for a cleanup pass that didn't hold.
        enum Route { case batch, rawText }

        var status: StripState.Status {
            switch self {
            case .pasted: .init(text: "PASTED", tone: .plain, sub: "")
            case .rerouted(.batch): .init(text: "RE-ROUTED", tone: .slate, sub: "VIA BATCH")
            case .rerouted(.rawText): .init(text: "RE-ROUTED", tone: .slate, sub: "RAW TEXT")
            case .held: .init(text: "HELD", tone: .white, sub: "")
            case .failed: .init(text: "FAILED", tone: .red, sub: "")
            case .cancelled: .init(text: "CANCELLED", tone: .gray, sub: "")
            }
        }

        /// How long the outcome stays on the board before the strip leaves. A pasted or cancelled
        /// take is over, so the strip gets out of the way; the others hold long
        /// enough to read their remarks.
        var linger: TimeInterval {
            switch self {
            case .pasted: 0.2
            case .rerouted: 1.7
            case .held: 2.4
            case .failed: 2.8
            case .cancelled: 0.25
            }
        }
    }

    private enum Phase { case hidden, recording, finalizing, outcome }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    // Room around the boards for their shadows and the lamp's glow, and above the strip for up to
    // three lines of remarks.
    private static let side: CGFloat = 48
    private static let below: CGFloat = 64
    private static let above: CGFloat = 32
    private static let remarksRoom: CGFloat = 3 + 16 + 3 * RemarksView.lineHeight

    private let panel: Panel
    private let stripBoard = StripBoardView(style: .strip)
    private let stripView = StripView()
    private let lampView = LampView()
    private let remarksBoard = StripBoardView(style: .remarks)
    private let remarksView = RemarksView()

    private var phase = Phase.hidden
    private var generation = 0
    private var level: () -> Float = { 0 }
    private var seconds: () -> Double = { 0 }
    private var meter = LevelMeter()
    private var live = false
    private var streamLost = false
    private var batch = false
    private var stoppedAt: CFTimeInterval = 0
    /// How long finalizing may take before the flap reads DELAYED.
    private var onTime: CFTimeInterval = 1
    private var lastFrame: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var width: CGFloat = 0

    /// Builds the panel at launch so the first take shows in one frame.
    init() {
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.setAccessibilityElement(false)
        let content = NSView()
        content.wantsLayer = true
        for view in [remarksBoard, remarksView, stripBoard, lampView, stripView] { content.addSubview(view) }
        panel.contentView = content
    }

    // MARK: Events from the take

    func begin(destination: String, platform: String, level: @escaping () -> Float, seconds: @escaping () -> Double) {
        generation += 1
        self.level = level
        self.seconds = seconds
        meter.reset()
        live = false
        streamLost = false
        batch = false
        phase = .recording
        stripView.state = StripState(destination: destination.uppercased(), platform: platform)
        lampView.level = nil
        setRemarks(nil)
        // A zero-length animation, so a new take supersedes an exit still fading the last one.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
            if let frame = place() { panel.animator().setFrame(frame, display: false) }
        }
        panel.orderFrontRegardless()
        startFrames()
        announce("Recording to \(destination)")
    }

    /// Real samples are flowing: the lamp follows their level from here.
    func setLive() {
        guard phase == .recording else { return }
        live = true
    }

    func setWords(_ plates: [WordLine.Plate]) {
        guard phase != .hidden, phase != .outcome else { return }
        stripView.state.words = plates
    }

    func streamLost(remark: String) {
        guard phase == .recording else { return }
        streamLost = true
        stripView.state.wordAlpha = 0.55
        stripView.state.status = .init(text: "NO LIVE TEXT", tone: .slate, sub: "STILL RECORDING")
        setRemarks(remark)
    }

    /// The stop tap: the mic is off, so the lamp goes dark, and the finalizing clock starts.
    /// `onTime` is how long the take's path normally needs; DELAYED shows only past it.
    func stopped(onTime: TimeInterval) {
        guard phase == .recording else { return }
        phase = .finalizing
        self.onTime = onTime
        live = false
        lampView.level = nil
        stoppedAt = CACurrentMediaTime()
        if !streamLost { stripView.state.status = nil }
        setRemarks(nil)
    }

    func reroutingToBatch() {
        guard phase == .finalizing else { return }
        batch = true
        updateFinalizing(at: CACurrentMediaTime())
    }

    func finish(_ outcome: Outcome, remark: String?) {
        guard phase != .hidden else { return }
        phase = .outcome
        live = false
        lampView.level = nil
        switch outcome {
        // The words now show the text that went out, so they come back to full ink.
        case .pasted, .rerouted, .held: stripView.state.wordAlpha = 1
        case .cancelled: stripView.state.wordAlpha = 0.35
        case .failed: break
        }
        stripView.state.status = outcome.status
        let shown = outcome == .pasted || outcome == .cancelled ? nil : remark
        setRemarks(shown)
        stopFrames()
        announce([outcome.status.text, shown].compactMap(\.self).joined(separator: ". "))
        let generation = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(outcome.linger))
            self?.leave(generation)
        }
    }

    // MARK: Frames

    private func startFrames() {
        guard displayLink == nil, let view = panel.contentView else { return }
        lastFrame = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopFrames() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = now - lastFrame
        lastFrame = now
        if live { lampView.level = meter.step(meanSquare: level(), seconds: dt) }
        let captured = Int(seconds())
        if stripView.state.seconds != captured { stripView.state.seconds = captured }
        if phase == .finalizing { updateFinalizing(at: now) }
    }

    /// DESIGN.md Finalizing: nothing while the final is on time; past its on-time window, DELAYED
    /// over the real elapsed time in half-second steps; a batch pass on time reads BATCH over
    /// SAVED AUDIO.
    private func updateFinalizing(at now: CFTimeInterval) {
        let elapsed = now - stoppedAt
        var status = stripView.state.status
        if elapsed > onTime {
            let steps = (elapsed * 2).rounded(.down) / 2
            status = .init(text: "DELAYED", tone: .plain, sub: String(format: "+%.1f S", steps) + (batch ? " · BATCH" : ""))
        } else if batch {
            status = .init(text: "BATCH", tone: .slate, sub: "SAVED AUDIO")
        }
        if status?.text != stripView.state.status?.text || status?.sub != stripView.state.status?.sub {
            stripView.state.status = status
        }
    }

    // MARK: Layout and exit

    /// Low and centered on the display with the cursor: the strip's bottom edge at 11% of the
    /// display's height. The remarks line grows upward from it; nothing moves the strip.
    /// Lays out the boards and returns the panel's frame.
    private func place() -> NSRect? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return nil }
        width = StripMetrics.width(on: screen)
        let size = NSSize(width: width + 2 * Self.side, height: Self.below + StripMetrics.height + Self.remarksRoom + Self.above)
        let stripBottom = screen.frame.minY + (screen.frame.height * 0.11).rounded()
        let origin = NSPoint(x: (screen.frame.midX - size.width / 2).rounded(), y: stripBottom - Self.below)

        let strip = NSRect(x: Self.side, y: Self.below, width: width, height: StripMetrics.height)
        stripBoard.frame = strip.insetBy(dx: -1, dy: -1)
        stripView.frame = strip
        let lamp = StripMetrics.lamp + 2 * LampView.margin
        lampView.frame = NSRect(
            x: strip.minX + StripMetrics.lampCenter.x - lamp / 2, y: strip.midY - lamp / 2, width: lamp, height: lamp)
        lampView.board = lampView.convert(strip, from: lampView.superview)
        stripBoard.restyle()
        remarksBoard.restyle()
        return NSRect(origin: origin, size: size)
    }

    private func setRemarks(_ remark: String?) {
        guard let remark, !remark.isEmpty else {
            remarksBoard.isHidden = true
            remarksView.isHidden = true
            return
        }
        let height = remarksView.set(remark, width: width)
        let frame = NSRect(x: Self.side, y: Self.below + StripMetrics.height + 3, width: width, height: height)
        remarksView.frame = frame
        remarksBoard.frame = frame.insetBy(dx: -1, dy: -1)
        remarksBoard.restyle()
        remarksBoard.isHidden = false
        remarksView.isHidden = false
    }

    /// Fades and drops 6pt over 160 ms on the board ease, or simply goes under Reduce Motion.
    private func leave(_ generation: Int) {
        guard generation == self.generation, phase == .outcome else { return }
        phase = .hidden
        guard !Board.reduceMotion else {
            panel.orderOut(nil)
            return
        }
        let start = panel.frame.origin
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(NSPoint(x: start.x, y: start.y - 6))
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
