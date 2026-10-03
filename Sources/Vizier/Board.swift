import AppKit

/// Departures tokens from DESIGN.md that the Swift surfaces use.
enum Board {
    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
    }

    /// Mic-Live Amber: lit only while real samples are flowing.
    static let amber = color(0xffb000)
    /// Failed Red: the status item's alert square.
    static let failedRed = color(0xc8102e)

    /// The board ease, cubic-bezier(.2, .7, .2, 1).
    static func ease(_ progress: Double) -> Double { boardCurve.y(atX: progress) }
    private static let boardCurve = UnitBezier(0.2, 0.7, 0.2, 1)

    static let board = color(0x141414)
    static let enamel = color(0xeae7e0)
    /// Faded and Dim Enamel, brighter under Increase Contrast.
    static var ink2: NSColor { color(increaseContrast ? 0xcfcbc2 : 0xa9a59c) }
    static var ink3: NSColor { color(increaseContrast ? 0xaaa59c : 0x7a766e) }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}

/// A CSS cubic-bezier timing curve from (0,0) to (1,1).
struct UnitBezier {
    private let ax, bx, cx, ay, by, cy: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1; bx = 3 * (x2 - x1) - cx; ax = 1 - cx - bx
        cy = 3 * y1; by = 3 * (y2 - y1) - cy; ay = 1 - cy - by
    }

    func y(atX x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return sample(ay, by, cy, solveT(x))
    }

    private func sample(_ a: Double, _ b: Double, _ c: Double, _ t: Double) -> Double { ((a * t + b) * t + c) * t }

    private func solveT(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let error = sample(ax, bx, cx, t) - x
            if abs(error) < 1e-6 { return t }
            let slope = (3 * ax * t + 2 * bx) * t + cx
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var (lo, hi) = (0.0, 1.0)
        t = x
        while hi - lo > 1e-7 {
            let value = sample(ax, bx, cx, t)
            if abs(value - x) < 1e-6 { return t }
            if value < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return t
    }
}
