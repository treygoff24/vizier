import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

/// Streams one take to ElevenLabs Scribe v2 Realtime over a WebSocket. The protocol decisions live
/// in `ScribeRealtimeSession`; this class moves bytes, keeps them in order, and turns every way the
/// connection can fail into one `TranscriberError`. It mirrors `GeminiLiveTranscriber`.
///
/// When the session asks for a repair, a second connection carries it. A repair that fails or
/// misses its deadline (a second inside the final timeout) leaves the live text in place; only the
/// live connection's failures fail the take.
public final class ScribeRealtimeTranscriber: LiveTranscriber, @unchecked Sendable {
    /// No cookies, no cache: every take is its own connection.
    static let urlSession = URLSession(configuration: .ephemeral)

    /// One socket and the frames waiting for it. Touched only on `queue`.
    private final class Link: @unchecked Sendable {
        let socket: URLSessionWebSocketTask
        var outbox: [Data] = []
        var sending = false
        init(_ socket: URLSessionWebSocketTask) { self.socket = socket }
    }

    private let queue = DispatchQueue(label: "net.praxient.dictum.scribe-realtime")
    private let setup: ScribeRealtime.Setup
    private let apiKey: String
    private let finalTimeout: DispatchTimeInterval
    private let repairTimeout: DispatchTimeInterval
    private let log = Logger(subsystem: "net.praxient.dictum", category: "scribe-realtime")

    // Everything below is touched only on `queue`.
    private var session = ScribeRealtimeSession()
    private var live: Link?
    private var repair: Link?
    private var repairAudio: Data?
    private var onEvent: (@Sendable (LiveTranscriberEvent) -> Void)?
    private var outcome: Result<String, TranscriberError>?
    private var waiter: CheckedContinuation<String, Error>?
    private var timer: DispatchWorkItem?
    private var repairTimer: DispatchWorkItem?

    public init(setup: ScribeRealtime.Setup, apiKey: String, finalTimeoutMs: Int) {
        self.setup = setup
        self.apiKey = apiKey
        self.finalTimeout = .milliseconds(finalTimeoutMs)
        self.repairTimeout = .milliseconds(max(finalTimeoutMs / 2, finalTimeoutMs - 1_000))
    }

    #if os(Linux)
    // Loopback tests exercise FoundationNetworking itself, without provider credentials.
    private var testEndpoint: URL?

    convenience init(setup: ScribeRealtime.Setup, apiKey: String, finalTimeoutMs: Int, endpoint: URL) {
        self.init(setup: setup, apiKey: apiKey, finalTimeoutMs: finalTimeoutMs)
        self.testEndpoint = endpoint
    }
    #endif

    deinit {
        live?.socket.cancel(with: .goingAway, reason: nil)
        repair?.socket.cancel(with: .goingAway, reason: nil)
    }

    public func start(onEvent: @escaping @Sendable (LiveTranscriberEvent) -> Void) {
        queue.async { [self] in
            guard live == nil, outcome == nil else { return }
            self.onEvent = onEvent
            let link = connect()
            live = link
            receive(on: link)
        }
    }

    public func send(_ pcm: Data) {
        queue.async { [self] in apply(session.audio(pcm)) }
    }

