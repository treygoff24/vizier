import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

/// Streams one take to `gemini-3.5-transcribe-live` over a WebSocket. The protocol decisions live
/// in `GeminiLiveSession`; this class moves bytes, keeps them in order, and turns every way the
/// connection can fail into one `TranscriberError`.
public final class GeminiLiveTranscriber: LiveTranscriber, @unchecked Sendable {
    /// No cookies, no cache: every take is its own connection.
    static let urlSession = URLSession(configuration: .ephemeral)

    private let queue = DispatchQueue(label: "net.praxient.dictum.gemini-live")
    private let apiKey: String
    private let finalTimeout: DispatchTimeInterval
    private let log = Logger(subsystem: "net.praxient.dictum", category: "gemini-live")

    // Everything below is touched only on `queue`.
    private var session: GeminiLiveSession
    private var socket: URLSessionWebSocketTask?
    private var outbox: [Data] = []
    private var sending = false
    private var onEvent: (@Sendable (LiveTranscriberEvent) -> Void)?
    private var outcome: Result<String, TranscriberError>?
    private var waiter: CheckedContinuation<String, Error>?
    private var timer: DispatchWorkItem?

    public init(setup: GeminiLive.Setup, apiKey: String, finalTimeoutMs: Int) {
        self.session = GeminiLiveSession(setup: setup)
        self.apiKey = apiKey
        self.finalTimeout = .milliseconds(finalTimeoutMs)
    }

    #if os(Linux)
    // Loopback tests exercise FoundationNetworking itself, without provider credentials.
    private var testEndpoint: URL?

    convenience init(setup: GeminiLive.Setup, apiKey: String, finalTimeoutMs: Int, endpoint: URL) {
        self.init(setup: setup, apiKey: apiKey, finalTimeoutMs: finalTimeoutMs)
        self.testEndpoint = endpoint
    }
    #endif

    deinit {
        socket?.cancel(with: .goingAway, reason: nil)
    }

    public func start(onEvent: @escaping @Sendable (LiveTranscriberEvent) -> Void) {
        queue.async { [self] in
            guard socket == nil, outcome == nil else { return }
            self.onEvent = onEvent
            #if os(Linux)
            var request = URLRequest(url: testEndpoint ?? GeminiLive.endpoint)
            #else
            var request = URLRequest(url: GeminiLive.endpoint)
            #endif
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let socket = Self.urlSession.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            receive(on: socket)
            apply(session.begin())
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

    private func apply(_ outputs: [GeminiLiveSession.Output]) {
        for output in outputs {
            guard outcome == nil else { return }
            switch output {
            case .send(let message):
                do {
                    outbox.append(try GeminiLive.encode(message))
                } catch {
                    settle(.failure(.streamLost("could not encode a message: \(error)")))
                    return
                }
                pump()
            case .transcript(let settled, let pending):
                onEvent?(.transcript(settled: settled, pending: pending))
            case .done(let text):
                settle(.success(text))
            }
        }
    }

    /// Sends one frame at a time, so frames reach the server in the order the session produced them.
    private func pump() {
        guard !sending, let socket, !outbox.isEmpty else { return }
        sending = true
        let frame = outbox.removeFirst()
        socket.send(.string(String(decoding: frame, as: UTF8.self))) { [weak self] error in
            guard let self else { return }
            queue.async { [self] in
                sending = false
                guard self.socket === socket else { return }
                if let error {
                    settle(.failure(.streamLost(Self.describe(error, on: socket))))
                } else {
                    pump()
                }
            }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            queue.async { [self] in
                guard self.socket === socket, outcome == nil else { return }
                switch result {
                case .failure(let error):
                    settle(.failure(.streamLost(Self.describe(error, on: socket))))
                case .success(let message):
                    handle(message)
                    receive(on: socket)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let frame: Data
        switch message {
        case .data(let data): frame = data
        case .string(let text): frame = Data(text.utf8)
        @unknown default: return
        }
        let events: [GeminiLive.ServerEvent]
        do {
            events = try GeminiLive.decode(frame)
        } catch {
            log.error("unreadable server frame of \(frame.count, privacy: .public) bytes: \(String(describing: error), privacy: .private)")
            return
        }
        for event in events {
            if case .goAway(let timeLeft) = event {
                log.notice("server will close the session in \(timeLeft ?? "an unstated time", privacy: .private)")
            }
            apply(session.receive(event))
        }
    }

    private func settle(_ result: Result<String, TranscriberError>) {
        guard outcome == nil else { return }
        outcome = result
        timer?.cancel()
        timer = nil
        outbox = []
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        if case .failure(.streamLost(let reason)) = result {
            onEvent?(.streamLost(reason))
        }
        onEvent = nil
        waiter?.resume(with: result.mapError { $0 as Error })
        waiter = nil
    }

    /// The server puts its reason (a bad key, an unknown model) in the close frame, and a refused
    /// upgrade shows up only as the HTTP status.
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
