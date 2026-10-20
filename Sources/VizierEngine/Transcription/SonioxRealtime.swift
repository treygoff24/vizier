import Foundation

/// The wire format of Soniox real-time transcription (`stt-rt-v5`), from the WebSocket API
/// reference (soniox.com/docs/stt/api-reference/websocket-api, read 2026-10-20). The first frame
/// is a JSON text frame with the key and settings; audio follows as binary frames; a
/// `{"type":"finalize"}` text frame makes the server finalize everything sent so far and answer
/// with a `<fin>` marker token.
public enum SonioxRealtime {
    public static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    /// The whole context object may be about 10,000 characters; terms are kept well under that.
    public static let maxTermCharacters = 8_000

    /// The marker token that ends a manual finalization.
    static let finMarker = "<fin>"
    /// The marker token endpoint detection emits; Vizier leaves endpoint detection off, but the
    /// text never carries it either way.
    static let endMarker = "<end>"

    public struct Setup: Equatable, Sendable {
        public var model: String
        /// Bare ISO 639 codes, in the mode's order, without duplicates.
        public var languageHints: [String]
        public var vocabulary: [String]
        /// Soniox's `general` context: short key-value facts about the audio (domain, setting).
        public var general: [GeneralItem]

        public init(model: String, languages: [String], vocabulary: [String], general: [GeneralItem] = []) {
            self.model = model
            self.general = general
            var hints: [String] = []
            for code in languages.compactMap(ScribeLanguage.code(from:)) where !hints.contains(code) { hints.append(code) }
            self.languageHints = hints
            self.vocabulary = vocabulary
        }
    }

    public struct GeneralItem: Equatable, Sendable, Encodable {
        public var key: String
        public var value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// The vocabulary terms sent as context, in order, trimmed and deduplicated, stopping before
    /// their total length passes `maxTermCharacters`.
    public static func terms(_ vocabulary: [String]) -> [String] {
        var out: [String] = []
        var total = 0
        for term in vocabulary.map({ $0.trimmingCharacters(in: .whitespaces) }) where !term.isEmpty && !out.contains(term) {
            guard total + term.count <= maxTermCharacters else { break }
            out.append(term)
            total += term.count
        }
        return out
    }

    /// The opening frame. Raw 16 kHz 16-bit mono PCM, endpoint detection off: Vizier finalizes
    /// when the hotkey is released.
    public static func configFrame(_ setup: Setup, apiKey: String) throws -> Data {
        let terms = terms(setup.vocabulary)
        let config = Wire.Config(
            api_key: apiKey, model: setup.model, audio_format: "pcm_s16le", sample_rate: 16_000, num_channels: 1,
            language_hints: setup.languageHints.isEmpty ? nil : setup.languageHints,
            context: terms.isEmpty && setup.general.isEmpty
                ? nil : Wire.Context(general: setup.general.isEmpty ? nil : setup.general, terms: terms.isEmpty ? nil : terms))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }

    public static let finalizeFrame = Data(#"{"type":"finalize"}"#.utf8)

    public struct Token: Equatable, Sendable {
        public var text: String
        public var isFinal: Bool

        public init(_ text: String, isFinal: Bool) {
            self.text = text
            self.isFinal = isFinal
        }
    }

    public enum ServerEvent: Equatable, Sendable {
        /// One response: tokens finalized in it (sent once, never repeated) and the current
        /// non-final tail (replaced by the next response).
        case tokens([Token])
        /// The server ended the stream after an empty frame; it closes the socket next.
        case finished
        /// An error response; the server closes the socket right after it.
        case failed(type: String, message: String)
    }

    public static func decode(_ frame: Data) throws -> ServerEvent {
        let message = try JSONDecoder().decode(Wire.Response.self, from: frame)
        if let text = message.error_message ?? message.error_code.map({ "error \($0)" }) {
            return .failed(type: message.error_type ?? "error", message: text)
        }
        if message.finished == true { return .finished }
        return .tokens((message.tokens ?? []).map { Token($0.text, isFinal: $0.is_final ?? false) })
    }

    private enum Wire {
        struct Config: Encodable {
            var api_key: String
            var model: String
            var audio_format: String
            var sample_rate: Int
            var num_channels: Int
            var language_hints: [String]?
            var context: Context?
        }

        struct Context: Encodable {
            var general: [GeneralItem]?
            var terms: [String]?
        }

        struct Response: Decodable {
            var tokens: [WireToken]?
            var finished: Bool?
            var error_code: Int?
            var error_type: String?
            var error_message: String?
        }

        struct WireToken: Decodable {
            var text: String
            var is_final: Bool?
        }
    }
}

/// The protocol logic of one Soniox take, apart from the socket, so it can be tested without a
/// network. Feed it what happens; send what it returns, in order.
///
/// A take is one stream: Soniox takes up to 300 minutes on a connection, so there are no
/// segments to cut. At the stop it sends `trailingSilenceMs` of silence (Soniox advises about
/// 200 ms of quiet after speech before a finalize, and a hotkey release often lands right on the
/// last word), then the finalize. The take is done at the `<fin>` marker: every token before it
/// is final.
public struct SonioxRealtimeSession: Sendable {
    public enum Output: Equatable, Sendable {
        case sendAudio(Data)
        case sendFinalize
        /// Everything heard so far: final text, then the non-final tail.
        case transcript(settled: String, pending: String)
        /// The take's text. Nothing follows it.
        case done(String)
        /// The stream failed before the final. Nothing follows it.
        case failed(String)
    }

    static let bytesPerSecond = 32_000
    public static let trailingSilenceMs = 200

    private enum Phase { case streaming, ending, done }
    private var phase = Phase.streaming
    private var settled = ""
    private var pending = ""

    public init() {}

    public mutating func audio(_ pcm: Data) -> [Output] {
        phase == .streaming ? [.sendAudio(pcm)] : []
    }

    public mutating func end() -> [Output] {
        guard phase == .streaming else { return [] }
        phase = .ending
        let silence = Data(count: Self.bytesPerSecond * Self.trailingSilenceMs / 1000)
        return [.sendAudio(silence), .sendFinalize]
    }

    public mutating func receive(_ event: SonioxRealtime.ServerEvent) -> [Output] {
        guard phase != .done else { return [] }
        switch event {
        case .failed(let type, let message):
            phase = .done
            return [.failed("\(type): \(message)")]
        case .finished:
            // Only an empty frame ends the stream, and Vizier sends none before `<fin>`.
            return finish(reason: "the server finished the stream before the final")
        case .tokens(let tokens):
            var fin = false
            pending = ""
            for token in tokens {
                if token.text == SonioxRealtime.finMarker {
                    if token.isFinal { fin = true }
                    continue
                }
                if token.text == SonioxRealtime.endMarker { continue }
                if token.isFinal { settled += token.text } else { pending += token.text }
            }
            var out: [Output] = [.transcript(settled: Self.trim(settled), pending: Self.trim(pending))]
            if fin, phase == .ending {
                phase = .done
                out.append(.done(Self.trim(settled)))
            }
            return out
        }
    }

    /// The connection closed or failed.
    public mutating func liveClosed(_ reason: String) -> [Output] {
        finish(reason: reason)
    }

    private mutating func finish(reason: String) -> [Output] {
        guard phase != .done else { return [] }
        phase = .done
        return [.failed(reason)]
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
