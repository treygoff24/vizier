#if canImport(AVFoundation)
import AVFoundation
import Foundation

extension TakeStore {
    public static let recordingSettings: [String: any Sendable] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    /// Apple's FLAC encoder writes an empty, unreadable file (a 42-byte header) for anything
    /// shorter than one 4,608-frame block, and reports no error (measured on macOS 27). A take
    /// shorter than that, such as an accidental double tap, gets trailing silence up to one block.
    public static let minimumFLACFrames: AVAudioFramePosition = 4_608

    public static let flacSettings: [String: any Sendable] = [
        AVFormatIDKey: kAudioFormatFLAC,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitDepthHintKey: 16,
    ]

    /// Opens the take's recording file for writing, readable by this user only.
    public static func createRecording(_ take: TakeFiles) throws -> AVAudioFile {
        let file = try AVAudioFile(forWriting: take.recording, settings: recordingSettings, commonFormat: .pcmFormatInt16, interleaved: true)
        try PrivateFiles.restrict(take.recording)
        return file
    }

    /// The take's recording as the neutral `RecordingFile` the recorder writes through.
    public static func createRecordingFile(_ take: TakeFiles) throws -> any RecordingFile {
        CAFRecordingFile(try createRecording(take))
    }

    /// The audio's length from its header, or nil when the header can't be read.
    public static func duration(of audio: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: audio), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Encodes a closed recording to FLAC, checks the FLAC holds every frame, then removes the
    /// recording. On any failure the recording stays, so the audio is never lost.
    @discardableResult
    public func finishAudio(_ take: TakeFiles) throws -> URL {
        _ = try encodeFLAC(from: take.recording, to: take)
        try FileManager.default.removeItem(at: take.recording)
        return take.flac
    }

    /// Encodes another app's 16-bit mono recording (a WAV, say) to the take's FLAC and checks it
    /// holds every frame. The source is only read, never moved or removed. Returns the FLAC's
    /// frame count.
    @discardableResult
    public func importAudio(from source: URL, to take: TakeFiles) throws -> AVAudioFramePosition {
        try encodeFLAC(from: source, to: take)
    }

    private func encodeFLAC(from url: URL, to take: TakeFiles) throws -> AVAudioFramePosition {
        let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let expected = source.length
        if FileManager.default.fileExists(atPath: take.flac.path) {
            try FileManager.default.removeItem(at: take.flac)
        }
        let flac = try AVAudioFile(forWriting: take.flac, settings: Self.flacSettings, commonFormat: .pcmFormatInt16, interleaved: true)
        try PrivateFiles.restrict(take.flac)
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_000)!
        while source.framePosition < expected {
            try source.read(into: buffer, frameCount: min(16_000, AVAudioFrameCount(expected - source.framePosition)))
            if buffer.frameLength == 0 { break }
            try flac.write(from: buffer)
        }
        if expected < Self.minimumFLACFrames {
            let silence = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(Self.minimumFLACFrames))!
            silence.frameLength = AVAudioFrameCount(Self.minimumFLACFrames - expected)
            memset(silence.int16ChannelData![0], 0, Int(silence.frameLength) * MemoryLayout<Int16>.size)
            try flac.write(from: silence)
        }
        flac.close()
        source.close()

        let check = try AVAudioFile(forReading: take.flac)
        let stored = max(expected, Self.minimumFLACFrames)
        guard check.length == stored else {
            throw TakeStoreError.frameCountMismatch(expected: stored, found: check.length)
        }
        return stored
    }
}

/// The CAF recording: `AVAudioFile` behind the neutral `RecordingFile`.
public final class CAFRecordingFile: RecordingFile, @unchecked Sendable {
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?

    init(_ file: AVAudioFile) {
        self.file = file
    }

    public func append(_ samples: UnsafeBufferPointer<Int16>) throws {
        guard let file else { throw AudioFileError.closed }
        guard !samples.isEmpty else { return }
        if buffer == nil || buffer!.frameCapacity < AVAudioFrameCount(samples.count) {
            buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(samples.count, 4_096)))
        }
        guard let buffer, let destination = buffer.int16ChannelData?[0] else { throw AudioFileError.invalidFormat }
        destination.update(from: samples.baseAddress!, count: samples.count)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    public func close() throws {
        file?.close()
        file = nil
    }
}
#endif
