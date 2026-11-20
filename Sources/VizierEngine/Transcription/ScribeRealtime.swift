import Foundation

/// The wire format of ElevenLabs Scribe v3 Live and v2 Realtime. Both use the same WebSocket,
/// with settings in the URL and JSON frames for audio and transcripts. v3 Live is the default
/// and can also receive a keyterm library on the first audio frame.
public enum ScribeRealtime {
    public static let endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!

    /// The realtime model takes at most 50 keyterms of at most 20 characters each.
    public static let maxKeyterms = 50
    public static let maxKeytermLength = 20

    /// Scribe v3 Live also takes a keyterm library, which it consults only when it hears a likely
    /// match: up to 10,000 terms of at most 50 characters. Other models close the socket on one.
    public static let libraryModel = "scribe_v3_live"
    public static let defaultModel = libraryModel
    public static let maxLibraryTerms = 10_000
    public static let maxLibraryTermLength = 50

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
    /// Unicode scalars. Longer terms are left out rather than truncated into something else.
    public static func keyterms(_ vocabulary: [String]) -> [String] {
        Array(vocabulary.lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.unicodeScalars.count <= maxKeytermLength }.prefix(maxKeyterms))
    }

    /// The vocabulary terms that go in the keyterm library: for Scribe v3 Live, every term of at
    /// most 50 Unicode scalars that is not already a keyterm; for other models, none. Even
    /// 10,000 terms of 50 four-byte scalars fit in the service's 2 MB of library text.
    public static func keytermLibrary(_ setup: Setup) -> [String] {
        guard setup.model == libraryModel else { return [] }
        let keyterms = Set(keyterms(setup.vocabulary))
        return Array(setup.vocabulary.lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.unicodeScalars.count <= maxLibraryTermLength && !keyterms.contains($0) }.prefix(maxLibraryTerms))
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

    /// Known wire identifiers only. An unknown identifier must not carry arbitrary server text.
    public enum Failure: String, Sendable {
        case authentication = "auth_error"
        case quota = "quota_exceeded"
        case transcriber = "transcriber_error"
        case input = "input_error"
        case invalidRequest = "invalid_request"
        case serverError = "error"
        case unacceptedTerms = "unaccepted_terms"
        case rateLimited = "rate_limited"
        case queueOverflow = "queue_overflow"
        case resourceExhausted = "resource_exhausted"
        case sessionTimeLimit = "session_time_limit_exceeded"
        case chunkSize = "chunk_size_exceeded"
        case insufficientAudio = "insufficient_audio_activity"
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
        case failed(Failure)
        /// Events this build doesn't use: entities, warnings.
        case ignored
    }

    /// `library` rides only on a connection's first message; the server rejects it on any later one.
    public static func encode(_ message: ClientMessage, library: [String] = []) throws -> Data {
        let audio: Data
        let commit: Bool
        switch message {
        case .audio(let pcm): (audio, commit) = (pcm, false)
        case .commit: (audio, commit) = (Data(), true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire.Chunk(
            message_type: "input_audio_chunk", audio_base_64: audio.base64EncodedString(), commit: commit, sample_rate: 16_000,
            keyterm_library: library.isEmpty ? nil : library))
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
            if let failure = Failure(rawValue: message.message_type) { return .failed(failure) }
            if message.error != nil { return .failed(.serverError) }
            return .ignored
        }
    }

    private enum Wire {
        struct Chunk: Encodable {
            var message_type: String
            var audio_base_64: String
            var commit: Bool
            var sample_rate: Int
            var keyterm_library: [String]?
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
