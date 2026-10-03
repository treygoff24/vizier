import Foundation

/// Deletes spoken fillers ("um", "uh") and cut-off word fragments ("w-") from a transcript, and
/// "you know", "I mean", and "like" when commas set them off on both sides ("It was, like, big."),
/// then mends the commas and capitals around each gap. It deletes nothing else and never adds or
/// changes a word, so unlike a model's cleanup it needs no guard: the worst it can do is leave a
/// comma where a person wouldn't have.
public enum FillerFilter {
    /// Never words in English dictation, whatever their punctuation.
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm"]
    /// Fillers that are also real tokens ("10 mm", "Er" as a name), so they go only when set off
    /// by punctuation the way transcribers write a filler: "Mm, pretty good."
    static let punctuatedFillers: Set<String> = ["er", "mm", "mmm"]
    /// Thinking sounds that are also replies ("Mm-hmm, sounds good."). They go only mid-sentence
    /// or trailing off into an ellipsis, where live Scribe writes a pause as "and- Mm-hmm ... works".
    static let hesitations: Set<String> = ["mm-hmm", "mm-hm", "mmhmm", "mhm", "hmm", "hm"]
    /// Two- and three-letter words Scribe writes with a hyphen when the speaker trails off on them
    /// ("desire and- works"). Unless the next word restarts them, they are words, not fragments.
    static let trailedOffWords: Set<String> = [
        "an", "and", "the", "to", "of", "in", "on", "at", "is", "it", "as", "be", "by", "do", "go", "he",
        "me", "my", "no", "so", "up", "us", "we", "or", "if", "but", "for", "not", "you", "all", "can",
        "was", "are", "has", "had", "how", "why", "who", "our", "out", "now", "get", "got", "its", "his",
        "her", "she", "him", "did", "use", "any", "way", "new", "see", "say", "let", "may",
    ]
    /// Words a comma rarely follows. A comma after one of these, right before a filler, was the
    /// transcriber's framing of the filler ("for the, uh, code"), so it goes with the filler.
    static let commalessWords: Set<String> = [
        "a", "an", "the", "to", "for", "of", "in", "on", "at", "with", "from", "into", "about", "and", "or",
        "my", "your", "our", "their", "his", "her", "its", "this", "that", "these", "those", "some", "any",
        "is", "are", "was", "were", "be", "i", "we", "you", "they", "it", "he", "she",
    ]

    /// Phrases that are fillers only between commas ("It was, you know, big"); the same words
    /// anywhere else are speech ("do you know", "what I mean is", "I like it"). Lowercase words.
    static let commaSetOffPhrases: [[String]] = [["you", "know"], ["i", "mean"], ["like"]]

    /// Whether a take in `mode` runs the filter: the mode asks for it and listens for English. The
    /// rules are English only: in German "um" is a word ("um 5 Uhr") and "Ein-" a prefix
    /// ("Ein- und Ausgang"), so a take in any other language skips the filter. A mode that names
    /// no language listens in the system's.
    public static func applies(to mode: VizierConfig.Mode) -> Bool {
        mode.removeFillers == true && isEnglish(mode.transcriber.languages.first ?? AppleSpeechModel.preferredLocale().identifier)
    }

    static func isEnglish(_ language: String) -> Bool {
        Locale(identifier: language).language.languageCode == .english
    }

    public static func apply(to text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { clean(line: String($0)) }.joined(separator: "\n")
    }

    private static func clean(line: String) -> String {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var out: [String] = []
        var capitalizeNext = false
        var skipEllipsis = false
        var skipTokens = 0
        for (index, token) in tokens.enumerated() {
            if skipTokens > 0 { skipTokens -= 1; continue }
            if let length = commaSetOffPhraseLength(tokens, at: index, previous: out.last) {
                skipTokens = length - 1
                let trail = trailingPunctuation(tokens[index + length - 1])
                // "agent, you know, Zorblex." keeps the first comma; "for the, like, code" loses it too.
                if let last = out.indices.last, trail.hasPrefix(","), commalessWords.contains(core(out[last]).lowercased()) {
                    out[last] = stripTrailingCommas(out[last])
                }
                continue
            }
            let next = tokens.indices.contains(index + 1) ? tokens[index + 1] : nil
            let after = tokens.indices.contains(index + 2) ? tokens[index + 2] : nil
            // The loose "..." Scribe writes after a deleted filler ("Mm-hmm ... works") goes with it.
            if skipEllipsis, isEllipsis(token) { skipEllipsis = false; continue }
            skipEllipsis = false
            guard isFiller(token) || isHesitation(token, previous: out.last, next: next)
                    || isFragment(token, next: next, after: after) else {
                let word = trailedOffWord(token, next: next) ?? token
                out.append(capitalizeNext ? capitalized(word) : word)
                capitalizeNext = false
                continue
            }
            skipEllipsis = true
            let atSentenceStart = out.last.map(endsSentence) ?? true
            if atSentenceStart, token.first?.isUppercase == true { capitalizeNext = true }
            let trail = trailingPunctuation(token)
            if let last = out.indices.last {
                if trail.contains("..") || trail.contains("…") {
                    // A trailing-off, not a sentence end: "this. Um... But" -> "this. But"
                } else if let end = trail.last(where: { ".?!".contains($0) }) {
                    // "stuff, uh." -> "stuff."
                    if !endsSentence(out[last]) { out[last] = stripTrailingCommas(out[last]) + String(end) }
                } else if trail.hasPrefix(","), out[last].hasSuffix(","),
                          commalessWords.contains(core(out[last]).lowercased()) {
                    // "for the, uh, code" -> "for the code"
                    out[last] = stripTrailingCommas(out[last])
                }
            }
        }
        return out.joined(separator: " ")
    }

