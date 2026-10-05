#if canImport(Speech)
import AVFoundation
import Speech
import Testing
@testable import VizierEngine

/// The converter between capture audio and what SpeechAnalyzer takes, on synthetic sine buffers.
/// Outputs are 16-bit mono because macOS 27's `AnalyzerInput(buffer:)` traps on anything else.
@Suite struct AnalyzerBufferConverterTests {
    private static let chunks: [AVAudioFrameCount] = [1600, 333, 4096, 1, 160]

    private static func int16(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
    }

    /// A 440 Hz sine at half scale, continuing from `start` so chunks join without a seam.
    private static func sine(_ format: AVAudioFormat, frames: AVAudioFrameCount, start: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.int16ChannelData![0][i] = Int16(16384 * sin(2 * .pi * 440 * Double(start + i) / format.sampleRate))
        }
        return buffer
    }

    private static func samples(_ inputs: [AnalyzerInput]) -> [Int16] {
        inputs.flatMap { input in
            let b = input.buffer
            return Array(UnsafeBufferPointer(start: b.int16ChannelData![0], count: Int(b.frameLength)))
        }
    }

    /// Feeds `sizes` through a fresh converter; returns the inputs before flush and the flush's.
    private static func run(_ from: AVAudioFormat, _ to: AVAudioFormat, _ sizes: [AVAudioFrameCount]) throws -> (body: [AnalyzerInput], flush: [AnalyzerInput]) {
        let converter = try AnalyzerBufferConverter(from: from, to: to)
        var body: [AnalyzerInput] = [], start = 0
        for size in sizes {
            body += try converter.convert(sine(from, frames: size, start: start))
            start += Int(size)
        }
        return (body, try converter.flush())
    }

    @Test func matchingFormatsPassEveryBufferThroughUnchanged() throws {
        let format = Self.int16(16_000)
        let (body, flush) = try Self.run(format, format, Self.chunks)
        #expect(body.map(\.buffer.frameLength) == Self.chunks)
        #expect(flush.isEmpty)
        var start = 0, expected: [Int16] = []
        for size in Self.chunks {
            let b = Self.sine(format, frames: size, start: start)
            expected += UnsafeBufferPointer(start: b.int16ChannelData![0], count: Int(size))
            start += Int(size)
        }
        #expect(Self.samples(body) == expected)
    }

    @Test func upsamplingKeepsEveryFrameAndFlushReleasesTheTail() throws {
        let input = Self.chunks.reduce(0, +)
        let (body, flush) = try Self.run(Self.int16(16_000), Self.int16(48_000), Self.chunks)
        let total = (body + flush).reduce(0) { $0 + Int($1.buffer.frameLength) }
        #expect(abs(total - 3 * Int(input)) <= 2, "\(total) frames for \(input) in")
        #expect(!flush.isEmpty, "the resampler's held frames come out at flush")
        #expect((body + flush).allSatisfy { $0.buffer.frameLength > 0 }, "no empty input is sent")
    }

    @Test func downsamplingKeepsLengthAndLevel() throws {
        let sizes: [AVAudioFrameCount] = [4800, 999, 12288, 3, 480]
        let input = sizes.reduce(0, +)
        let (body, flush) = try Self.run(Self.int16(48_000), Self.int16(16_000), sizes)
        let out = Self.samples(body + flush)
        #expect(abs(out.count - Int(input) / 3) <= 2, "\(out.count) frames for \(input) in")
        let peak = out.map { abs(Int($0)) }.max() ?? 0
        #expect(abs(peak - 16384) <= 400, "peak \(peak)")
    }

    @Test func chunkBoundariesDoNotChangeTheOutput() throws {
        let whole = try Self.run(Self.int16(16_000), Self.int16(44_100), [Self.chunks.reduce(0, +)])
        let split = try Self.run(Self.int16(16_000), Self.int16(44_100), Self.chunks)
        let a = Self.samples(whole.body + whole.flush), b = Self.samples(split.body + split.flush)
        #expect(!a.isEmpty && a.count == b.count, "\(a.count) vs \(b.count)")
        #expect(zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

    @Test func everyInputStartsWhereThePreviousOneEnded() throws {
        for (from, to) in [(Self.int16(16_000), Self.int16(16_000)), (Self.int16(16_000), Self.int16(44_100))] {
            let (body, flush) = try Self.run(from, to, Self.chunks)
            let inputs = body + flush
            var expected: Int64 = 0
            for input in inputs {
                let start = try #require(input.bufferStartTime, "an input has no start time")
                #expect(start == CMTime(value: expected, timescale: CMTimeScale(to.sampleRate)))
                expected += Int64(input.buffer.frameLength)
            }
            #expect(inputs.count >= Self.chunks.count - 1)
        }
    }

    @Test func anOutputThatIsNotSixteenBitMonoIsRefused() {
        let float = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: true)!
        let stereo = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 2, interleaved: true)!
        let mono = Self.int16(16_000)
        for output in [float, stereo] {
            #expect(throws: AnalyzerBufferConverter.Failure.self) { try AnalyzerBufferConverter(from: mono, to: output) }
        }
        // The same format on both sides is refused too: passthrough would hand it to the analyzer.
        #expect(throws: AnalyzerBufferConverter.Failure.self) { try AnalyzerBufferConverter(from: float, to: float) }
    }

    @Test func aConverterKeepsWorkingAfterFlush() throws {
        let from = Self.int16(16_000), to = Self.int16(44_100)
        let converter = try AnalyzerBufferConverter(from: from, to: to)
        for size in Self.chunks { _ = try converter.convert(Self.sine(from, frames: size, start: 0)) }
        _ = try converter.flush()
        let after = try converter.convert(Self.sine(from, frames: 1600, start: 0)) + converter.flush()
        let total = after.reduce(0) { $0 + Int($1.buffer.frameLength) }
        #expect(abs(total - 4410) <= 2, "\(total) frames after flush")
    }
}
#endif
