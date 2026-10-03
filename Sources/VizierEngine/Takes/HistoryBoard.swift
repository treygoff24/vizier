import Foundation

/// The History window's three views: every take, the takes that went wrong, and cancels.
public enum HistoryFilter: String, CaseIterable, Sendable {
    case all, problems, cancelled

    /// The outcomes the view shows; nil is every outcome. Takes still in flight count as neither
    /// a problem nor a cancel.
    public var outcomes: Set<TakeOutcome>? {
        switch self {
        case .all: nil
        case .problems: [.rerouted, .held, .failed]
        case .cancelled: [.cancelled]
        }
    }
}

/// One day on the History board: a heading and that day's takes, newest first.
public struct TakeDay: Sendable, Equatable {
    public let start: Date
    public let label: String
    public let takes: [TakeRecord]
}

public enum HistoryBoard {
    /// Groups newest-first takes by local calendar day, keeping their order. Today and yesterday
    /// are named; older days read like "Friday, Sep 25".
    public static func days(_ takes: [TakeRecord], calendar: Calendar = .current, now: Date = .now) -> [TakeDay] {
        var result: [TakeDay] = []
        var current: [TakeRecord] = []
        var currentStart: Date?
        func close() {
            guard let start = currentStart, !current.isEmpty else { return }
            result.append(TakeDay(start: start, label: dayLabel(start, calendar: calendar, now: now), takes: current))
        }
        for take in takes {
            let start = calendar.startOfDay(for: take.startedAt)
            if start != currentStart {
                close()
                current = []
                currentStart = start
            }
            current.append(take)
        }
        close()
        return result
    }

    public static func dayLabel(_ day: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        let format = Date.FormatStyle(date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.abbreviated).day()
        return day.formatted(format)
    }

    /// "14:03", the board's 24-hour posted time.
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "0:21" or "12:04" for a take's length.
    public static func length(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        let seconds = Int((Double(milliseconds) / 1000).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "0.28 s" for a time after the stop tap.
    public static func seconds(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        return String(format: "%.2f s", Double(milliseconds) / 1000)
    }

    /// Binary units, matching the lab: "812 KB", "47.0 MB", "3.30 GB".
    public static func bytes(_ count: Int64?) -> String {
        guard let count else { return "—" }
        let n = Double(count)
        if count < 1024 { return "\(count) B" }
        if n < pow(1024, 2) { return String(format: "%.0f KB", n / 1024) }
        if n < pow(1024, 3) { return String(format: "%.1f MB", n / pow(1024, 2)) }
        return String(format: "%.2f GB", n / pow(1024, 3))
    }

    /// A mode's two-letter platform code from its name's initials: "Gemini SMART" posts GS,
    /// "Scribe" posts SC.
    public static func platformCode(_ name: String) -> String {
        let initials = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap(\.first)
        return String((initials.count >= 2 ? initials : Array(name.filter { $0.isLetter || $0.isNumber })).prefix(2)).uppercased()
    }

    /// Words in a text, split on whitespace.
    public static func wordCount(_ text: String?) -> Int {
        guard let text else { return 0 }
        return text.split(whereSeparator: \.isWhitespace).count
    }
}

extension TakeRecord {
    /// Where the text went, or where focus was when the take began if it never pasted.
    public var destination: String? {
        [destinationAtPaste, destinationAtStart].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// The best text the take has: what was pasted, else the cleaned text, else the raw transcript.
    public var bestText: String? {
        [finalText, cleanedText, rawTranscript].compactMap { $0 }.first { !$0.allSatisfy(\.isWhitespace) }
    }

    /// Words of the best text; nil for a cancel, which shows a dash.
    public var words: Int? {
        outcome == .cancelled ? nil : HistoryBoard.wordCount(bestText)
    }

    /// Whether the take's text reached the focused app.
    public var didPaste: Bool { outcome == .pasted || outcome == .rerouted }
}
