import AppKit
import CoreText

/// Archivo at the design's width and weight. The app bundles the variable font (Resources/Fonts,
/// registered through ATSApplicationFontsPath), so both axes are real.
enum Archivo {
    private static let weightAxis = NSNumber(value: 0x7767_6874)  // 'wght'
    private static let widthAxis = NSNumber(value: 0x7764_7468)  // 'wdth'

    static func font(_ size: CGFloat, weight: CGFloat, width: CGFloat, tabular: Bool = false) -> NSFont {
        var attributes: [NSFontDescriptor.AttributeName: Any] = [
            .family: "Archivo",
            .variation: [weightAxis: NSNumber(value: Double(weight)), widthAxis: NSNumber(value: Double(width))],
        ]
        if tabular {
            attributes[.featureSettings] = [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]
        }
        return NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size)
            ?? .systemFont(ofSize: size, weight: .bold)
    }

    // The type roles the strip uses, from DESIGN.md Typography.
    static let word = font(24, weight: 560, width: 80)
    static let module = font(10.5, weight: 700, width: 72)
    static let statusPlate = font(13, weight: 800, width: 70)
    static let statusSub = font(9.5, weight: 700, width: 75, tabular: true)
    static let remarks = font(13.5, weight: 500, width: 100)
    static let label = font(10, weight: 700, width: 75)
}

/// One line of text laid out once and drawn at an exact baseline. `lineHeight` places it the way
/// CSS does: the font's ascent and descent centered in the line box.
struct BoardText {
    let line: CTLine
    let width: CGFloat
    private let ascent: CGFloat
    private let descent: CGFloat

    /// `tracking` is letter-spacing in em.
    init(_ string: String, font: NSFont, color: NSColor, tracking: CGFloat = 0) {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font,
            .kern: tracking * font.pointSize,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ])
        self.init(line: CTLineCreateWithAttributedString(attributed))
    }

    init(line: CTLine) {
        self.line = line
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        self.ascent = ascent
        self.descent = descent
    }

    /// Draws into a flipped context with the line box's top at `top`.
    func draw(_ context: CGContext, x: CGFloat, top: CGFloat, lineHeight: CGFloat) {
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: top + (lineHeight - ascent - descent) / 2 + ascent)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// A flap's faces: top, bottom, the 1px split at the midline, and the ink on it.
struct FlapTone {
    let top: NSColor
    let bottom: NSColor
    let split: NSColor
    let ink: NSColor

    private static func tone(_ top: UInt32, _ bottom: UInt32, _ split: UInt32, _ ink: NSColor) -> FlapTone {
        FlapTone(top: Board.color(top), bottom: Board.color(bottom), split: Board.color(split), ink: ink)
    }

    static let module = tone(0x222121, 0x1a1a1a, 0x0d0d0d, Board.enamel)
    static var tail: FlapTone { tone(0x1d1d1c, 0x171717, 0x0d0d0d, Board.color(0xeae7e0, alpha: Board.increaseContrast ? 0.78 : 0.5)) }
    // Status plates split at the deeper Plate Split.
    static let plain = tone(0x222121, 0x1a1a1a, 0x0b0b0b, Board.enamel)
    static let slate = tone(0x62727f, 0x56656f, 0x4c5a66, Board.color(0xf3f1ec))
    static let white = tone(0xeeebe4, 0xe4e1d9, 0xd3d0c8, Board.color(0x141414))
    static let red = tone(0xcf1432, 0xbd0f2b, 0xa30d26, Board.color(0xffffff))
    static let gray = tone(0x3a3a38, 0x333331, 0x282827, Board.color(0xb9b5ad))

    /// Paints the flap: top face to the midline less half a point, the split, then the bottom face.
    func paint(_ context: CGContext, _ rect: CGRect, radius: CGFloat) {
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        let mid = rect.midY
        context.setFillColor(top.cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: mid - 0.5 - rect.minY))
        context.setFillColor(split.cgColor)
        context.fill(CGRect(x: rect.minX, y: mid - 0.5, width: rect.width, height: 1))
        context.setFillColor(bottom.cgColor)
        context.fill(CGRect(x: rect.minX, y: mid + 0.5, width: rect.width, height: rect.maxY - mid - 0.5))
        context.restoreGState()
    }
}
