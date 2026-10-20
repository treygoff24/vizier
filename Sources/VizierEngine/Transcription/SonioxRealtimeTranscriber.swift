import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

/// Streams one take to Soniox real-time transcription over a WebSocket. The protocol decisions
/// live in `SonioxRealtimeSession`; this class moves bytes, keeps them in order, and turns every
/// way the connection can fail into one `TranscriberError`. It mirrors `ScribeRealtimeTranscriber`
/// without the segment repair, which Soniox does not need.
public final class SonioxRealtimeTranscriber: LiveTranscriber, @unchecked Sendable {
    /// No cookies, no cache: every take is its own connection.
    static let urlSession = URLSession(configuration: .ephemeral)

    private enum Frame { case text(Data), binary(Data) }

    private let queue = DispatchQueue(label: "net.praxient.dictum.soniox-realtime")
    private let setup: SonioxRealtime.Setup
    private let apiKey: String
    private let finalTimeout: DispatchTimeInterval
    private let log = Logger(subsystem: "net.praxient.dictum", category: "soniox-realtime")

    // Everything below is touched only on `queue`.
    private var session = SonioxRealtimeSession()
    private var socket: URLSessionWebSocketTask?
    private var outbox: [Frame] = []
    private var sending = false
    private var onEvent: (@Sendable (LiveTranscriberEvent) -> Void)?
    private var outcome: Result<String, TranscriberError>?
    private var waiter: CheckedContinuation<String, Error>?
    private var timer: DispatchWorkItem?

    public init(setup: SonioxRealtime.Setup, apiKey: String, finalTimeoutMs: Int) {
        self.setup = setup
        self.apiKey = apiKey
        self.finalTimeout = .milliseconds(finalTimeoutMs)
    }

    deinit {
        socket?.cancel(with: .goingAway, reason: nil)
    }

    public func start(onEvent: @escaping @Sendable (LiveTranscriberEvent) -> Void) {
        queue.async { [self] in
            guard socket == nil, outcome == nil else { return }
            self.onEvent = onEvent
            let config: Data
            do {
                config = try SonioxRealtime.configFrame(setup, apiKey: apiKey)
            } catch {
                settle(.failure(.streamLost("could not encode the settings")))
                return
            }
            let socket = Self.urlSession.webSocketTask(with: SonioxRealtime.endpoint)
            self.socket = socket
            socket.resume()
            // The settings must be the first frame; the socket sends in queue order.
            outbox.insert(.text(config), at: 0)
            pump()
            receive()
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

    private func apply(_ outputs: [SonioxRealtimeSession.Output]) {
        for output in outputs {
            guard outcome == nil else { return }
            switch output {
            case .sendAudio(let pcm):
                outbox.append(.binary(pcm))
                pump()
            case .sendFinalize:
                outbox.append(.text(SonioxRealtime.finalizeFrame))
                pump()
            case .transcript(let settled, let pending):
                onEvent?(.transcript(settled: settled, pending: pending))
            case .done(let text):
                settle(.success(text))
            case .failed(let reason):
                settle(.failure(.streamLost(reason)))
            }
        }
    }

    /// Sends one frame at a time, so frames reach the server in the order they were queued.
    /// Frames queued before `start` wait for the socket.
    private func pump() {
        guard let socket, !sending, !outbox.isEmpty else { return }
        sending = true
        let message: URLSessionWebSocketTask.Message
        switch outbox.removeFirst() {
        case .text(let data): message = .string(String(decoding: data, as: UTF8.self))
        case .binary(let data): message = .data(data)
        }
        socket.send(message) { [weak self] error in
            guard let self else { return }
            queue.async { [self] in
                sending = false
                guard self.socket === socket, outcome == nil else { return }
                if let error {
                    lost(Self.describe(error, on: socket))
                } else {
                    pump()
                }
            }
        }
    }

    private func receive() {
        guard let socket else { return }
        socket.receive { [weak self] result in
            guard let self else { return }
            queue.async { [self] in
                guard self.socket === socket, outcome == nil else { return }
                switch result {
                case .failure(let error):
                    lost(Self.describe(error, on: socket))
                case .success(let message):
                    handle(message)
                    receive()
                }
            }
        }
    }

    private func lost(_ reason: String) {
        apply(session.liveClosed(reason))
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let frame: Data
        switch message {
        case .data(let data): frame = data
        case .string(let text): frame = Data(text.utf8)
        @unknown default: return
        }
        do {
            apply(session.receive(try SonioxRealtime.decode(frame)))
        } catch {
            log.error("unreadable server frame of \(frame.count, privacy: .public) bytes: \(String(describing: error), privacy: .private)")
        }
    }

    private func settle(_ result: Result<String, TranscriberError>) {
        guard outcome == nil else { return }
        outcome = result
        timer?.cancel()
        timer = nil
        outbox = []
        // Billing runs while the stream is open, so close it as soon as the take is decided.
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        if case .failure(.streamLost(let reason)) = result {
            onEvent?(.streamLost(reason))
        }
        onEvent = nil
        waiter?.resume(with: result.mapError { $0 as Error })
        waiter = nil
    }

    /// The server puts its reason in the close frame (after an error response, which the session
    /// has usually reported already), and a refused upgrade shows up only as the HTTP status.
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
