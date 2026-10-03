import Foundation

/// Edits one top-level string value in `vizier.jsonc` and leaves every other byte alone. The file
/// is hand-edited JSON with comments (JSON5 as far as Foundation reads it), and people and scripts
/// keep notes in it, so decoding the whole file and encoding it back would throw those away.
///
/// The scanner knows just enough JSON5 to find the key: line and block comments, double- and
/// single-quoted strings with backslash escapes, unquoted identifier keys, and brace depth. It
/// finds the key only at depth 1, so `modes[].transcriber.mode` is never mistaken for `mode`, and
/// a `mode` inside a comment or a string value is text, not a key. A key written with an escape
/// in it (`"mode"`) is not recognized; nobody writes keys that way.
enum SettingsEditor {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case missingKey(String)
        case duplicateKey(String)
        case valueNotAString(String)
        case unterminated(String)

        var description: String {
            switch self {
            case .missingKey(let key): "no top-level \"\(key)\" key"
            case .duplicateKey(let key): "more than one top-level \"\(key)\" key"
            case .valueNotAString(let key): "the top-level \"\(key)\" value is not a string"
            case .unterminated(let what): "unterminated \(what)"
            }
        }
    }

    /// The text with the top-level `key`'s string value replaced by `value`, quoted and escaped.
    static func replacingTopLevelString(named key: String, with value: String, in text: String) throws(Failure) -> String {
        let bytes = Array(text.utf8)
        let range = try topLevelStringValue(named: key, in: bytes)
        var out = Array(bytes[..<range.lowerBound])
        out.append(contentsOf: Array(quoted(value).utf8))
        out.append(contentsOf: bytes[range.upperBound...])
        return String(decoding: out, as: UTF8.self)
    }

    /// The byte range, quotes included, of the string value of the one top-level `key`.
    static func topLevelStringValue(named key: String, in bytes: [UInt8]) throws(Failure) -> Range<Int> {
        let wanted = Array(key.utf8)
        var scanner = Scanner(bytes: bytes)
        var found: Range<Int>?
        while let token = try scanner.next() {
            guard scanner.depth == 1, token.content == wanted else { continue }
            // A key is a name followed by a colon; a name followed by anything else is a value.
            var ahead = scanner
            guard let colon = try ahead.next(), colon == .punctuation(UInt8(ascii: ":")) else { continue }
            guard let valueToken = try ahead.next(), case .string(let range, _) = valueToken else {
                throw .valueNotAString(key)
            }
            guard found == nil else { throw .duplicateKey(key) }
            found = range
            scanner = ahead
        }
        guard let found else { throw .missingKey(key) }
        return found
    }

    /// `value` as a JSON string literal.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    enum Token: Equatable {
        /// An unquoted identifier, as its bytes. JSON5 lets a key be written this way.
        case name([UInt8])
        /// A quoted string: the byte range of the whole literal, quotes included, and the raw
        /// bytes between the quotes.
        case string(Range<Int>, [UInt8])
        case punctuation(UInt8)

        /// What a key comparison sees: the identifier, or the string's content.
        var content: [UInt8]? {
            switch self {
            case .name(let bytes), .string(_, let bytes): bytes
            case .punctuation: nil
            }
        }
    }

    /// Walks the bytes one token at a time, skipping whitespace and comments and tracking depth.
    struct Scanner {
        let bytes: [UInt8]
        var index = 0
        private(set) var depth = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func next() throws(Failure) -> Token? {
            try skipTrivia()
            guard index < bytes.count else { return nil }
            let c = bytes[index]
            switch c {
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                let start = index
                try skipString(quote: c)
                return .string(start..<index, Array(bytes[(start + 1)..<(index - 1)]))
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                index += 1
                return .punctuation(c)
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                index += 1
                return .punctuation(c)
            case _ where Self.isIdentifier(c):
                let start = index
                while index < bytes.count, Self.isIdentifier(bytes[index]) || bytes[index].isDigit { index += 1 }
                return .name(Array(bytes[start..<index]))
            default:
                index += 1
                return .punctuation(c)
            }
        }

        private mutating func skipTrivia() throws(Failure) {
            while index < bytes.count {
                let c = bytes[index]
                if c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\n") || c == UInt8(ascii: "\r") {
                    index += 1
                } else if c == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                    while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
                } else if c == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
                    index += 2
                    while true {
                        guard index + 1 < bytes.count else { throw .unterminated("comment") }
                        if bytes[index] == UInt8(ascii: "*"), bytes[index + 1] == UInt8(ascii: "/") { index += 2; break }
                        index += 1
                    }
                } else {
                    return
                }
            }
        }

        private mutating func skipString(quote: UInt8) throws(Failure) {
            index += 1
            while index < bytes.count {
                let c = bytes[index]
                if c == UInt8(ascii: "\\") { index += 2; continue }
                index += 1
                if c == quote { return }
            }
            throw .unterminated("string")
        }

        private static func isIdentifier(_ c: UInt8) -> Bool {
            (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
                || c == UInt8(ascii: "_") || c == UInt8(ascii: "$")
        }
    }
}

private extension UInt8 {
    var isDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
}
