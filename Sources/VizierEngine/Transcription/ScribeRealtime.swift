import Foundation

/// The wire format of ElevenLabs Scribe v2 Realtime, checked against the realtime API reference and
/// live probes. Settings travel in the URL; the socket carries JSON text frames with
/// base64 audio one way and transcript events the other.
public enum ScribeRealtime {
    public static let endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!

    /// The realtime model takes at most 50 keyterms of at most 20 characters each.
    public static let maxKeyterms = 50
    public static let maxKeytermLength = 20

    public struct Setup: Equatable, Sendable {
        public var model: String
        /// An ISO 639 code. The API rejects a region suffix ("en-US" closes the socket with
        /// `invalid_request`), so the setup keeps only the language code (`ScribeLanguage`).
        public var language: String?
        public var vocabulary: [String]
        /// Scribe's own removal of fillers, false starts, and disfluencies.
        public var noVerbatim: Bool

        public init(model: String, languages: [String], vocabulary: [String], noVerbatim: Bool) {
            self.model = model
            self.language = ScribeLanguage.code(from: languages.first)
            self.vocabulary = vocabulary
            self.noVerbatim = noVerbatim
        }
    }

    /// The vocabulary terms the realtime model accepts, in order: the first 50 that fit in 20
    /// characters. Longer terms are left out rather than truncated into something else.
    public static func keyterms(_ vocabulary: [String]) -> [String] {
        Array(vocabulary.lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= maxKeytermLength }.prefix(maxKeyterms))
    }

    /// Manual commits: Vizier decides where segments end, so it knows how many finals to wait for.
    /// Timestamps add a second message after each `committed_transcript`, so the plain answer, which
    /// ends the take, is not delayed (measured: the timed copy came 0.15 to 0.6 s later).
    public static func url(_ setup: Setup) -> URL {
        var items: [(String, String)] = [
            ("model_id", setup.model), ("audio_format", "pcm_16000"), ("commit_strategy", "manual"),
            ("include_timestamps", "true"),
        ]
        if let language = setup.language { items.append(("language_code", language)) }
        if setup.noVerbatim { items.append(("no_verbatim", "true")) }
        items += keyterms(setup.vocabulary).map { ("keyterms", $0) }
        // Percent-encode everything but unreserved characters, so a "+" or "&" in a term survives.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = items.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }.joined(separator: "&")
        return URL(string: "\(endpoint.absoluteString)?\(query)")!
    }

    public enum ClientMessage: Equatable, Sendable {
        /// 16 kHz 16-bit mono PCM.
        case audio(Data)
        /// Ends the current segment. The server answers with its `committed_transcript`, or with
        /// `commit_throttled` when less than 0.3 s of audio is uncommitted.
        case commit
    }

    /// One piece of a timed transcript: a word, or the spacing between words. Times are seconds of
    /// audio from the start of the session, not of the segment (measured: the second
    /// segment of a take cut at 30 s began at 30.06).
    public struct TimedToken: Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
        public var isWord: Bool

        public init(_ text: String, start: Double, end: Double, isWord: Bool = true) {
            self.text = text
            self.start = start
            self.end = end
            self.isWord = isWord
        }
    }

    public enum ServerEvent: Equatable, Sendable {
        case sessionStarted
        /// The current segment so far, not a delta.
        case partial(String)
        /// A finished segment. It will not change.
        case committed(String)
        /// The same finished segment again, with every word's timing. It arrives after `committed`.
        case timed(text: String, tokens: [TimedToken])
        /// The server ignored a commit because too little audio was uncommitted.
        case commitIgnored
        /// An error event (`auth_error`, `quota_exceeded`, `invalid_request`, and the rest). The
        /// server closes the socket after most of them.
        case failed(type: String, message: String)
        /// Events this build doesn't use: entities, warnings.
        case ignored
    }

    public static func encode(_ message: ClientMessage) throws -> Data {
        let audio: Data
        let commit: Bool
        switch message {
        case .audio(let pcm): (audio, commit) = (pcm, false)
        case .commit: (audio, commit) = (Data(), true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire.Chunk(
            message_type: "input_audio_chunk", audio_base_64: audio.base64EncodedString(), commit: commit, sample_rate: 16_000))
    }

    public static func decode(_ frame: Data) throws -> ServerEvent {
        let message = try JSONDecoder().decode(Wire.ServerMessage.self, from: frame)
        switch message.message_type {
        case "session_started": return .sessionStarted
        case "partial_transcript": return .partial(message.text ?? "")
        case "committed_transcript": return .committed(message.text ?? "")
        case "committed_transcript_with_timestamps":
            let tokens = (message.words ?? []).compactMap { word -> TimedToken? in
                guard let text = word.text, let start = word.start, let end = word.end else { return nil }
                return TimedToken(text, start: start, end: end, isWord: word.type == "word")
            }
            return .timed(text: message.text ?? "", tokens: tokens)
        case "commit_throttled": return .commitIgnored
        default:
            if let error = message.error { return .failed(type: message.message_type, message: error) }
            return .ignored
        }
    }

    private enum Wire {
        struct Chunk: Encodable {
            var message_type: String
            var audio_base_64: String
            var commit: Bool
            var sample_rate: Int
        }

        struct ServerMessage: Decodable {
            var message_type: String
            var text: String?
            var error: String?
            var words: [Word]?
        }

        struct Word: Decodable {
            var text: String?
            var start: Double?
            var end: Double?
            var type: String?
        }
    }
}
