import AVFoundation
import Foundation

/// The files of one take. The id doubles as the future history row's key, so the history lane
/// can adopt these files without renaming them: one FLAC per take, named by its UTC start time.
public struct TakeFiles: Sendable, Equatable {
    public let id: String
    public let directory: URL

    /// Written while recording. It survives a crash readable, which FLAC does not (an unclosed FLAC
    /// has an empty stream header), so a take becomes FLAC only once its recording is closed.
    public var recording: URL { directory.appending(path: id + ".caf") }
    public var flac: URL { directory.appending(path: id + ".flac") }
}

public enum TakeStoreError: Error, CustomStringConvertible {
    case frameCountMismatch(expected: AVAudioFramePosition, found: AVAudioFramePosition)

    public var description: String {
        switch self {
        case .frameCountMismatch(let expected, let found): "FLAC holds \(found) frames, recording holds \(expected)"
        }
    }
}

/// Where takes live: `<root>/<yyyy-MM>/<id>.flac`, with the id a UTC timestamp to the millisecond.
public struct TakeStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let standard = TakeStore(
        root: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Vizier/Takes"))

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

    public func newTake(startedAt date: Date = .now) throws -> TakeFiles {
        try files(forID: Self.takeID(date))
    }

    /// A take's id: its UTC start time to the millisecond, `2026-09-25T22-35-49.202Z`.
    public static func takeID(_ date: Date) -> String {
        let utc = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let millis = Int(date.timeIntervalSince1970 * 1000) % 1000
        return String(format: "%04d-%02d-%02dT%02d-%02d-%02d.%03dZ", utc.year!, utc.month!, utc.day!, utc.hour!, utc.minute!, utc.second!, millis)
    }

    /// The files for a take id, in its month's folder, which this creates. The takes folder and
    /// the month folder are 0700 (`PrivateFiles`).
    public func files(forID id: String) throws -> TakeFiles {
        let directory = root.appending(path: String(id.prefix(7)), directoryHint: .isDirectory)
        try PrivateFiles.makeDirectory(directory)
        PrivateFiles.tighten(root)
        return TakeFiles(id: id, directory: directory)
    }

    /// Opens the take's recording file for writing, readable by this user only.
    public static func createRecording(_ take: TakeFiles) throws -> AVAudioFile {
        let file = try AVAudioFile(forWriting: take.recording, settings: recordingSettings, commonFormat: .pcmFormatInt16, interleaved: true)
        try PrivateFiles.restrict(take.recording)
        return file
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

    /// Recordings left behind by a crash or a failed encode, oldest first.
    public func unfinishedTakes() -> [TakeFiles] {
        let fm = FileManager.default
        guard let months = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return months.flatMap { month -> [TakeFiles] in
            let files = (try? fm.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "caf" }
                .map { TakeFiles(id: $0.deletingPathExtension().lastPathComponent, directory: month) }
        }
        .sorted { $0.id < $1.id }
    }
}
