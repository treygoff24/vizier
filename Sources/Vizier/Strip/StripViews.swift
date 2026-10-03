import AppKit
import VizierEngine

/// Everything the strip shows, set by `StripController`.
struct StripState {
    struct Status {
        var text: String
        var tone: FlapTone
        var sub: String
    }

    /// Up to 8 characters, uppercase.
    var destination = ""
    /// Captured audio as m:ss.
    var seconds = 0
    /// The mode's two-letter platform code.
    var platform = ""
    var words: [WordLine.Plate] = []
    /// 0.55 while the words are frozen by a lost stream, 0.35 once a take is cancelled.
    var wordAlpha: CGFloat = 1
    /// Nil keeps the status column's space empty.
    var status: Status?
}

/// DESIGN.md Layout, "The strip": one 62pt row, 14pt gutters, fixed columns, words take the rest.
enum StripMetrics {
    static let height: CGFloat = 62
    static let padLeft: CGFloat = 14
    static let padRight: CGFloat = 12
    static let gutter: CGFloat = 14
    static let lamp: CGFloat = 20
    static let meta: CGFloat = 103
    static let statusMin: CGFloat = 112
    static let wordsX = padLeft + lamp + gutter + meta + gutter  // 165
    static let radius: CGFloat = 10
    static let lampCenter = CGPoint(x: padLeft + lamp / 2, y: height / 2)

    static func width(on screen: NSScreen) -> CGFloat { min(880, screen.frame.width - 96) }
}

/// A floating board's fill, outline, and drop shadows: the strip's (Strip shadow) or the remarks
/// line's (Remarks shadow). Unflipped, so layer shadows fall down.
final class StripBoardView: NSView {
    enum Style { case strip, remarks }

    private let style: Style
    private let face = CALayer()

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(face)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        restyle()
    }

    /// The view is 1pt larger than the strip on every side; that point is the outline ring.
    func restyle() {
        guard let layer else { return }
        let contrast = Board.increaseContrast
        let strip = bounds.insetBy(dx: 1, dy: 1)
        layer.cornerRadius = StripMetrics.radius + 1
        layer.backgroundColor = contrast ? Board.color(0x8a8680).cgColor : NSColor(white: 1, alpha: 0.06).cgColor
        layer.shadowPath = CGPath(roundedRect: strip, cornerWidth: StripMetrics.radius, cornerHeight: StripMetrics.radius, transform: nil)
        layer.shadowColor = NSColor.black.cgColor
        // A CSS blur radius is twice a layer's shadowRadius.
        layer.shadowOpacity = style == .strip ? 0.55 : 0.45
        layer.shadowRadius = style == .strip ? 18 : 11
        layer.shadowOffset = CGSize(width: 0, height: style == .strip ? -14 : -8)
        face.frame = strip
        face.cornerRadius = StripMetrics.radius
        face.backgroundColor = Board.board.cgColor
        face.shadowPath = CGPath(roundedRect: face.bounds, cornerWidth: StripMetrics.radius, cornerHeight: StripMetrics.radius, transform: nil)
        face.shadowColor = NSColor.black.cgColor
        face.shadowOpacity = contrast || style == .remarks ? 0 : 0.4
        face.shadowRadius = 4
        face.shadowOffset = CGSize(width: 0, height: -3)
    }
}

/// The strip's contents except the lamp: destination, timer, platform, words, and status.
final class StripView: NSView {
    var state = StripState() { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawHighlight(context)
        drawMeta(context)
        let statusLeft = drawStatus(context)
        drawWords(context, from: StripMetrics.wordsX, to: statusLeft - StripMetrics.gutter)
    }

