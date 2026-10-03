import Foundation
import Synchronization

/// Captures one take at a time: every sample goes to the take's recording file on disk first,
/// then out in 100 ms chunks for a live transcriber.
public final class TakeRecorder: @unchecked Sendable {
    public struct Summary: Sendable {
        public var frames: Int64
        public var capture: CaptureStats
        /// Set when a write to the recording file, or closing it, failed. Earlier audio is still on disk.
        public var writeError: String?
        public var seconds: Double { Double(frames) / 16_000 }
    }

    /// 100 ms of 16 kHz 16-bit mono.
    public static let chunkBytes = 3_200

    public let capture: any AudioCapture
    private let framesCaptured = Atomic<Int64>(0)

    // Touched on the capture's delivery context while running, and by start/stop otherwise.
    private var file: (any RecordingFile)?
    private var pending = Data()
    private var onChunk: (@Sendable (Data) -> Void)?
    private var writeError: String?

    private let recordingFactory: @Sendable (TakeFiles) throws -> any RecordingFile

    public init(capture: any AudioCapture) {
        self.capture = capture
        recordingFactory = { try TakeStore.createRecordingFile($0) }
    }

    /// For tests: a recording file the test controls.
    init(capture: any AudioCapture, recordingFactory: @escaping @Sendable (TakeFiles) throws -> any RecordingFile) {
        self.capture = capture
        self.recordingFactory = recordingFactory
    }

    #if canImport(AudioToolbox)
    public convenience init() {
        self.init(capture: HALAudioCapture())
    }
    #endif

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
        onEvent: @escaping @Sendable (CaptureEvent) -> Void
    ) throws {
        file = try recordingFactory(take)
        pending = Data()
        pending.reserveCapacity(Self.chunkBytes * 2)
        writeError = nil
        framesCaptured.store(0, ordering: .relaxed)
        self.onChunk = onChunk
        do {
            try capture.start(sink: { [unowned self] samples in self.receive(samples) }, onEvent: onEvent)
        } catch {
            try? file?.close()
            file = nil
            throw error
        }
    }

    /// Stops capture, delivers the last partial chunk, and closes the recording file. A failure to
    /// close lands in `Summary.writeError`; the recording stays on disk either way.
    public func stop() -> Summary {
        let stats = capture.stop()
        if !pending.isEmpty { onChunk?(pending) }
        pending = Data()
        do { try file?.close() } catch {
            if writeError == nil { writeError = "closing the recording failed: \(error)" }
        }
        file = nil
        onChunk = nil
        return Summary(frames: framesCaptured.load(ordering: .relaxed), capture: stats, writeError: writeError)
    }

    private func receive(_ samples: UnsafeBufferPointer<Int16>) {
        if let file, writeError == nil {
            do { try file.append(samples) } catch { writeError = String(describing: error) }
        }
        framesCaptured.wrappingAdd(Int64(samples.count), ordering: .relaxed)
        pending.append(samples)
        while pending.count >= Self.chunkBytes {
            onChunk?(Data(pending.prefix(Self.chunkBytes)))
            pending.removeFirst(Self.chunkBytes)
        }
    }
}
