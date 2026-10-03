import Foundation
#if os(Linux)
import Glibc
#endif
import Testing
@testable import VizierEngine

struct AudioFileTests {
    private static var ffmpeg: URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = paths.map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") }
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ffmpeg")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func temporary(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func wavRoundTrip() throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("take.wav")
            let input: [Int16] = [.min, -123, 0, 123, .max]
            let writer = try WAVWriter(url: url)
            try input.prefix(2).withUnsafeBufferPointer { try writer.append($0) }
            try Array(input.dropFirst(2)).withUnsafeBufferPointer { try writer.append($0) }
            #expect(try writer.close() == 5)
            #expect(try writer.close() == 5)
            #expect(try WAVFile.samples(url) == input)
            let bytes = try Data(contentsOf: url)
            #expect(bytes.integer(at: 4, bytes: 4, littleEndian: true) == 46)
            #expect(bytes.integer(at: 40, bytes: 4, littleEndian: true) == 10)
            #expect(bytes.integer(at: 24, bytes: 4, littleEndian: true) == 16000)
            #expect(throws: AudioFileError.closed) {
                try input.withUnsafeBufferPointer { try writer.append($0) }
            }
        }
    }

    @Test(arguments: [UInt32(0), UInt32.max]) func unpatchedWAV(size: UInt32) throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("crash.wav")
            let input: [Int16] = [.min, 0, .max]
            do {
                let writer = try WAVWriter(url: url)
                try input.withUnsafeBufferPointer { try writer.append($0) }
                // Deinitialization closes the descriptor but deliberately does not patch the header.
            }
            var bytes = try Data(contentsOf: url)
            var field = Data()
            field.appendLE(UInt64(size), bytes: 4)
            bytes.replaceSubrange(40..<44, with: field)
            bytes.append(0xab) // A crashed write may leave half of the final sample.
            try bytes.write(to: url)
            #expect(try WAVFile.samples(url) == input)
        }
    }

    @Test func malformedWAV() throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("bad.wav")
            try Data("garbage".utf8).write(to: url)
            #expect(throws: AudioFileError.invalidFormat) { try WAVFile.samples(url) }
            try FileManager.default.removeItem(at: url)
            let writer = try WAVWriter(url: url)
            try [Int16(1)].withUnsafeBufferPointer { try writer.append($0) }
            try writer.close()
            let original = try Data(contentsOf: url)
            for length in 0..<original.count {
                try original.prefix(length).write(to: url)
                #expect(throws: AudioFileError.invalidFormat) { try WAVFile.samples(url) }
            }
            var stereo = original
            stereo[22] = 2
            try stereo.write(to: url)
            #expect(throws: AudioFileError.invalidFormat) { try WAVFile.samples(url) }
        }
    }

    private func signal(_ kind: String) -> [Int16] {
        switch kind {
        case "silence": return [Int16](repeating: 0, count: 8192)
        case "sine": return (0..<8192).map { Int16(28000 * sin(Double($0) * 2 * .pi * 440 / 16000)) }
        case "noise":
            var seed: UInt64 = 12345
            var samples: [Int16] = [.min, .max]
            for _ in 0..<8190 {
                seed = seed &* 6364136223846793005 &+ 1
                samples.append(Int16(bitPattern: UInt16(truncatingIfNeeded: seed >> 32)))
            }
            return samples
        case "partial": return (0..<4127).map { Int16(($0 % 2000) - 1000) }
        case "escape":
            var seed: UInt64 = 54321
            return (0..<4096).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return Int16(Int((seed >> 32) & 255) - 128)
            }
        case "one": return [.min]
        case "long": return [Int16](repeating: 42, count: 4096 * 129 + 1)
        default: return []
        }
    }

    /// CI sets VIZIER_REQUIRE_FFMPEG so this independent decode can never skip there (plan A9).
    private static var ffmpegRequired: Bool { ProcessInfo.processInfo.environment["VIZIER_REQUIRE_FFMPEG"] != nil }

    @Test(.enabled(if: Self.ffmpeg != nil || Self.ffmpegRequired, "Skipped: ffmpeg is absent from PATH and ~/.local/bin/ffmpeg"),
          arguments: ["silence", "sine", "noise", "partial", "one", "zero", "long", "escape"])
    func flacRoundTrip(kind: String) throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("take.flac")
            let input = signal(kind)
            #expect(try FLACEncoder.encode(input, sampleRate: 16000, to: url) == Int64(input.count))
            try expectDecoded(url, equals: input, in: directory)
            #expect(FLACInfo.streamInfo(url)?.totalSamples == Int64(input.count))
            #expect(FLACInfo.streamInfo(url)?.sampleRate == 16000)
            let header = try Data(contentsOf: url)
            if kind == "escape" {
                #expect(header[50] == 16) // Fixed predictor order 0.
                #expect(header[51] == 3 && header[52] >> 6 == 3) // Rice escape parameter 15.
            }
            #expect(header.prefix(4) == Data("fLaC".utf8))
            #expect(header[4] == 0x80)
            #expect(header.integer(at: 8, bytes: 2) == 4096)
            #expect(header.integer(at: 10, bytes: 2) == 4096)
        }
    }

    private func decode(_ url: URL, in directory: URL) throws -> (bytes: Data, status: Int32, diagnostics: Data) {
        let process = Process()
        let executable: URL = try #require(Self.ffmpeg)
        process.executableURL = executable
        process.arguments = ["-v", "error", "-err_detect", "crccheck+explode", "-xerror", "-i", url.path,
                             "-f", "s16le", "-ac", "1", "-ar", "16000", "-"]
        let output = Pipe()
        let errorURL = directory.appendingPathComponent("decoder-errors")
        try Data().write(to: errorURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (bytes, process.terminationStatus, try Data(contentsOf: errorURL))
    }

    private func expectDecoded(_ url: URL, equals input: [Int16], in directory: URL) throws {
        let result = try decode(url, in: directory)
        if !input.isEmpty { // Empty FLAC has no audio frames for ffmpeg to decode.
            #expect(result.status == 0)
            #expect(result.diagnostics.isEmpty)
        }
        var expected = Data()
        for value in input { expected.appendLE(UInt64(UInt16(bitPattern: value)), bytes: 2) }
        #expect(result.bytes == expected)
    }

    @Test(arguments: [UInt64(127), 128, 2047, 2048, 65535, 65536, 14062])
    func frameNumberCoding(number: UInt64) {
        let vectors: [UInt64: [UInt8]] = [127: [0x7f], 128: [0xc2, 0x80], 2047: [0xdf, 0xbf],
            2048: [0xe0, 0xa0, 0x80], 65535: [0xef, 0xbf, 0xbf], 65536: [0xf0, 0x90, 0x80, 0x80],
            14062: [0xe3, 0x9b, 0xae]] // RFC 9639 section 9.1.5 UTF-8 coding.
        #expect(FLACEncoder.codedNumber(number) == vectors[number])
    }

    @Test(.enabled(if: Self.ffmpeg != nil || Self.ffmpegRequired, "Skipped: ffmpeg is absent"),
          arguments: [0, 1, 2, 3, 4], [14, 15])
    func forcedPredictors(order: Int, parameter: Int) throws {
        try temporary { directory in
            let input: [Int16] = (0..<4096).map { $0 % 2 == 0 ? .min : .max }
            let url = directory.appendingPathComponent("forced.flac")
            try FLACEncoder.encode(input, sampleRate: 16000, to: url)
            var data = try Data(contentsOf: url).prefix(42)
            let subframe = FLACEncoder.subframe(input.map(Int64.init), order: order, riceParameter: parameter)
            #expect(subframe[0] == UInt8((8 + order) << 1))
            let residualHeader = 1 + order * 2
            #expect(subframe[residualHeader] & 3 == UInt8(parameter >> 2))
            #expect(subframe[residualHeader + 1] >> 6 == UInt8(parameter & 3))
            data.append(FLACEncoder.frame(input.map(Int64.init), number: 0, sampleRate: 16000,
                                          order: order, riceParameter: parameter))
            try data.write(to: url)
            try expectDecoded(url, equals: input, in: directory)
        }
    }

    @Test(.enabled(if: Self.ffmpeg != nil || Self.ffmpegRequired, "Skipped: ffmpeg is absent"))
    func decoderRejectsCRC() throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("crc.flac")
            try FLACEncoder.encode([1, 2, 3], sampleRate: 16000, to: url)
            var data = try Data(contentsOf: url)
            data[data.count - 1] ^= 1
            try data.write(to: url)
            let result = try decode(url, in: directory)
            #expect(result.status != 0)
            #expect(!result.diagnostics.isEmpty)
        }
    }

    @Test(.enabled(if: Self.ffmpeg != nil || Self.ffmpegRequired, "Skipped: ffmpeg is absent"),
          arguments: [UInt32(0), UInt32.max, UInt32(8254)])
    func streamingWAV(size: UInt32) throws {
        try temporary { directory in
            let wav = directory.appendingPathComponent("input.wav")
            let flac = directory.appendingPathComponent("output.flac")
            let input = signal("partial")
            let writer = try WAVWriter(url: wav)
            try input.withUnsafeBufferPointer { try writer.append($0) }
            try writer.close()
            var data = try Data(contentsOf: wav)
            var field = Data()
            field.appendLE(UInt64(size), bytes: 4)
            data.replaceSubrange(40..<44, with: field)
            if size != 8254 { data.append(0xff) }
            try data.write(to: wav)
            #expect(try FLACEncoder.encode(wav: wav, to: flac) == 4127)
            #expect(FLACInfo.streamInfo(flac)?.totalSamples == 4127)
            try expectDecoded(flac, equals: input, in: directory)
            #expect(!FileManager.default.fileExists(atPath: flac.path + ".partial"))
        }
    }

    @Test func wavFormatAndPermissions() throws {
        try temporary { directory in
            let wav = directory.appendingPathComponent("input.wav")
            let flac = directory.appendingPathComponent("output.flac")
            let writer = try WAVWriter(url: wav)
            #expect(try permissions(wav) == 0o600)
            try [Int16(123)].withUnsafeBufferPointer { try writer.append($0) }
            try writer.close()
            try FLACEncoder.encode(wav: wav, to: flac)
            #expect(try permissions(flac) == 0o600)
            #expect(throws: (any Error).self) { try WAVWriter(url: wav) }
            #expect(try WAVFile.samples(wav) == [123])
            var data = try Data(contentsOf: wav)
            // Patched odd byte lengths remain invalid; only crash recovery discards half a sample.
            data[40] = 1
            try data.write(to: wav)
            #expect(throws: AudioFileError.invalidFormat) { try WAVFile.samples(wav) }
            data[40] = 2
            var rate = Data()
            rate.appendLE(48000, bytes: 4)
            data.replaceSubrange(24..<28, with: rate)
            try data.write(to: wav)
            #expect(throws: AudioFileError.invalidFormat) { try WAVFile.samples(wav) }
            #expect(throws: AudioFileError.invalidFormat) { try FLACEncoder.encode(wav: wav, to: flac) }
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attrs[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    #if os(Linux)
    @Test(arguments: ["append", "close"]) func wavWriteFailureIsSticky(operation: String) throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("failure.wav")
            let writer = try WAVWriter(url: url)
            try [Int16(123)].withUnsafeBufferPointer { try writer.append($0) }
            let entries = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
            let entry = try #require(entries.first {
                (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/" + $0)) == url.path
            })
            let descriptor = try #require(Int32(entry))
            let full = open("/dev/full", O_WRONLY)
            #expect(full >= 0)
            guard full >= 0 else { return }
            defer { _ = Glibc.close(full) }
            #expect(dup2(full, descriptor) == descriptor)
            #expect(throws: (any Error).self) {
                if operation == "append" {
                    try [Int16(456)].withUnsafeBufferPointer { try writer.append($0) }
                } else { try writer.close() }
            }
            // Restore a writable descriptor: the failure must remain sticky even then.
            let restored = open(url.path, O_WRONLY | O_APPEND)
            #expect(restored >= 0)
            guard restored >= 0 else { return }
            defer { _ = Glibc.close(restored) }
            #expect(dup2(restored, descriptor) == descriptor)
            #expect(throws: AudioFileError.writeFailed) {
                try [Int16(789)].withUnsafeBufferPointer { try writer.append($0) }
            }
            #expect(throws: AudioFileError.writeFailed) { try writer.close() }
            #expect(try WAVFile.samples(url) == [123])
        }
    }
    #endif

    @Test func finalizationFailurePreservesDestination() throws {
        try temporary { directory in
            let destination = directory.appendingPathComponent("take.flac")
            let partial = URL(fileURLWithPath: destination.path + ".partial")
            try Data("old take".utf8).write(to: destination)
            try Data("in progress".utf8).write(to: partial)
            #expect(throws: (any Error).self) { try FLACEncoder.encode([1], sampleRate: 16000, to: destination) }
            #expect(try Data(contentsOf: destination) == Data("old take".utf8))
            #expect(try Data(contentsOf: partial) == Data("in progress".utf8))
            try FileManager.default.removeItem(at: partial)
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try FLACEncoder.encode([1], sampleRate: 16000, to: destination) }
            #expect(!FileManager.default.fileExists(atPath: partial.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    @Test(arguments: [16000, 12345, 128000, 655350, 1048575])
    func frameSampleRate(rate: Int) throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("rate.flac")
            try FLACEncoder.encode([1], sampleRate: rate, to: url)
            let bytes = try Data(contentsOf: url)
            let expected: [Int: UInt8] = [16000: 0x75, 12345: 0x7d, 128000: 0x7c, 655350: 0x7e, 1048575: 0x70]
            #expect(bytes[44] == expected[rate])
            if rate == 12345 { #expect(bytes[49..<51] == Data([0x30, 0x39])) }
            if rate == 128000 { #expect(bytes[49] == 128) }
            if rate == 655350 { #expect(bytes[49..<51] == Data([0xff, 0xff])) }
        }
    }

    @Test(arguments: [0, 1, 2, 3, 4]) func fixedPredictorChoice(order: Int) throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("predictor.flac")
            let input: [Int16] = (0..<16).map { index in
                let x = index - 8
                switch order {
                case 0: return 0
                case 1: return 42
                case 2: return Int16(x * 20)
                case 3: return Int16(x * x * 20)
                default: return Int16(x * x * x * 20)
                }
            }
            try FLACEncoder.encode(input, sampleRate: 16000, to: url)
            let data = try Data(contentsOf: url)
            #expect(data[50] == UInt8((8 + order) << 1))
        }
    }

    @Test func flacMetadata() throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("info.flac")
            for rate in [16000, 44100, 48000] {
                try FLACEncoder.encode([Int16](repeating: 0, count: 123), sampleRate: rate, to: url)
                #expect(FLACInfo.streamInfo(url)?.sampleRate == rate)
                #expect(FLACInfo.streamInfo(url)?.totalSamples == 123)
                #expect(FLACInfo.duration(url) == 123.0 / Double(rate))
            }
            try FLACEncoder.encode([], sampleRate: 16000, to: url)
            #expect(FLACInfo.duration(url) == 0)
        }
    }

    @Test func invalidFLACInfo() throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("bad.flac")
            #expect(FLACInfo.streamInfo(url) == nil)
            try Data("garbage".utf8).write(to: url)
            #expect(FLACInfo.streamInfo(url) == nil)
            #expect(FLACInfo.duration(url) == nil)
            try FLACEncoder.encode([], sampleRate: 16000, to: url)
            let original = try Data(contentsOf: url)
            for length in 0..<42 {
                try original.prefix(length).write(to: url)
                #expect(FLACInfo.streamInfo(url) == nil)
            }
            for index in [0, 4, 7, 8, 10] {
                var invalid = original
                invalid[index] = index == 10 ? 0 : 0xff
                try invalid.write(to: url)
                #expect(FLACInfo.streamInfo(url) == nil)
            }
        }
    }

    @Test func invalidSampleRates() throws {
        try temporary { directory in
            for rate in [0, -1, 1_048_576] {
                #expect(throws: AudioFileError.invalidFormat) {
                    try FLACEncoder.encode([0], sampleRate: rate, to: directory.appendingPathComponent("bad.flac"))
                }
            }
        }
    }
}
