import AVFoundation
import Foundation
import Synchronization

/// Captures one take at a time: every sample goes to the take's recording file on disk first,
/// then out in 100 ms chunks for a live transcriber.
public final class TakeRecorder: @unchecked Sendable {
    public struct Summary: Sendable {
        public var frames: Int64
        public var capture: HALCapture.Stats
        /// Set when a write to the recording file failed. Earlier audio is still on disk.
        public var writeError: String?
        public var seconds: Double { Double(frames) / 16_000 }
    }

    /// 100 ms of 16 kHz 16-bit mono.
    public static let chunkBytes = 3_200

    public let capture = HALCapture()
    private let framesCaptured = Atomic<Int64>(0)

    // Touched on the capture's processing queue while running, and by start/stop otherwise.
    private var file: AVAudioFile?
    private var pending = Data()
    private var onChunk: (@Sendable (Data) -> Void)?
    private var writeError: String?

    public init() {}

    /// Captured audio so far, in seconds. This is the strip's timer: time captured, not time elapsed.
    public var capturedSeconds: Double { Double(framesCaptured.load(ordering: .relaxed)) / 16_000 }

    /// Readies the capture unit so the first take's audio arrives sooner. Writes nothing, sends
    /// nothing, and does not start the microphone. Call only once mic access is granted.
    public func warmUp() {
        capture.prepare()
    }

    public func start(
        _ take: TakeFiles,
        onChunk: @escaping @Sendable (Data) -> Void,
        onEvent: @escaping @Sendable (HALCapture.Event) -> Void
    ) throws {
        file = try TakeStore.createRecording(take)
        pending = Data()
        pending.reserveCapacity(Self.chunkBytes * 2)
        writeError = nil
        framesCaptured.store(0, ordering: .relaxed)
        self.onChunk = onChunk
        do {
            try capture.start(sink: { [unowned self] buffer in self.receive(buffer) }, onEvent: onEvent)
        } catch {
            file?.close()
            file = nil
            throw error
        }
    }

    /// Stops capture, delivers the last partial chunk, and closes the recording file.
    public func stop() -> Summary {
        let stats = capture.stop()
        if !pending.isEmpty { onChunk?(pending) }
        pending = Data()
        file?.close()
        file = nil
        onChunk = nil
        return Summary(frames: framesCaptured.load(ordering: .relaxed), capture: stats, writeError: writeError)
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        if let file, writeError == nil {
            do { try file.write(from: buffer) } catch { writeError = String(describing: error) }
        }
        framesCaptured.wrappingAdd(Int64(buffer.frameLength), ordering: .relaxed)
        guard let samples = buffer.int16ChannelData?[0] else { return }
        pending.append(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        while pending.count >= Self.chunkBytes {
            onChunk?(Data(pending.prefix(Self.chunkBytes)))
            pending.removeFirst(Self.chunkBytes)
        }
    }
}
