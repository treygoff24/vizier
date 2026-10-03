import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum AudioFileError: Error {
    case invalidFormat
    case closed
    case writeFailed
    case tooLarge
}

/// Streaming 16 kHz mono PCM. Callers serialize append and close operations.
public final class WAVWriter {
    private let file: FileHandle
    private var frames: Int64 = 0
    private var isClosed = false
    private var failed = false

    public init(url: URL) throws {
        file = try privateAudioFile(url)
        var header = Data("RIFF".utf8)
        header.appendLE(0, bytes: 4)
        header.append(Data("WAVEfmt ".utf8))
        for (value, bytes) in [(16, 4), (1, 2), (1, 2), (16000, 4), (32000, 4), (2, 2), (16, 2)] {
            header.appendLE(UInt64(value), bytes: bytes)
        }
        header.append(Data("data".utf8))
        header.appendLE(0, bytes: 4)
        try file.write(contentsOf: header)
    }

    public func append(_ samples: UnsafeBufferPointer<Int16>) throws {
        guard !failed else { throw AudioFileError.writeFailed }
        guard !isClosed else { throw AudioFileError.closed }
        guard Int64(samples.count) <= (Int64(UInt32.max) - 36) / 2 - frames else {
            throw AudioFileError.tooLarge
        }
        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples { data.appendLE(UInt64(UInt16(bitPattern: sample)), bytes: 2) }
        do { try file.write(contentsOf: data) }
        catch {
            // A partial write may end between samples. Never append after that failure.
            failed = true
            throw error
        }
        frames += Int64(samples.count)
    }

    @discardableResult public func close() throws -> Int64 {
        guard !failed else { throw AudioFileError.writeFailed }
        if isClosed { return frames }
        do {
            var riff = Data()
            riff.appendLE(UInt64(frames * 2 + 36), bytes: 4)
            try file.seek(toOffset: 4)
            try file.write(contentsOf: riff)
            var size = Data()
            size.appendLE(UInt64(frames * 2), bytes: 4)
            try file.seek(toOffset: 40)
            try file.write(contentsOf: size)
            try file.close()
            isClosed = true
            return frames
        } catch {
            failed = true
            throw error
        }
    }

    deinit { try? file.close() }
}

public enum WAVFile {
    public static func samples(_ url: URL) throws -> [Int16] {
        let reader = try WAVReader(url)
        var samples: [Int16] = []
        while let block = try reader.next() { samples.append(contentsOf: block) }
        return samples
    }

    /// The number of samples the WAV holds, from its header (or its length when a crash left the
    /// header unpatched), without reading the samples.
    public static func sampleCount(_ url: URL) throws -> Int64 {
        try WAVReader(url).totalSamples
    }
}

/// The array reader and streaming encoder share chunk bounds and crash recovery.
final class WAVReader {
    private let file: FileHandle
    private var remaining: UInt64 = 0
    let totalSamples: Int64

    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        let length = try file.seekToEnd()
        try file.seek(toOffset: 0)
        let header = try file.read(upToCount: 12) ?? Data()
        guard header.count == 12, header.prefix(4) == Data("RIFF".utf8),
              header[8..<12] == Data("WAVE".utf8) else { throw AudioFileError.invalidFormat }
        var offset: UInt64 = 12
        var pcm = false
        while offset <= length, length - offset >= 8 {
            try file.seek(toOffset: offset)
            let chunk = try file.read(upToCount: 8) ?? Data()
            guard chunk.count == 8 else { throw AudioFileError.invalidFormat }
            let id = chunk.prefix(4)
            let size = chunk.integer(at: 4, bytes: 4, littleEndian: true)
            offset += 8
            if id == Data("data".utf8) {
                guard pcm else { throw AudioFileError.invalidFormat }
                let bytes = (size == 0 || size == UInt64(UInt32.max)) ? (length - offset) & ~1 : size
                guard bytes <= length - offset, bytes % 2 == 0 else { throw AudioFileError.invalidFormat }
                remaining = bytes
                totalSamples = Int64(bytes / 2)
                return
            }
            guard size <= length - offset else { throw AudioFileError.invalidFormat }
            if id == Data("fmt ".utf8) {
                let fmt = try file.read(upToCount: 16) ?? Data()
                guard size >= 16, fmt.count == 16,
                      fmt.integer(at: 0, bytes: 2, littleEndian: true) == 1,
                      fmt.integer(at: 2, bytes: 2, littleEndian: true) == 1,
                      fmt.integer(at: 4, bytes: 4, littleEndian: true) == 16000,
                      fmt.integer(at: 12, bytes: 2, littleEndian: true) == 2,
                      fmt.integer(at: 14, bytes: 2, littleEndian: true) == 16 else {
                    throw AudioFileError.invalidFormat
                }
                pcm = true
            }
            offset += size + size % 2
        }
        throw AudioFileError.invalidFormat
    }

    func next() throws -> [Int16]? {
        guard remaining > 0 else { return nil }
        let count = Int(min(remaining, 4096 * 2))
        let bytes = try file.read(upToCount: count) ?? Data()
        guard bytes.count == count else { throw AudioFileError.invalidFormat }
        remaining -= UInt64(count)
        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stride(from: 0, to: count, by: 2).map {
                Int16(bitPattern: UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8)
            }
        }
    }

    deinit { try? file.close() }
}

/// Exclusive creation prevents a pre-existing file or symlink from exposing audio.
func privateAudioFile(_ url: URL) throws -> FileHandle {
    let descriptor = url.withUnsafeFileSystemRepresentation { name in
        guard let name else { errno = EINVAL; return Int32(-1) }
        return open(name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

func renameAudioFile(_ source: URL, to destination: URL) throws {
    let result = source.withUnsafeFileSystemRepresentation { src in
        destination.withUnsafeFileSystemRepresentation { dst in
            guard let src, let dst else { errno = EINVAL; return Int32(-1) }
            return rename(src, dst)
        }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

extension Data {
    mutating func appendLE(_ value: UInt64, bytes: Int) {
        for shift in 0..<bytes { append(UInt8(truncatingIfNeeded: value >> (8 * shift))) }
    }

    func integer(at offset: Int, bytes: Int, littleEndian: Bool = false) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<bytes {
            let position = littleEndian ? offset + bytes - 1 - index : offset + index
            value = (value << 8) | UInt64(self[position])
        }
        return value
    }
}