    /// The inset 1pt highlight along the top edge (dropped under Increase Contrast).
    private func drawHighlight(_ context: CGContext) {
        guard !Board.increaseContrast else { return }
        let r = StripMetrics.radius
        context.saveGState()
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil))
        context.addPath(CGPath(roundedRect: bounds.offsetBy(dx: 0, dy: 1), cornerWidth: r, cornerHeight: r, transform: nil))
        context.setFillColor(NSColor(white: 1, alpha: 0.04).cgColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    private func drawMeta(_ context: CGContext) {
        let left = StripMetrics.padLeft + StripMetrics.lamp + StripMetrics.gutter
        let top = (StripMetrics.height - 35) / 2
        drawArrow(context, x: left, y: top + 2)
        drawModules(context, Array(state.destination.prefix(8)), count: 8, x: left + 16, y: top, ink: Board.enamel)
        let clock = "\(state.seconds / 60):" + String(format: "%02d", state.seconds % 60)
        let padded = String(repeating: " ", count: max(0, 5 - clock.count)) + clock
        drawModules(context, Array(padded.suffix(5)), count: 5, x: left + 16, y: top + 20, ink: Board.enamel)
        drawModules(context, Array(state.platform.prefix(2)), count: 2, x: left + 16 + 54 + 8, y: top + 20, ink: Board.ink2)
    }

    /// The 16-unit arrow icon at 11pt: a 1.5-unit stroke with round caps and joins.
    private func drawArrow(_ context: CGContext, x: CGFloat, y: CGFloat) {
        let scale: CGFloat = 11 / 16
        func p(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: x + u * scale, y: y + v * scale) }
        context.saveGState()
        context.setStrokeColor(Board.ink2.cgColor)
        context.setLineWidth(1.5 * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: p(2.5, 8)); context.addLine(to: p(13, 8))
        context.move(to: p(9.5, 4.5)); context.addLine(to: p(13, 8)); context.addLine(to: p(9.5, 11.5))
        context.strokePath()
        context.restoreGState()
    }

    /// Character modules: fixed 10×15 cells 1pt apart, one uppercase character each.
    private func drawModules(_ context: CGContext, _ characters: [Character], count: Int, x: CGFloat, y: CGFloat, ink: NSColor) {
        for index in 0..<count {
            let cell = CGRect(x: x + CGFloat(index) * 11, y: y, width: 10, height: 15)
            FlapTone.module.paint(context, cell, radius: 2)
            guard index < characters.count, characters[index] != " " else { continue }
            let text = BoardText(String(characters[index]).uppercased(), font: Archivo.module, color: ink)
            text.draw(context, x: cell.minX + (10 - text.width) / 2, top: cell.minY, lineHeight: 15)
        }
    }

    /// The status plate over its sub line, right-aligned. Returns the column's left edge. An empty
    /// status keeps its space so the words never shift when one arrives.
    private func drawStatus(_ context: CGContext) -> CGFloat {
        let right = bounds.width - StripMetrics.padRight
        let top = (StripMetrics.height - 38) / 2
        var width = StripMetrics.statusMin
        guard let status = state.status else { return right - width }
        let text = BoardText(status.text, font: Archivo.statusPlate, color: status.tone.ink, tracking: 0.08)
        let plate = CGRect(x: right - text.width - 16, y: top, width: text.width + 16, height: 24)
        status.tone.paint(context, plate, radius: 3)
        text.draw(context, x: plate.minX + 8, top: plate.minY, lineHeight: 24)
        width = max(width, plate.width)
        if !status.sub.isEmpty {
            let sub = BoardText(status.sub, font: Archivo.statusSub, color: Board.ink3, tracking: 0.12)
            sub.draw(context, x: right - sub.width, top: top + 27, lineHeight: 11)
            width = max(width, sub.width)
        }
        return right - width
    }

    /// Word plates 36pt tall and 4pt apart. When they overflow, the newest stay in view and the
    /// row's left edge fades from clear at 10pt to solid at 48pt.
    private func drawWords(_ context: CGContext, from left: CGFloat, to right: CGFloat) {
        guard !state.words.isEmpty, right > left else { return }
        let texts = state.words.map { plate in
            (plate, BoardText(plate.text, font: Archivo.word, color: (plate.settled ? FlapTone.module : FlapTone.tail).ink, tracking: 0.005))
        }
        let total = texts.reduce(0) { $0 + $1.1.width + 14 + 4 }
        let rowWidth = right - left
        let overflow = max(0, total - rowWidth)
        let row = CGRect(x: left, y: (StripMetrics.height - 40) / 2, width: rowWidth, height: 40)

        context.saveGState()
        context.clip(to: row)
        context.setAlpha(state.wordAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        var x = left - overflow
        for (plate, text) in texts {
            let width = text.width + 14
            if x + width >= left {
                let rect = CGRect(x: x, y: row.minY + 2, width: width, height: 36)
                (plate.settled ? FlapTone.module : FlapTone.tail).paint(context, rect, radius: 3)
                text.draw(context, x: rect.minX + 7, top: rect.minY, lineHeight: 36)
            }
            x += width + 4
        }
        if overflow > 0 {
            context.setBlendMode(.destinationIn)
            let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [NSColor.clear.cgColor, NSColor.black.cgColor] as CFArray, locations: [0, 1])!
            context.clip(to: CGRect(x: left, y: row.minY, width: 48, height: row.height))
            context.drawLinearGradient(fade, start: CGPoint(x: left + 10, y: 0), end: CGPoint(x: left + 48, y: 0), options: [.drawsBeforeStartLocation])
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// The lamp: dark glass in a bezel, lit amber from the real buffer level while samples flow.
final class LampView: NSView {
    /// The lamp's level, 0...1, or nil when the mic is not live.
    var level: Double? { didSet { if level != oldValue { needsDisplay = true } } }
    /// The strip's board in this view's coordinates. The glow lights the board and stops at its edge.
    var board: CGRect = .null { didSet { needsDisplay = true } }

    static let margin: CGFloat = 40
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let lamp = CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        // Lamp Bezel: a 3pt #0d0d0d socket.
        context.setFillColor(Board.color(0x0d0d0d).cgColor)
        context.fillEllipse(in: lamp.insetBy(dx: -3, dy: -3))
        radial(context, lamp, colors: [0x2b261c, 0x1c1812, 0x0e0c08], stop: 0.6, space: space)
        // The socket's 1pt inset shadow on the glass. The light washes over it as the level rises.
        context.setStrokeColor(NSColor(white: 0, alpha: 0.6).cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: lamp.insetBy(dx: 0.5, dy: 0.5))

        if let level {
            let lv = CGFloat(level)
            // Lamp Glow: amber at 0.3 + 0.55·level over the socket, spread 3·level, casting a blur of
            // 4 + 26·level onto the board under the plates and stopping at the board's edge.
            context.saveGState()
            if !board.isNull {
                context.addPath(CGPath(roundedRect: board, cornerWidth: StripMetrics.radius, cornerHeight: StripMetrics.radius, transform: nil))
                context.clip()
            }
            context.setShadow(offset: .zero, blur: 4 + 26 * lv, color: Board.color(0xffb000).cgColor)
            context.setFillColor(Board.color(0xffb000, alpha: 0.3 + 0.55 * lv).cgColor)
            context.fillEllipse(in: lamp.insetBy(dx: -3 * lv, dy: -3 * lv))
            context.restoreGState()

            context.saveGState()
            context.setAlpha(0.55 + 0.45 * lv)
            radial(context, lamp, colors: [0xffe3a3, 0xffb000, 0xc98500], stop: 0.55, space: space)
            context.restoreGState()
        }
    }

    /// radial-gradient(circle at 42% 38%, a, b stop, c), sized to the farthest corner.
    private func radial(_ context: CGContext, _ rect: CGRect, colors: [UInt32], stop: CGFloat, space: CGColorSpace) {
        let center = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.38)
        let radius = hypot(rect.maxX - center.x, rect.maxY - center.y)
        let gradient = CGGradient(colorsSpace: space, colors: colors.map { Board.color($0).cgColor } as CFArray, locations: [0, stop, 1])!
        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
        context.restoreGState()
    }
}

