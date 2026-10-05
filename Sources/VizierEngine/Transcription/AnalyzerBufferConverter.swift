#if canImport(Speech)
@preconcurrency import AVFoundation
import Foundation
import Speech

/// Converts capture audio into the format a `SpeechAnalyzer`'s modules accept, one `AnalyzerInput`
/// per buffer. macOS 27 ships `AnalyzerInputConverter` for this; macOS 26 only reports the format it
/// wants (`SpeechAnalyzer.bestAvailableAudioFormat`), so this does the conversion with
/// `AVAudioConverter`. Same shape as Apple's: `convert` for each buffer, `flush` once at the end to
/// drain what a sample-rate change held back. Every input carries `bufferStartTime`, the running
/// count of output frames so far, as Apple's converter does. A converter serves one stream; after
/// `flush` it is reset, so it would start a fresh stream if fed again.
final class AnalyzerBufferConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    /// Nil when the formats already match and buffers pass through untouched.
    private let converter: AVAudioConverter?
    /// Output frames handed out so far; the next input starts at this many frames.
    private var framesOut: Int64 = 0

    enum Failure: Error, CustomStringConvertible {
        case noCompatibleFormat
        case cannotConvert(from: AVAudioFormat, to: AVAudioFormat)
        case conversionFailed(String)

        var description: String {
            switch self {
            case .noCompatibleFormat: "Apple speech reported no audio format it can analyze"
            case .cannotConvert(let from, let to): "no audio converter from \(from) to \(to)"
            case .conversionFailed(let reason): "audio conversion failed: \(reason)"
            }
        }
    }

    /// The converter from `input` to whatever `modules` can analyze.
    static func converter(from input: AVAudioFormat, compatibleWith modules: [any SpeechModule]) async throws -> AnalyzerBufferConverter {
        guard let output = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: input) else {
            throw Failure.noCompatibleFormat
        }
        return try AnalyzerBufferConverter(from: input, to: output)
    }

    init(from input: AVAudioFormat, to output: AVAudioFormat) throws {
        // `AnalyzerInput(buffer:)` traps on anything but 16-bit integers on macOS 27, so refuse here
        // and let the take fail with a message instead of crashing the app.
        guard output.commonFormat == .pcmFormatInt16, output.channelCount == 1 else {
            throw Failure.cannotConvert(from: input, to: output)
        }
        inputFormat = input
        outputFormat = output
        if input == output {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: input, to: output) else {
                throw Failure.cannotConvert(from: input, to: output)
            }
            self.converter = converter
        }
    }

    /// The analyzer inputs for one capture buffer: none when a rate change holds every frame back.
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        guard let converter else { return [stamped(buffer)] }
        let scale = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * scale).rounded(.up)) + 64
        return try drain(converter, capacity: capacity, feeding: buffer)
    }

    /// The inputs for the frames the converter still holds; call once after the last buffer.
    func flush() throws -> [AnalyzerInput] {
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(outputFormat.sampleRate.rounded(.up))
        let inputs = try drain(converter, capacity: capacity, feeding: nil)
        converter.reset()
        return inputs
    }

    /// `buffer` as an analyzer input starting where the previous one ended.
    private func stamped(_ buffer: AVAudioPCMBuffer) -> AnalyzerInput {
        let start = CMTime(value: framesOut, timescale: CMTimeScale(outputFormat.sampleRate))
        framesOut += Int64(buffer.frameLength)
        return AnalyzerInput(buffer: buffer, bufferStartTime: start)
    }

    /// Runs the converter until it wants more input. `buffer` is offered once; nil means the end of
    /// the stream, which makes the converter release the frames it was holding for the resampler.
    private func drain(_ converter: AVAudioConverter, capacity: AVAudioFrameCount, feeding buffer: AVAudioPCMBuffer?) throws -> [AnalyzerInput] {
        var inputs: [AnalyzerInput] = []
        nonisolated(unsafe) var offered = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(capacity, 1)) else {
                throw Failure.conversionFailed("could not allocate an output buffer")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if let buffer, !offered {
                    offered = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                outStatus.pointee = buffer == nil ? .endOfStream : .noDataNow
                return nil
            }
            if output.frameLength > 0 { inputs.append(stamped(output)) }
            switch status {
            case .error: throw Failure.conversionFailed(error?.localizedDescription ?? "unknown")
            case .haveData: continue
            case .inputRanDry, .endOfStream: return inputs
            @unknown default: return inputs
            }
        }
    }
}
#endif
