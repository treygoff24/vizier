import Foundation

/// The file a take's samples go to while recording: 16 kHz mono signed 16-bit, readable after a
/// crash (CAF on macOS, WAV elsewhere).
public protocol RecordingFile: AnyObject, Sendable {
    /// Appends samples. Callers serialize `append` and `close`.
    func append(_ samples: UnsafeBufferPointer<Int16>) throws
    /// Finishes the file. Safe to call again after it has returned; a call after a throw may throw again.
    func close() throws
}

/// The WAV recording: `WAVWriter`, created 0600 before any sample is written.
public final class WAVRecordingFile: RecordingFile, @unchecked Sendable {
    private let writer: WAVWriter

    public init(url: URL) throws {
        // WAVWriter creates the file exclusively at 0600 before its first byte, whatever the umask.
        writer = try WAVWriter(url: url)
    }

    public func append(_ samples: UnsafeBufferPointer<Int16>) throws { try writer.append(samples) }

    public func close() throws { try writer.close() }
}
