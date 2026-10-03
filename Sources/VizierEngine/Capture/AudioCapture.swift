import Foundation

/// What a capture tells its owner besides audio. Engine-neutral: the macOS input unit and the
/// Linux recorder subprocess both speak it.
public enum CaptureEvent: Sendable, Equatable {
    /// The first buffer with a nonzero sample since `start`. A blocked or dead input delivers
    /// exact digital silence, so this is the proof the microphone is listening.
    case signal
    case deviceSwitched(name: String)
    case deviceSwitchFailed(String)
    /// The capture ended without a `stop()` (a recorder process died, its stream hit EOF).
    /// Delivered at most once per `start`, after the last sink call. The owner keeps the audio
    /// it received so far and still calls `stop()`.
    case failed(String)
}

public struct CaptureStats: Sendable, Equatable {
    public var deviceSwitches: Int
    public var droppedBuffers: UInt64

    public init(deviceSwitches: Int = 0, droppedBuffers: UInt64 = 0) {
        self.deviceSwitches = deviceSwitches
        self.droppedBuffers = droppedBuffers
    }
}

/// Receives 16 kHz mono signed 16-bit samples.
public typealias CaptureSink = @Sendable (UnsafeBufferPointer<Int16>) -> Void

/// A source of 16 kHz mono signed 16-bit audio for one take at a time.
///
/// Lifecycle guarantees every conforming capture keeps, and the recorder relies on:
/// - Sink calls are serialized: never two at once, and in capture order.
/// - The sample pointer is valid only during the call; the sink copies what it keeps.
/// - `prepare()` captures nothing, sends nothing, and may be called any number of times.
/// - `onEvent` calls are serialized with the sink calls (same context, never concurrent).
/// - `stop()` delivers every complete sample already captured, returns only after the last sink
///   call has returned, and no sink or event call happens after it returns.
/// - `stop()` on a capture that is not running returns empty stats and does nothing else.
/// - `.failed` arrives at most once per `start`, after the last sink call of that run.
public protocol AudioCapture: AnyObject, Sendable {
    /// Mean square of the latest buffer (samples scaled to -1...1), for the level meter. Safe from any thread.
    var meanSquare: Float { get }

    /// Readies the capture so the first take's audio arrives sooner. Writes nothing and does not
    /// start the microphone.
    func prepare()

    func start(sink: @escaping CaptureSink, onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws

    func stop() -> CaptureStats
}
