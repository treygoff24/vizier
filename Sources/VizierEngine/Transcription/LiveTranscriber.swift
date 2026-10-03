import Foundation

/// What a live transcriber reports while a take is running.
public enum LiveTranscriberEvent: Equatable, Sendable {
    /// Everything heard so far in this take: the finals, which will not change, then the
    /// interim words, which may.
    case transcript(settled: String, pending: String)
    /// The stream failed before the final. The take keeps recording; its saved audio goes to batch at stop.
    case streamLost(String)
}

public enum TranscriberError: Error, Equatable, Sendable, CustomStringConvertible {
    case streamLost(String)
    case timedOut
    case cancelled

    public var description: String {
        switch self {
        case .streamLost(let reason): "stream lost: \(reason)"
        case .timedOut: "no final before the timeout"
        case .cancelled: "cancelled"
        }
    }
}

/// The interface every streaming engine adapter shares. One instance serves one take.
///
/// Calls may come from any thread; each adapter serializes them in call order, so audio sent
/// before `finish()` is always transcribed before the final is returned.
public protocol LiveTranscriber: AnyObject, Sendable {
    /// Connects and begins the take. Audio sent before the connection is ready is buffered.
    func start(onEvent: @escaping @Sendable (LiveTranscriberEvent) -> Void)
    /// 16 kHz 16-bit mono PCM, little-endian.
    func send(_ pcm: Data)
    /// Ends the take and waits for its final text. Throws `TranscriberError` when the stream
    /// failed, the final did not arrive in time, or the take was cancelled.
    func finish() async throws -> String
    /// Abandons the take. A pending `finish()` throws `TranscriberError.cancelled`.
    func cancel()
}
