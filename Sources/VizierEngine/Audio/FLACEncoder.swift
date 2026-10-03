import Foundation

/// Mono, 16-bit FLAC using RFC 9639 fixed predictors and one Rice partition.
public enum FLACEncoder {
    @discardableResult public static func encode(_ samples: [Int16], sampleRate: Int, to url: URL) throws -> Int64 {
        var offset = 0
        return try encode(total: Int64(samples.count), sampleRate: sampleRate, to: url) {
            guard offset < samples.count else { return nil }
            let end = min(offset + 4096, samples.count)
            defer { offset = end }
            return Array(samples[offset..<end])
        }
    }

    /// Reads only a header and one 4,096-sample block at a time, including recovered WAVs.
    @discardableResult public static func encode(wav: URL, to url: URL) throws -> Int64 {
        let reader = try WAVReader(wav)
        return try encode(total: reader.totalSamples, sampleRate: 16000, to: url) { try reader.next() }
    }

    private static func encode(total: Int64, sampleRate: Int, to url: URL,
                               next: () throws -> [Int16]?) throws -> Int64 {
        guard (1...1_048_575).contains(sampleRate) else { throw AudioFileError.invalidFormat }
        guard total >= 0, UInt64(total) < (1 << 36) else { throw AudioFileError.tooLarge }
        let partial = URL(fileURLWithPath: url.path + ".partial")
        let file = try privateAudioFile(partial)
        do {
            var info = FLACBits()
            info.put(4096, 16) // Nominal fixed block size; the last frame may be shorter.
            info.put(4096, 16)
            info.put(0, 24) // Frame byte sizes unknown.
            info.put(0, 24)
            info.put(UInt64(sampleRate), 20)
            info.put(0, 3) // One channel minus one.
            info.put(15, 5) // Bits per sample minus one.
            info.put(UInt64(total), 36)
            for _ in 0..<16 { info.put(0, 8) } // MD5 unset.
            var header = Data("fLaC".utf8)
            header.append(contentsOf: [0x80, 0, 0, 34])
            header.append(info.finish())
            try file.write(contentsOf: header)
            var frames: UInt64 = 0
            var written: Int64 = 0
            while let block = try next() {
                try file.write(contentsOf: frame(block.map(Int64.init), number: frames, sampleRate: sampleRate))
                frames += 1
                written += Int64(block.count)
            }
            guard written == total else { throw AudioFileError.invalidFormat }
            try file.synchronize()
            try file.close()
            try renameAudioFile(partial, to: url)
            return written
        } catch {
            try? file.close()
            try? FileManager.default.removeItem(at: partial) // Only the file this call created.
            throw error
        }
    }

    static func frame(_ samples: [Int64], number: UInt64, sampleRate: Int,
                      order: Int? = nil, riceParameter: Int? = nil) -> Data {
        let (rateCode, rateBytes) = rateEncoding(sampleRate)
        var frame = Data([0xff, 0xf8, 0x70 | rateCode, 0x08])
        frame.append(contentsOf: codedNumber(number))
        frame.append(UInt8(truncatingIfNeeded: (samples.count - 1) >> 8))
        frame.append(UInt8(truncatingIfNeeded: samples.count - 1))
        frame.append(contentsOf: rateBytes)
        frame.append(UInt8(crc(frame, width: 8)))
        frame.append(subframe(samples, order: order, riceParameter: riceParameter))
        let checksum = crc(frame, width: 16)
        frame.append(UInt8(checksum >> 8))
        frame.append(UInt8(truncatingIfNeeded: checksum))
        return frame
    }

    private static func rateEncoding(_ rate: Int) -> (UInt8, [UInt8]) {
        let table = [88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000]
        if let index = table.firstIndex(of: rate) { return (UInt8(index + 1), []) }
        if rate < 65536 { return (13, [UInt8(rate >> 8), UInt8(truncatingIfNeeded: rate)]) }
        if rate % 1000 == 0, rate / 1000 < 256 { return (12, [UInt8(rate / 1000)]) }
        if rate % 10 == 0, rate / 10 < 65536 {
            return (14, [UInt8((rate / 10) >> 8), UInt8(truncatingIfNeeded: rate / 10)])
        }
        return (0, []) // Only rates not representable in the frame header use STREAMINFO.
    }

