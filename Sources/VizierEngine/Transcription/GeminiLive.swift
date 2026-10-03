import Foundation

/// The wire format of the Gemini Live API for `gemini-3.5-transcribe-live`, checked against the
/// Live API reference and a live probe. The WebSocket speaks camelCase JSON; some
/// server frames (setupComplete among them) arrive as binary frames holding the same JSON.
public enum GeminiLive {
    public static let endpoint = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!

    public struct Setup: Equatable, Sendable {
        /// The model id with or without the `models/` prefix.
        public var model: String
        /// Live transcription mode, uppercase on this API ("SMART").
        public var mode: String
        public var languages: [String]
        public var vocabulary: [String]

        public init(model: String, mode: String, languages: [String], vocabulary: [String]) {
            self.model = model
            self.mode = mode
            self.languages = languages
            self.vocabulary = vocabulary
        }
    }

    public enum ClientMessage: Equatable, Sendable {
        case setup(Setup)
        /// Opens the take's one activity. Automatic activity detection is off, so Vizier marks it.
        case activityStart
        /// 16 kHz 16-bit mono PCM.
        case audio(Data)
        /// Closes the activity; the server answers with the final and `generationComplete`.
        case activityEnd
    }

    public enum ServerEvent: Equatable, Sendable {
        case setupComplete
        /// The whole activity so far, not a delta.
        case interim(String)
        /// The activity's final transcript.
        case final(String)
        case generationComplete
        /// The server's echo of the activity's end. It comes after the activity's final, and for
        /// an activity with no speech it is the only thing that comes (observed on a live connection).
        case activityEnded
        /// The server will close the session soon (sessions last at most 10 minutes).
        case goAway(timeLeft: String?)
    }

    public static let audioMimeType = "audio/pcm;rate=16000"

    public static func encode(_ message: ClientMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch message {
        case .setup(let setup):
            let transcription = Wire.InputAudioTranscription(
                mode: setup.mode,
                customVocabulary: setup.vocabulary.isEmpty ? nil : setup.vocabulary,
                languageCodes: setup.languages.isEmpty ? nil : setup.languages)
            return try encoder.encode(["setup": Wire.Setup(
                model: setup.model.hasPrefix("models/") ? setup.model : "models/\(setup.model)",
                generationConfig: .init(responseModalities: ["TEXT"]),
                realtimeInputConfig: .init(automaticActivityDetection: .init(disabled: true)),
                inputAudioTranscription: transcription)])
        case .activityStart:
            return try encoder.encode(["realtimeInput": ["activityStart": Wire.Empty()]])
        case .activityEnd:
            return try encoder.encode(["realtimeInput": ["activityEnd": Wire.Empty()]])
        case .audio(let pcm):
            return try encoder.encode(["realtimeInput": ["audio": Wire.Blob(data: pcm.base64EncodedString(), mimeType: audioMimeType)]])
        }
    }

    /// The events one server frame carries, in the order the take should see them. Fields this
    /// build doesn't use (the activity-start echo, usage metadata) are ignored.
    public static func decode(_ frame: Data) throws -> [ServerEvent] {
        let message = try JSONDecoder().decode(Wire.ServerMessage.self, from: frame)
        var events: [ServerEvent] = []
        if message.setupComplete != nil { events.append(.setupComplete) }
        if let content = message.serverContent {
            if let text = content.interimInputTranscription?.text { events.append(.interim(text)) }
            if let text = content.inputTranscription?.text { events.append(.final(text)) }
            if content.generationComplete == true { events.append(.generationComplete) }
        }
        if message.voiceActivity?.type == "ACTIVITY_END" { events.append(.activityEnded) }
        if let goAway = message.goAway { events.append(.goAway(timeLeft: goAway.timeLeft)) }
        return events
    }

    private enum Wire {
        struct Empty: Codable {}

        struct Setup: Encodable {
            var model: String
            var generationConfig: GenerationConfig
            var realtimeInputConfig: RealtimeInputConfig
            var inputAudioTranscription: InputAudioTranscription
        }
        struct GenerationConfig: Encodable { var responseModalities: [String] }
        struct RealtimeInputConfig: Encodable { var automaticActivityDetection: AutomaticActivityDetection }
        struct AutomaticActivityDetection: Encodable { var disabled: Bool }
        struct InputAudioTranscription: Encodable {
            var mode: String
            var customVocabulary: [String]?
            var languageCodes: [String]?
        }
        struct Blob: Encodable {
            var data: String
            var mimeType: String
        }

        struct ServerMessage: Decodable {
            var setupComplete: Empty?
            var serverContent: ServerContent?
            var voiceActivity: VoiceActivity?
            var goAway: GoAway?
        }
        struct VoiceActivity: Decodable { var type: String? }
        struct ServerContent: Decodable {
            var interimInputTranscription: Transcription?
            var inputTranscription: Transcription?
            var generationComplete: Bool?
        }
        struct Transcription: Decodable { var text: String? }
        struct GoAway: Decodable { var timeLeft: String? }
    }
}
