import Foundation

/// Turns a finished transcript into the text the speaker meant to type: fillers out, punctuation
/// and paragraphs in, every other word kept.
public protocol TextCleaner: Sendable {
    func clean(_ transcript: String) async throws -> String
}

/// Runs a cleanup pass that can never cost a take. A cleanup that fails, runs past its time, or
/// returns text too far from the transcript's length leaves the raw transcript standing, with the
/// reason.
public enum TextCleanup {
    public enum Result: Equatable, Sendable {
        case cleaned(String)
        case raw(Fallback)
    }

    /// Why the raw transcript stood.
    public enum Fallback: Equatable, Sendable, CustomStringConvertible {
        case timedOut
        case failed(String)
        /// The cleaned text lost too many words, so something real was probably dropped.
        case tooShort(raw: Int, cleaned: Int)
        /// The cleaned text gained words, so the model probably answered or added something.
        case tooLong(raw: Int, cleaned: Int)

        public var description: String {
            switch self {
            case .timedOut: "timed out"
            case .failed(let reason): "failed: \(reason)"
            case .tooShort(let raw, let cleaned): "\(cleaned) words back from \(raw), too few"
            case .tooLong(let raw, let cleaned): "\(cleaned) words back from \(raw), too many"
            }
        }

        /// What a public log may say: a fixed category, an HTTP status, or word counts. `failed`
        /// carries the provider's own message, which can echo the transcript, so it stays out.
        public var publicSummary: String {
            guard case .failed(let reason) = self else { return description }
            guard reason.hasPrefix("HTTP ") else { return "failed" }
            let digits = reason.dropFirst(5).prefix { $0.isNumber }
            return digits.isEmpty ? "failed" : "failed: HTTP \(digits)"
        }
    }

    /// Below this many words a take is too short for a ratio to mean much ("Um, yes." to "Yes."
    /// halves it), so only an empty result counts as too short.
    public static let ratioFloorWords = 12
    /// On nine test takes Flash-Lite and Flash kept 0.79 to 1.0 of the transcript's
    /// words. Fillers and self-corrections account for the loss; 0.6 leaves room for a take thick
    /// with them.
    public static let minKeptRatio = 0.6
    /// Cleanup never adds words, apart from a number spelled out or a contraction opened up.
    public static let maxGrowthRatio = 1.25
    public static let growthSlackWords = 4

    public static func run(_ transcript: String, cleaner: any TextCleaner, timeout: Duration) async -> Result {
        let cleaned: String
        do {
            cleaned = try await withThrowingTaskGroup { group in
                group.addTask { try await cleaner.clean(transcript) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CleanupError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch CleanupError.timedOut {
            return .raw(.timedOut)
        } catch {
            return .raw(.failed(String(describing: error)))
        }
        if let problem = check(cleaned: cleaned, raw: transcript) { return .raw(problem) }
        return .cleaned(cleaned)
    }

    /// Nil when the cleaned text is a plausible cleanup of the raw transcript.
    public static func check(cleaned: String, raw: String) -> Fallback? {
        let rawWords = wordCount(raw)
        let cleanedWords = wordCount(cleaned)
        if rawWords > 0, cleanedWords == 0 { return .tooShort(raw: rawWords, cleaned: cleanedWords) }
        if rawWords >= ratioFloorWords, Double(cleanedWords) < Double(rawWords) * minKeptRatio {
            return .tooShort(raw: rawWords, cleaned: cleanedWords)
        }
        if Double(cleanedWords) > Double(rawWords) * maxGrowthRatio + Double(growthSlackWords) {
            return .tooLong(raw: rawWords, cleaned: cleanedWords)
        }
        return nil
    }

    /// Whitespace-separated tokens holding at least one letter or digit, so punctuation and
    /// ellipses are not words.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count { $0.contains { $0.isLetter || $0.isNumber } }
    }
}

public enum CleanupError: Error, Equatable, Sendable, CustomStringConvertible {
    case timedOut
    case http(status: Int, message: String)
    /// Gemini refused the prompt; the reason is its block reason.
    case blocked(String)
    /// The answer stopped for a reason other than finishing (a token limit or a safety stop).
    case unfinished(String)

    public var description: String {
        switch self {
        case .timedOut: "timed out"
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .blocked(let reason): "prompt blocked: \(reason)"
        case .unfinished(let reason): "stopped early: \(reason)"
        }
    }
}
