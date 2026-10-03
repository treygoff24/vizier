import Foundation

/// The strip's word row: every word heard so far as a plate, solid once it has settled and a tail
/// plate while it may still turn.
///
/// Gemini's live transcript is one cumulative interim for the whole take and a single final at
/// stop, so "settled" is judged here: an interim word settles once it has held its place through
/// one revision and is not among the last two words, which the recognizer revises most. Finals
/// are always settled. A settled word can still change if the recognizer revises it; its plate
/// then flips to the new text.
public struct WordLine: Equatable, Sendable {
    public struct Plate: Equatable, Sendable {
        public var text: String
        public var settled: Bool

        public init(_ text: String, settled: Bool) {
            self.text = text
            self.settled = settled
        }
    }

    /// Past this many plates the row trims to the newest `trimmedPlates`; the trimmed words have
    /// already slid off the row's left edge.
    public static let maxPlates = 64
    public static let trimmedPlates = 40
    /// Interim words this close to the end stay tail plates.
    public static let turningWords = 2

    public private(set) var plates: [Plate] = []
    private var lastPending: [String] = []
    private var trimmed = 0

    public init() {}

    public mutating func update(settled: String, pending: String) {
        let finals = Self.words(settled)
        let interim = Self.words(pending)
        var line = finals.map { Plate($0, settled: true) }
        for (index, word) in interim.enumerated() {
            let held = index < lastPending.count && lastPending[index] == word
            line.append(Plate(word, settled: held && index < interim.count - Self.turningWords))
        }
        lastPending = interim
        show(line)
    }

    /// The text that will paste: every word settled.
    public mutating func finish(_ text: String) {
        show(Self.words(text).map { Plate($0, settled: true) })
    }

    private mutating func show(_ line: [Plate]) {
        if line.count - trimmed > Self.maxPlates {
            trimmed = line.count - Self.trimmedPlates
        } else if line.count < trimmed {
            trimmed = max(0, line.count - Self.trimmedPlates)
        }
        plates = Array(line.dropFirst(trimmed))
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
