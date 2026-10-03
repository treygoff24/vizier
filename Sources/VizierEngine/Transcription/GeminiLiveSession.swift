import Foundation

/// The protocol logic of one Gemini Live take, apart from the socket, so it can be tested
/// without a network. Feed it what happens; send what it returns, in order.
///
/// A take is one activity: `activityStart`, the audio, `activityEnd`. Audio that arrives before
/// the server confirms setup is held and sent right after `activityStart`, and a stop before
/// setup completes still sends every held chunk before `activityEnd`. The take is done when
/// `generationComplete` follows `activityEnd`. A take the server heard nothing in gets no
/// `generationComplete`, only the activity-end echo, so that echo ends a take with no text at all;
/// once any text has come, the take keeps waiting for its final.
public struct GeminiLiveSession: Sendable {
    public enum Output: Equatable, Sendable {
        case send(GeminiLive.ClientMessage)
        /// Everything heard so far, for the strip: finals, then the interim words still turning.
        case transcript(settled: String, pending: String)
        /// The take's text. Nothing follows it.
        case done(String)
    }

    private enum Phase { case idle, awaitingSetup, streaming, ending, done }

    private let setup: GeminiLive.Setup
    private var phase = Phase.idle
    private var held: [Data] = []
    private var endRequested = false
    private var finals: [String] = []
    private var heardText = false

    public init(setup: GeminiLive.Setup) {
        self.setup = setup
    }

    public mutating func begin() -> [Output] {
        guard phase == .idle else { return [] }
        phase = .awaitingSetup
        return [.send(.setup(setup))]
    }

    public mutating func audio(_ pcm: Data) -> [Output] {
        switch phase {
        case .awaitingSetup where !endRequested:
            held.append(pcm)
            return []
        case .streaming:
            return [.send(.audio(pcm))]
        default:
            return []
        }
    }

    public mutating func end() -> [Output] {
        switch phase {
        case .awaitingSetup:
            endRequested = true
            return []
        case .streaming:
            phase = .ending
            return [.send(.activityEnd)]
        default:
            return []
        }
    }

    public mutating func receive(_ event: GeminiLive.ServerEvent) -> [Output] {
        switch (phase, event) {
        case (.awaitingSetup, .setupComplete):
            var out: [Output] = [.send(.activityStart)]
            out += held.map { .send(.audio($0)) }
            held = []
            if endRequested {
                phase = .ending
                out.append(.send(.activityEnd))
            } else {
                phase = .streaming
            }
            return out
        case (.streaming, .interim(let text)), (.ending, .interim(let text)):
            heardText = heardText || !Self.join([text]).isEmpty
            return [.transcript(settled: Self.join(finals), pending: Self.join([text]))]
        case (.streaming, .final(let text)), (.ending, .final(let text)):
            finals.append(text)
            heardText = heardText || !Self.join([text]).isEmpty
            return [.transcript(settled: Self.join(finals), pending: "")]
        case (.ending, .generationComplete):
            phase = .done
            return [.done(Self.join(finals))]
        case (.ending, .activityEnded) where !heardText:
            phase = .done
            return [.done("")]
        default:
            return []
        }
    }

    private static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