    public func finish() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let outcome {
                    continuation.resume(with: outcome.mapError { $0 as Error })
                    return
                }
                waiter = continuation
                let timer = DispatchWorkItem { [weak self] in self?.settle(.failure(.timedOut)) }
                self.timer = timer
                queue.asyncAfter(deadline: .now() + finalTimeout, execute: timer)
                apply(session.end())
            }
        }
    }

    public func cancel() {
        queue.async { [self] in settle(.failure(.cancelled)) }
    }

    private func connect() -> Link {
        #if os(Linux)
        var request = URLRequest(url: testEndpoint ?? ScribeRealtime.url(setup))
        #else
        var request = URLRequest(url: ScribeRealtime.url(setup))
        #endif
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let socket = Self.urlSession.webSocketTask(with: request)
        socket.resume()
        return Link(socket)
    }

    private func apply(_ outputs: [ScribeRealtimeSession.Output]) {
        for output in outputs {
            guard outcome == nil else { return }
            switch output {
            case .send(let message):
                guard let live else { continue }
                guard enqueue([message], on: live) else {
                    settle(.failure(.streamLost("could not encode a message")))
                    return
                }
            case .repair(let audio):
                startRepair(audio)
            case .transcript(let settled, let pending):
                onEvent?(.transcript(settled: settled, pending: pending))
            case .note(let text):
                log.notice("\(text, privacy: .private)")
            case .done(let text):
                settle(.success(text))
            case .failed(let reason):
                settle(.failure(.streamLost(reason)))
            }
        }
    }

    private func enqueue(_ messages: [ScribeRealtime.ClientMessage], on link: Link) -> Bool {
        do {
            link.outbox += try messages.map(ScribeRealtime.encode)
        } catch {
            return false
        }
        pump(link)
        return true
    }

    /// Sends one frame at a time, so frames reach the server in the order they were queued.
    private func pump(_ link: Link) {
        guard !link.sending, !link.outbox.isEmpty else { return }
        link.sending = true
        let frame = link.outbox.removeFirst()
        link.socket.send(.string(String(decoding: frame, as: UTF8.self))) { [weak self] error in
            guard let self else { return }
            queue.async { [self] in
                link.sending = false
                if let error {
                    lost(link, Self.describe(error, on: link.socket))
                } else if isOpen(link) {
                    pump(link)
                }
            }
        }
    }

    private func receive(on link: Link) {
        link.socket.receive { [weak self] result in
            guard let self else { return }
            queue.async { [self] in
                guard isOpen(link), outcome == nil else { return }
                switch result {
                case .failure(let error):
                    lost(link, Self.describe(error, on: link.socket))
                case .success(let message):
                    handle(message, from: link)
                    receive(on: link)
                }
            }
        }
    }

    private func isOpen(_ link: Link) -> Bool { link === live || link === repair }

    private func lost(_ link: Link, _ reason: String) {
        if link === live {
            // The session decides: fatal while an answer is owed, harmless after the last one.
            self.live = nil
            link.outbox = []
            link.socket.cancel(with: .normalClosure, reason: nil)
            apply(session.liveClosed(reason))
        } else if link === repair {
            endRepair(failure: reason)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, from link: Link) {
        let frame: Data
        switch message {
        case .data(let data): frame = data
        case .string(let text): frame = Data(text.utf8)
        @unknown default: return
        }
        let event: ScribeRealtime.ServerEvent
        do {
            event = try ScribeRealtime.decode(frame)
        } catch {
            log.error("unreadable server frame of \(frame.count, privacy: .public) bytes: \(String(describing: error), privacy: .private)")
            return
        }
        if link === repair {
            handleRepair(event)
            return
        }
        if case .commitIgnored = event {
            log.notice("server ignored a commit with under 0.3 s of uncommitted audio")
        }
        apply(session.receive(event))
    }

    // MARK: Repair

    private func startRepair(_ audio: Data) {
        guard repair == nil else { return }
        log.notice("repairing a short last segment with \(audio.count / 32_000, privacy: .public) s of audio")
        let link = connect()
        repair = link
        repairAudio = audio
        let deadline = DispatchWorkItem { [weak self] in self?.endRepair(failure: "no answer before the repair deadline") }
        repairTimer = deadline
        queue.asyncAfter(deadline: .now() + repairTimeout, execute: deadline)
        receive(on: link)
    }

    private func handleRepair(_ event: ScribeRealtime.ServerEvent) {
        guard let link = repair else { return }
        switch event {
        case .sessionStarted:
            guard let audio = repairAudio else { return }
            repairAudio = nil
            if !enqueue(ScribeRealtimeSession.repairMessages(audio), on: link) {
                endRepair(failure: "could not encode the repair audio")
            }
        case .committed(let text):
            closeRepair()
            apply(session.repaired(text))
        case .commitIgnored:
            endRepair(failure: "the server ignored the repair's commit")
        case .failed(let type, let message):
            endRepair(failure: "\(type): \(message)")
        case .partial, .timed, .ignored:
            break
        }
    }

    private func endRepair(failure reason: String) {
        guard repair != nil else { return }
        closeRepair()
        apply(session.repairFailed(reason))
    }

    private func closeRepair() {
        repairTimer?.cancel()
        repairTimer = nil
        repairAudio = nil
        repair?.outbox = []
        repair?.socket.cancel(with: .normalClosure, reason: nil)
        repair = nil
    }

    private func settle(_ result: Result<String, TranscriberError>) {
        guard outcome == nil else { return }
        outcome = result
        timer?.cancel()
        timer = nil
        closeRepair()
        live?.outbox = []
        live?.socket.cancel(with: .normalClosure, reason: nil)
        live = nil
        if case .failure(.streamLost(let reason)) = result {
            onEvent?(.streamLost(reason))
        }
        onEvent = nil
        waiter?.resume(with: result.mapError { $0 as Error })
        waiter = nil
    }

    /// The server puts its reason in the close frame (after an error event, which the session has
    /// usually reported already), and a refused upgrade shows up only as the HTTP status.
    private static func describe(_ error: Error, on socket: URLSessionWebSocketTask) -> String {
        var parts: [String] = []
        if socket.closeCode != .invalid {
            parts.append("closed \(socket.closeCode.rawValue)")
            if let reason = socket.closeReason, let text = String(data: reason, encoding: .utf8), !text.isEmpty {
                parts.append(text)
            }
        } else if let http = socket.response as? HTTPURLResponse, http.statusCode != 101 {
            parts.append("HTTP \(http.statusCode)")
        }
        parts.append((error as NSError).localizedDescription)
        return parts.joined(separator: ": ")
    }
}
