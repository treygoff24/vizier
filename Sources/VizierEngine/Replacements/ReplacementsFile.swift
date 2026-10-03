import Foundation

/// Reads `replacements.txt`: one rule per line, `variant, another variant -> replacement`.
///
/// A line whose first character is `#` is a comment; blank lines are skipped. The line splits at
/// its first `->`, so the replacement may itself contain `->` or commas. Any bad line rejects the
/// whole file, so the caller can keep its last good rules instead of running a partial set.
public enum ReplacementsFile {
    public struct LineError: Error, Equatable, CustomStringConvertible, Sendable {
        public var line: Int
        public var reason: String
        public var description: String { "replacements.txt line \(line): \(reason)" }
    }

    public static func parse(_ text: String) throws(LineError) -> [ReplacementRule] {
        var rules: [ReplacementRule] = []
        var seen: [String: Int] = [:]
        // Split on any newline Character: Swift reads "\r\n" as one Character, so a CRLF file never
        // splits on "\n" alone.
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = index + 1
            if line.first == "#" || line.allSatisfy(\.isWhitespace) { continue }
            guard let arrow = line.range(of: "->") else {
                throw LineError(line: lineNumber, reason: "missing \"->\" between the words and their replacement")
            }
            let replacement = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !replacement.isEmpty else {
                throw LineError(line: lineNumber, reason: "nothing after \"->\"")
            }
            var variants: [String] = []
            for part in line[..<arrow.lowerBound].split(separator: ",") {
                let variant = part.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
                guard !variant.isEmpty else { continue }
                let key = variant.folding(options: [.caseInsensitive], locale: nil)
                if let first = seen[key] {
                    if first == lineNumber { continue }
                    throw LineError(line: lineNumber, reason: "\"\(variant)\" already has a rule on line \(first)")
                }
                seen[key] = lineNumber
                variants.append(variant)
            }
            guard !variants.isEmpty else {
                throw LineError(line: lineNumber, reason: "no words before \"->\"")
            }
            rules.append(ReplacementRule(variants: variants, replacement: replacement))
        }
        return rules
    }
}
