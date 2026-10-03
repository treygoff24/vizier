// Adapted from VoiceInk v2.20 (https://github.com/Beingpax/VoiceInk, tag v2.20):
//   VoiceInk/Features/Dictionary/Workflows/WordReplacementService.swift
//   VoiceInk/Features/Dictionary/Workflows/WordReplacementVariants.swift
// VoiceInk is licensed under the GNU General Public License v3.0.
// Modified 2026-09/10 by Trey Goff.
//
// Kept from upstream: comma-separated variants, NFC normalization, case-insensitive matching,
// Unicode-aware word boundaries, and plain substring matching for scripts written without spaces.
// Changed for Vizier: all variants match in one left-to-right pass, so a replacement's output is
// never matched again by another rule, and replacement text is inserted literally rather than
// read as a regex template (upstream let "$1" or a backslash in a replacement misbehave).

import Foundation

/// One line of `replacements.txt`: every variant on the left becomes `replacement`.
public struct ReplacementRule: Equatable, Sendable {
    public var variants: [String]
    public var replacement: String

    public init(variants: [String], replacement: String) {
        self.variants = variants
        self.replacement = replacement
    }
}

/// Applies replacement rules to finished text. Deterministic: the same rules and text always give
/// the same output, independent of rule order in the file except where noted on `init`.
public struct WordReplacer: Sendable {
    private let regex: NSRegularExpression?
    /// Replacement for each capture group, in group order (group 1 is index 0).
    private let replacements: [String]

    /// Builds the matcher. At any position the longest variant wins; variants of equal length keep
    /// file order. Matching proceeds left to right and never re-reads replaced text.
    public init(rules: [ReplacementRule]) throws {
        var alternatives: [(variant: String, replacement: String, order: Int)] = []
        for rule in rules {
            for variant in rule.variants {
                alternatives.append((variant.precomposedStringWithCanonicalMapping, rule.replacement, alternatives.count))
            }
        }
        alternatives.sort {
            let (l, r) = ($0.variant.count, $1.variant.count)
            return l != r ? l > r : $0.order < $1.order
        }
        guard !alternatives.isEmpty else {
            regex = nil
            replacements = []
            return
        }
        let pattern = alternatives
            .map { "(" + Self.pattern(for: $0.variant) + ")" }
            .joined(separator: "|")
        regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        replacements = alternatives.map(\.replacement)
    }

    public func apply(to text: String) -> String {
        guard let regex else { return text }
        let source = text.precomposedStringWithCanonicalMapping as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
            guard let group = (1...replacements.count).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += replacements[group - 1]
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }

    // A letter, mark, or digit outside the scripts written without spaces. A variant may not touch
    // one on either side, so "cat" never matches inside "concatenate" but does match "cat,".
    private static let wordChar =
        "[[\\p{L}\\p{M}\\p{N}]-[\\p{scx=Han}\\p{scx=Hiragana}\\p{scx=Katakana}\\p{scx=Hangul}\\p{scx=Thai}]]"

    private static func pattern(for variant: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: variant)
        guard usesWordBoundaries(variant) else { return escaped }
        return "(?<!\(wordChar))\(escaped)(?!\(wordChar))"
    }

    /// False for text in scripts written without spaces (CJK, Thai), which match as substrings.
    private static func usesWordBoundaries(_ text: String) -> Bool {
        let nonSpaced: [ClosedRange<UInt32>] = [
            0x3040...0x309F,  // Hiragana
            0x30A0...0x30FF,  // Katakana
            0x4E00...0x9FFF,  // CJK Unified Ideographs
            0xAC00...0xD7AF,  // Hangul Syllables
            0x0E00...0x0E7F,  // Thai
        ]
        return !text.unicodeScalars.contains { s in nonSpaced.contains { $0.contains(s.value) } }
    }
}