/// The remarks line's text: the label where the lamp and destination sit and the reason starting
/// at the same x as the words. A `StripBoardView` behind it paints the board.
final class RemarksView: NSView {
    private(set) var lines: [BoardText] = []
    private let label = BoardText("REMARKS", font: Archivo.label, color: Board.ink3, tracking: 0.12)
    static let lineHeight: CGFloat = (13.5 * 1.35).rounded(.up)

    override var isFlipped: Bool { true }

    /// Sets the reason and returns the height the line needs at `width`.
    @discardableResult
    func set(_ remark: String, width: CGFloat) -> CGFloat {
        let attributed = NSAttributedString(string: remark, attributes: [
            .font: Archivo.remarks,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Board.enamel.cgColor,
        ])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let available = Double(width - 14 - 12 - 137 - 14)
        var start = 0
        lines = []
        while start < attributed.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, available))
            lines.append(BoardText(line: CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))))
            start += count
        }
        needsDisplay = true
        return 16 + CGFloat(max(lines.count, 1)) * Self.lineHeight
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        label.draw(context, x: 14, top: 8, lineHeight: Self.lineHeight)
        for (index, line) in lines.enumerated() {
            line.draw(context, x: StripMetrics.wordsX, top: 8 + CGFloat(index) * Self.lineHeight, lineHeight: Self.lineHeight)
        }
    }
}