    static func subframe(_ samples: [Int64], order forcedOrder: Int? = nil,
                         riceParameter forcedParameter: Int? = nil) -> Data {
        precondition(!samples.isEmpty)
        precondition(forcedOrder == nil || (0...min(4, samples.count - 1)).contains(forcedOrder!))
        precondition(forcedParameter == nil || (forcedOrder != nil && (0...15).contains(forcedParameter!)))
        var bestCost = forcedOrder == nil ? 8 + samples.count * 16 : Int.max
        var bestOrder: Int?
        var bestParameter = 0
        var bestWidth = 0
        var bestResidual: [Int64] = []
        let orders = forcedOrder.map { $0...$0 } ?? (0...min(4, samples.count - 1))
        for order in orders {
            var residual = [Int64]()
            var folded = [UInt64]()
            residual.reserveCapacity(samples.count - order)
            folded.reserveCapacity(samples.count - order)
            var minimum: Int64 = 0
            var maximum: Int64 = 0
            var sum: UInt64 = 0
            for index in order..<samples.count {
                let prediction: Int64
                switch order {
                case 0: prediction = 0
                case 1: prediction = samples[index - 1]
                case 2: prediction = 2 * samples[index - 1] - samples[index - 2]
                case 3: prediction = 3 * samples[index - 1] - 3 * samples[index - 2] + samples[index - 3]
                default: prediction = 4 * samples[index - 1] - 6 * samples[index - 2]
                    + 4 * samples[index - 3] - samples[index - 4]
                }
                let value = samples[index] - prediction
                let code = UInt64(value >= 0 ? 2 * value : -2 * value - 1)
                residual.append(value)
                folded.append(code)
                minimum = min(minimum, value)
                maximum = max(maximum, value)
                sum += code
            }
            let magnitude = UInt64(max(maximum, ~minimum))
            let width = minimum == 0 && maximum == 0 ? 0 : 65 - magnitude.leadingZeroBitCount
            let overhead = 8 + order * 16 + 6 + 4
            // Rice cost is convex in k. Start near the mean and descend to the exact minimum.
            func riceCost(_ k: Int) -> Int {
                overhead + folded.count * (1 + k) + Int(folded.reduce(0) { $0 + ($1 >> k) })
            }
            let mean = sum / UInt64(folded.count)
            var parameter = forcedParameter ?? min(14, max(0, 63 - mean.leadingZeroBitCount))
            if parameter != 15 {
                var cost = riceCost(parameter)
                if forcedParameter == nil {
                    while parameter > 0, riceCost(parameter - 1) <= cost {
                        parameter -= 1
                        cost = riceCost(parameter)
                    }
                    while parameter < 14, riceCost(parameter + 1) < cost {
                        parameter += 1
                        cost = riceCost(parameter)
                    }
                }
                if cost < bestCost {
                    bestCost = cost; bestOrder = order; bestParameter = parameter
                    bestResidual = residual
                }
            }
            let escapeCost = overhead + 5 + width * residual.count
            if forcedParameter == 15 || (forcedParameter == nil && escapeCost < bestCost) {
                bestCost = escapeCost; bestOrder = order; bestParameter = 15
                bestWidth = width; bestResidual = residual
            }
        }
        var bits = FLACBits()
        guard let order = bestOrder else {
            bits.put(2, 8) // Verbatim, no wasted bits.
            for sample in samples { bits.signed(sample, 16) }
            return bits.finish()
        }
        bits.put(UInt64((8 + order) << 1), 8)
        for sample in samples.prefix(order) { bits.signed(sample, 16) }
        bits.put(0, 2) // Rice coding with 4-bit parameter.
        bits.put(0, 4) // Single partition.
        bits.put(UInt64(bestParameter), 4)
        if bestParameter == 15 {
            bits.put(UInt64(bestWidth), 5)
            for value in bestResidual { bits.signed(value, bestWidth) }
        } else {
            for value in bestResidual {
                let folded = UInt64(value >= 0 ? value * 2 : -value * 2 - 1)
                bits.zeros(Int(folded >> bestParameter))
                bits.put(1, 1)
                bits.put(folded, bestParameter)
            }
        }
        return bits.finish()
    }

    static func codedNumber(_ number: UInt64) -> [UInt8] {
        precondition(number < 1 << 31) // Fixed-block frame numbers are limited to 31 bits.
        if number < 128 { return [UInt8(number)] }
        let count = (2...6).first { number < (UInt64(1) << (5 * $0 + 1)) }!
        var bytes = [UInt8](repeating: 0, count: count)
        var remainder = number
        for index in stride(from: count - 1, through: 1, by: -1) {
            bytes[index] = 0x80 | UInt8(remainder & 0x3f)
            remainder >>= 6
        }
        bytes[0] = UInt8(truncatingIfNeeded: 0xff << (8 - count)) | UInt8(remainder)
        return bytes
    }

    private static let crc8 = crcTable(width: 8, polynomial: 0x07)
    private static let crc16 = crcTable(width: 16, polynomial: 0x8005)

    private static func crcTable(width: Int, polynomial: UInt16) -> [UInt16] {
        (0..<256).map { byte in
            var value = UInt16(byte) << (width - 8)
            let top = UInt16(1) << (width - 1)
            for _ in 0..<8 { value = value & top != 0 ? (value &<< 1) ^ polynomial : value &<< 1 }
            return width == 8 ? value & 0xff : value
        }
    }

    private static func crc(_ bytes: Data, width: Int) -> UInt16 {
        var value: UInt16 = 0
        if width == 8 {
            for byte in bytes { value = crc8[Int(value ^ UInt16(byte))] }
        } else {
            for byte in bytes { value = (value &<< 8) ^ crc16[Int((value >> 8) ^ UInt16(byte))] }
        }
        return value
    }
}

private struct FLACBits {
    private var data = Data()
    private var accumulator: UInt64 = 0
    private var used = 0

    mutating func put(_ value: UInt64, _ count: Int) {
        var remaining = count
        while remaining > 0 {
            let take = min(64 - used, remaining)
            let mask: UInt64 = take == 64 ? .max : (1 << take) - 1
            let part = (value >> (remaining - take)) & mask
            accumulator = take == 64 ? part : (accumulator << take) | part
            used += take
            remaining -= take
            if used == 64 {
                for shift in stride(from: 56, through: 0, by: -8) {
                    data.append(UInt8(truncatingIfNeeded: accumulator >> shift))
                }
                accumulator = 0
                used = 0
            }
        }
    }

    mutating func signed(_ value: Int64, _ count: Int) { put(UInt64(bitPattern: value), count) }
    mutating func zeros(_ count: Int) {
        var remaining = count
        while remaining > 0 { let take = min(64, remaining); put(0, take); remaining -= take }
    }
    mutating func finish() -> Data {
        let padding = (8 - used % 8) % 8
        put(0, padding)
        if used > 0 {
            for shift in stride(from: used - 8, through: 0, by: -8) {
                data.append(UInt8(truncatingIfNeeded: accumulator >> shift))
            }
            used = 0
            accumulator = 0
        }
        return data
    }
}
