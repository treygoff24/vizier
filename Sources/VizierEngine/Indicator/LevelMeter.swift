import Foundation

/// The lamp's level: the buffer's mean square in dB, mapped from -62 dB (dark) to -22 dB (full),
/// rising with a 24 ms time constant and falling with 150 ms. Full sits at -22 dB because real
/// dictation into a USB condenser mic ran at a median near -31 dB and a 90th percentile near
/// -23 dB; the design lab's -10 dB left the lamp short of full on every take.
public struct LevelMeter: Equatable, Sendable {
    public static let floorDB = -62.0
    public static let rangeDB = 40.0
    public static let attack = 0.024
    public static let release = 0.150

    public private(set) var level = 0.0

    public init() {}

    /// Where the level is heading for a buffer with this mean square (samples in -1...1).
    public static func target(meanSquare: Float) -> Double {
        let db = 10 * log10(Double(meanSquare) + 1e-12)
        return min(max((db - floorDB) / rangeDB, 0), 1)
    }

    /// Moves the level toward the buffer's target over `seconds` of display time.
    @discardableResult
    public mutating func step(meanSquare: Float, seconds: Double) -> Double {
        let target = Self.target(meanSquare: meanSquare)
        let constant = target > level ? Self.attack : Self.release
        level += (target - level) * (1 - exp(-max(seconds, 0) / constant))
        return level
    }

    public mutating func reset() {
        level = 0
    }
}
