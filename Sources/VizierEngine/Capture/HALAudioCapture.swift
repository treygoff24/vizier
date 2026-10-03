#if canImport(AudioToolbox)
import AVFoundation
import Foundation

/// `HALCapture` as an `AudioCapture`: hands the neutral Int16 sink the samples of each converted
/// buffer. `HALCapture`'s own API is unchanged; the app's level meter and device lookups still use it.
public final class HALAudioCapture: AudioCapture, @unchecked Sendable {
    public let hal: HALCapture
    /// HALCapture delivers audio and `.signal` on its processing queue and device events on its
    /// control queue. Both are forwarded through this one serial queue, synchronously, so the sink and
    /// the event handler never overlap (the AudioCapture guarantee) and the buffer stays valid.
    private let delivery = DispatchQueue(label: "net.praxient.dictum.capture.delivery", qos: .userInteractive)

    public init(hal: HALCapture = HALCapture()) {
        self.hal = hal
    }

    public var meanSquare: Float { hal.meanSquare }

    public func prepare() { hal.prepare() }

    public func start(sink: @escaping CaptureSink, onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws {
        let delivery = delivery
        try hal.start(sink: { buffer in
            delivery.sync {
                guard let samples = buffer.int16ChannelData?[0] else { return }
                sink(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            }
        }, onEvent: { event in
            delivery.sync { onEvent(event) }
        })
    }

    public func stop() -> CaptureStats { hal.stop() }
}
#endif
