import AppKit

/// The 26×16 menu bar glyph from DESIGN.md: a lamp dot at left, a two-half flap at right, and a
/// Failed Red square knocked out of the flap's lower right after a failed or held take.
struct StatusGlyph: Equatable {
    enum Lamp: Equatable { case off, arming, live }

    var lamp: Lamp = .off
    /// 0 is the open flap; 1 folds the top half to 30% of its height (finalizing).
    var fold: Double = 0
    var alert = false

    static let size = NSSize(width: 26, height: 16)

    /// Draws in the menu bar's foreground for `dark`: white at 0.92 in a dark bar.
    func image(dark: Bool) -> NSImage {
        let glyph = self
        let ink = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
        let image = NSImage(size: Self.size, flipped: true) { _ in
            glyph.draw(ink: ink)
            return true
        }
        image.isTemplate = false
        return image
    }

    func draw(ink: NSColor) {
        switch lamp {
        case .off: break
        case .arming: Board.amber.withAlphaComponent(0.35).setFill()
        case .live: Board.amber.setFill()
        }
        if lamp != .off {
            NSBezierPath(ovalIn: NSRect(x: 4 - 2.6, y: 8 - 2.6, width: 5.2, height: 5.2)).fill()
        }

        ink.setFill()
        // The top half folds toward the split line, as a scaleY about its bottom edge (y 7.5).
        let scale = 1 - 0.7 * min(max(fold, 0), 1)
        let topHeight = 5.9 * scale
        NSBezierPath(roundedRect: NSRect(x: 9.5, y: 7.5 - topHeight, width: 13, height: topHeight),
                     xRadius: 1.4, yRadius: 1.4 * scale).fill()
        NSBezierPath(roundedRect: NSRect(x: 9.5, y: 8.5, width: 13, height: 5.9), xRadius: 1.4, yRadius: 1.4).fill()

        guard alert, let context = NSGraphicsContext.current else { return }
        // The lab strokes the square 1.2px wide in the bar's color; knocking out that ring keeps the
        // same geometry against any menu bar.
        context.saveGraphicsState()
        context.compositingOperation = .clear
        NSBezierPath(roundedRect: NSRect(x: 18.9, y: 9.9, width: 6.2, height: 6.2), xRadius: 1.6, yRadius: 1.6).fill()
        context.restoreGraphicsState()
        Board.failedRed.setFill()
        NSBezierPath(roundedRect: NSRect(x: 20.1, y: 11.1, width: 3.8, height: 3.8), xRadius: 0.4, yRadius: 0.4).fill()
    }
}
