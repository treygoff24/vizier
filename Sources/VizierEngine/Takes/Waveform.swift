#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation

/// The History waveform: a take's audio reduced to a fixed number of bars, each the loudness (RMS)
/// of its slice scaled against the loudest slice, so a quiet mic still shows the shape of speech.
/// A take that never rises above `silenceFloor` is all zeros, which draws as the bare midline.
public enum Waveform {
    /// About -50 dBFS. Below this everywhere, the take is treated as silence.
    public static let silenceFloor: Float = 0.003

    #if canImport(AVFoundation)
    /// Reads the whole file off the main thread's hands: call it from a background task.
    public static func bars(of url: URL, count: Int = 64) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(file.length)
        guard count > 0, frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            return Array(repeating: 0, count: max(count, 0))
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return Array(repeating: 0, count: count) }
        return bars(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)), count: count)
    }
    #endif

    public static func bars(_ samples: UnsafeBufferPointer<Float>, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var rms = [Float](repeating: 0, count: count)
        guard !samples.isEmpty else { return rms }
        for bar in 0..<count {
            let start = samples.count * bar / count
            let end = max(start + 1, samples.count * (bar + 1) / count)
            guard start < samples.count else { break }
            var sum: Float = 0
            for index in start..<min(end, samples.count) { sum += samples[index] * samples[index] }
            rms[bar] = (sum / Float(min(end, samples.count) - start)).squareRoot()
        }
        let loudest = rms.max() ?? 0
        guard loudest >= silenceFloor else { return Array(repeating: 0, count: count) }
        return rms.map { $0 / loudest }
    }
}
