import Foundation

public enum FLACInfo {
    public static func streamInfo(_ url: URL) -> (sampleRate: Int, totalSamples: Int64)? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 42), data.count == 42,
              data.prefix(4) == Data("fLaC".utf8), data[4] & 0x7f == 0,
              data.integer(at: 5, bytes: 3) == 34 else { return nil }
        let minimum = data.integer(at: 8, bytes: 2)
        let maximum = data.integer(at: 10, bytes: 2)
        guard minimum >= 16, maximum >= minimum else { return nil }
        let packed = data.integer(at: 18, bytes: 8)
        let rate = Int(packed >> 44)
        guard rate > 0 else { return nil }
        return (rate, Int64(packed & 0x0f_ffff_ffff))
    }

    public static func duration(_ url: URL) -> Double? {
        guard let info = streamInfo(url) else { return nil }
        return Double(info.totalSamples) / Double(info.sampleRate)
    }
}