    /// How many tokens of a comma-set-off phrase start at `index`: the phrase's words with no
    /// punctuation but a comma after the last, and a comma after the token before it. Nil when
    /// the words are not set off on both sides.
    static func commaSetOffPhraseLength(_ tokens: [String], at index: Int, previous: String?) -> Int? {
        guard let previous, previous.hasSuffix(",") else { return nil }
        for phrase in commaSetOffPhrases where index + phrase.count <= tokens.count {
            let window = tokens[index..<(index + phrase.count)]
            let wordsMatch = zip(window, phrase).allSatisfy { token, word in
                leadingPunctuation(token).isEmpty && core(token).lowercased() == word
            }
            guard wordsMatch else { continue }
            // Every word but the last carries no punctuation, and the last ends in exactly one comma.
            let insideClean = window.dropLast().allSatisfy { trailingPunctuation($0).isEmpty }
            guard insideClean, trailingPunctuation(window.last!) == "," else { continue }
            return phrase.count
        }
        return nil
    }

    static func isFiller(_ token: String) -> Bool {
        let word = core(token)
        guard !word.isEmpty, leadingPunctuation(token).isEmpty else { return false }
        // All capitals is an acronym ("UM", "ER"), not a sound.
        if word.count > 1, word == word.uppercased() { return false }
        let lower = word.lowercased()
        if fillers.contains(lower) { return true }
        if punctuatedFillers.contains(lower) {
            let trail = trailingPunctuation(token)
            return trail.hasPrefix(",") || trail.contains(where: { ".?!".contains($0) })
        }
        return false
    }

    /// A thinking sound mid-sentence, or trailing off into an ellipsis. At a sentence start with no
    /// ellipsis it is a reply and stays: "Mm-hmm, sounds good."
    static func isHesitation(_ token: String, previous: String?, next: String?) -> Bool {
        guard leadingPunctuation(token).isEmpty, hesitations.contains(core(token).lowercased()) else { return false }
        let trail = trailingPunctuation(token)
        if trail.contains("..") || trail.contains("…") || next.map(isEllipsis) == true { return true }
        guard let previous else { return false }
        return !endsSentence(previous)
    }

    static func isEllipsis(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0 == "." || $0 == "…" } && (token.contains("…") || token.count >= 2)
    }

    /// One to three letters and a hyphen, as transcribers write a word cut off and restarted
    /// ("w- when"). A prefix before "and"/"or" and a hyphenated word is kept: "pre- and post-war".
    /// So is a whole word trailed off on and not restarted ("desire and- works"; see `trailedOffWord`).
    static func isFragment(_ token: String, next: String?, after: String?) -> Bool {
        guard token.hasSuffix("-"), token.count >= 2, token.count <= 4, token.dropLast().allSatisfy(\.isLetter) else { return false }
        if let next, ["and", "or"].contains(next.lowercased()), after?.contains("-") == true { return false }
        return trailedOffWord(token, next: next) == nil
    }

    /// The word itself, without its hyphen, when the token is a whole word the speaker trailed off
    /// on rather than restarted: "and- works" is "and", but "the- the" and "go- going" are restarts.
    static func trailedOffWord(_ token: String, next: String?) -> String? {
        guard token.hasSuffix("-"), token.count >= 3, token.count <= 4 else { return nil }
        let word = String(token.dropLast())
        guard word.allSatisfy(\.isLetter), trailedOffWords.contains(word.lowercased()) else { return nil }
        if let next, core(next).lowercased().hasPrefix(word.lowercased()) { return nil }
        return word
    }

    private static let edgePunctuation = CharacterSet(charactersIn: ",.;:!?\"'“”‘’()[]…")

    private static func core(_ token: String) -> String {
        token.trimmingCharacters(in: edgePunctuation)
    }

    private static func leadingPunctuation(_ token: String) -> String {
        String(token.prefix { $0.unicodeScalars.allSatisfy(edgePunctuation.contains) })
    }

    private static func trailingPunctuation(_ token: String) -> String {
        String(token.reversed().prefix { $0.unicodeScalars.allSatisfy(edgePunctuation.contains) }.reversed())
    }

    private static func endsSentence(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
        return trimmed.last.map { ".?!".contains($0) } ?? false
    }

    private static func stripTrailingCommas(_ token: String) -> String {
        var token = token
        while token.hasSuffix(",") { token.removeLast() }
        return token
    }

    private static func capitalized(_ token: String) -> String {
        guard let first = token.first, first.isLowercase else { return token }
        return first.uppercased() + token.dropFirst()
    }
}
