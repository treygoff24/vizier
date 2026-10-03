#if !canImport(AVFoundation)
import Foundation

/// The take audio path where AVFoundation does not exist: WAV recordings, the pure-Swift FLAC encoder.
extension TakeStore {
    /// Opens the take's recording (`<id>.wav`) for writing, readable by this user only from its first byte.
    public static func createRecordingFile(_ take: TakeFiles) throws -> any RecordingFile {
        try WAVRecordingFile(url: take.recording)
    }

    /// The audio's length from its header, or nil when the header can't be read: a FLAC's from its
    /// STREAMINFO, a WAV's from its data length.
    public static func duration(of audio: URL) -> Double? {
        if let seconds = FLACInfo.duration(audio) { return seconds }
        // A WAV recording: its data after the 44-byte header, without reading the samples.
        guard audio.pathExtension == "wav",
              let size = (try? FileManager.default.attributesOfItem(atPath: audio.path))?[.size] as? Int, size >= 44
        else { return nil }
        return Double((size - 44) / 2) / 16_000
    }

    /// Encodes a closed recording to FLAC, checks the FLAC holds every frame, then removes the
    /// recording. On any failure the recording stays, so the audio is never lost.
    @discardableResult
    public func finishAudio(_ take: TakeFiles) throws -> URL {
        try finishAudio(take, encoder: { try FLACEncoder.encode(wav: $0, to: $1) })
    }

    /// `finishAudio` with the encoder swapped (a test's, to make the frame check fail).
    func finishAudio(_ take: TakeFiles, encoder: (URL, URL) throws -> Int64) throws -> URL {
        _ = try encodeFLAC(from: take.recording, to: take, encoder: encoder)
        try FileManager.default.removeItem(at: take.recording)
        return take.flac
    }

    /// Encodes a 16 kHz mono WAV to the take's FLAC and checks it holds every frame. The source is
    /// only read. Returns the FLAC's frame count.
    @discardableResult
    public func importAudio(from source: URL, to take: TakeFiles) throws -> Int64 {
        try encodeFLAC(from: source, to: take, encoder: { try FLACEncoder.encode(wav: $0, to: $1) })
    }

    private func encodeFLAC(from url: URL, to take: TakeFiles, encoder: (URL, URL) throws -> Int64) throws -> Int64 {
        let expected: Int64
        do {
            try? FileManager.default.removeItem(at: take.flac)
            // A crash mid-encode leaves `<id>.flac.partial`; it is unverified, and the encoder
            // refuses to overwrite it, so it goes before the next attempt.
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: take.flac.path + ".partial"))
            // The expected count comes from the WAV itself, not from the encoder being checked.
            expected = try WAVFile.sampleCount(url)
            _ = try encoder(url, take.flac)
            try PrivateFiles.restrict(take.flac)
            guard let info = FLACInfo.streamInfo(take.flac), info.sampleRate == 16_000, info.totalSamples == expected else {
                throw TakeStoreError.frameCountMismatch(expected: expected, found: FLACInfo.streamInfo(take.flac)?.totalSamples ?? -1)
            }
        } catch {
            // An unverified FLAC would outrank nothing and mislead everything: keep only the source.
            try? FileManager.default.removeItem(at: take.flac)
            throw error
        }
        return expected
    }
}

#endif
