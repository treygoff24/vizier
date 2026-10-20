import Foundation

/// The wire format of AssemblyAI streaming (v3), from the Streaming WebSocket API reference
/// (assemblyai.com/docs/api-reference/streaming-api, read 2026-10-20). Settings travel in the URL
/// and the key in the `Authorization` header; audio goes up as binary frames; the server answers
/// with `Begin`, then `Turn` messages, and `Termination` after a client `Terminate`.
public enum AssemblyAIRealtime {
    public static let endpoint = URL(string: "wss://streaming.assemblyai.com/v3/ws")!

    /// "a maximum of 100 keyterms per session", each "50 characters or less".
    public static let maxKeyterms = 100
    public static let maxKeytermLength = 50

    public struct Setup: Equatable, Sendable {
        public var model: String
        public var vocabulary: [String]
        /// A plain description of the audio (`prompt`); empty sends none.
        public var prompt: String

        public init(model: String, vocabulary: [String], prompt: String = "") {
            self.model = model
            self.vocabulary = vocabulary
            self.prompt = prompt
        }
    }

    public static func keyterms(_ vocabulary: [String]) -> [String] {
        var out: [String] = []
        for term in vocabulary.map({ $0.trimmingCharacters(in: .whitespaces) })
        where !term.isEmpty && term.count <= maxKeytermLength && !out.contains(term) {
            out.append(term)
            if out.count == maxKeyterms { break }
        }
        return out
    }

    public static func url(_ setup: Setup) -> URL {
        var items: [(String, String)] = [("speech_model", setup.model), ("sample_rate", "16000"), ("encoding", "pcm_s16le")]
        let terms = keyterms(setup.vocabulary)
        if !terms.isEmpty, let json = try? JSONEncoder().encode(terms) {
            items.append(("keyterms_prompt", String(decoding: json, as: UTF8.self)))
        }
        if !setup.prompt.isEmpty { items.append(("prompt", setup.prompt)) }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = items.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }.joined(separator: "&")
        return URL(string: "\(endpoint.absoluteString)?\(query)")!
    }

    public static let forceEndpointFrame = Data(#"{"type":"ForceEndpoint"}"#.utf8)
    public static let terminateFrame = Data(#"{"type":"Terminate"}"#.utf8)

    public enum ServerEvent: Equatable, Sendable {
        case begin
        /// One turn so far: its order, its text, and whether the turn has ended.
        case turn(order: Int, text: String, ended: Bool)
        case termination
        case failed(String)
        case ignored
    }

    public static func decode(_ frame: Data) throws -> ServerEvent {
        let message = try JSONDecoder().decode(Wire.Message.self, from: frame)
        switch message.type {
        case "Begin": return .begin
        case "Turn": return .turn(order: message.turn_order ?? 0, text: message.transcript ?? "", ended: message.end_of_turn ?? false)
        case "Termination": return .termination
        case "Error": return .failed(message.error ?? "error")
        default:
            if let error = message.error { return .failed(error) }
            return .ignored
        }
    }

    private enum Wire {
        struct Message: Decodable {
            var type: String?
            var turn_order: Int?
            var transcript: String?
            var end_of_turn: Bool?
            var error: String?
        }
    }
}

/// The protocol logic of one AssemblyAI take, apart from the socket. Audio before `Begin` is held.
/// At the stop it sends `ForceEndpoint`, which ends the open turn at the audio sent so far, then
/// `Terminate`. The take is done at the first turn that ends after the stop and had not ended
/// before it: that is the forced endpoint, and it covers every frame sent. Waiting for
/// `Termination` instead cost 0.4 to 0.5 s more (measured on a synthetic clip). When no turn
/// was open, nothing is forced, and `Termination` ends the take. Its text is every turn in
/// order; a turn that never ended keeps its last text.
public struct AssemblyAIRealtimeSession: Sendable {
    public enum Output: Equatable, Sendable {
        case sendAudio(Data)
        case sendForceEndpoint
        case sendTerminate
        case transcript(settled: String, pending: String)
        case done(String)
        case failed(String)
    }

    private enum Phase { case awaitingBegin, streaming, ending, done }
    private var phase = Phase.awaitingBegin
    private var held: [Data] = []
    private var endRequested = false
    private var turns: [Int: (text: String, ended: Bool)] = [:]
    /// Turns already ended when the stop came.
    private var endedAtStop: Set<Int> = []

    public init() {}

    public mutating func audio(_ pcm: Data) -> [Output] {
        switch phase {
        case .awaitingBegin where !endRequested:
            held.append(pcm)
            return []
        case .streaming:
            return [.sendAudio(pcm)]
        default:
            return []
        }
    }

    public mutating func end() -> [Output] {
        switch phase {
        case .awaitingBegin:
            endRequested = true
            return []
        case .streaming:
            phase = .ending
            endedAtStop = Set(turns.filter(\.value.ended).keys)
            return [.sendForceEndpoint, .sendTerminate]
        default:
            return []
        }
    }

    public mutating func receive(_ event: AssemblyAIRealtime.ServerEvent) -> [Output] {
        guard phase != .done else { return [] }
        switch event {
        case .begin where phase == .awaitingBegin:
            phase = .streaming
            var out = held.map { Output.sendAudio($0) }
            held = []
            if endRequested {
                phase = .ending
                out += [.sendForceEndpoint, .sendTerminate]
            }
            return out
        case .turn(let order, let text, let ended):
            turns[order] = (text, ended)
            if phase == .ending, ended, !endedAtStop.contains(order) {
                phase = .done
                return [transcript(), .done(allText())]
            }
            return [transcript()]
        case .termination:
            phase = .done
            return [.done(allText())]
        case .failed(let reason):
            phase = .done
            return [.failed(reason)]
        default:
            return []
        }
    }

    public mutating func liveClosed(_ reason: String) -> [Output] {
        guard phase != .done else { return [] }
        phase = .done
        return [.failed(reason)]
    }

    private func allText() -> String {
        Self.join(turns.keys.sorted().map { turns[$0]!.text })
    }

    private func transcript() -> Output {
        let ordered = turns.keys.sorted().map { turns[$0]! }
        return .transcript(settled: Self.join(ordered.filter(\.ended).map(\.text)),
                           pending: Self.join(ordered.filter { !$0.ended }.map(\.text)))
    }

    private static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
