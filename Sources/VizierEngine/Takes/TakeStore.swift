import Foundation

/// The files of one take. The id doubles as the future history row's key, so the history lane
/// can adopt these files without renaming them: one FLAC per take, named by its UTC start time.
public struct TakeFiles: Sendable, Equatable {
    public let id: String
    public let directory: URL

    /// Written while recording. It survives a crash readable, which FLAC does not (an unclosed FLAC
    /// has an empty stream header), so a take becomes FLAC only once its recording is closed.
    public var recording: URL { directory.appending(path: id + "." + Self.recordingExtension) }

    /// The recording's file extension: CAF where AVFoundation writes it, WAV (`WAVWriter`) elsewhere.
    public static var recordingExtension: String {
        #if os(macOS)
        "caf"
        #else
        "wav"
        #endif
    }
    public var flac: URL { directory.appending(path: id + ".flac") }
}

public enum TakeStoreError: Error, CustomStringConvertible {
    case frameCountMismatch(expected: Int64, found: Int64)

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
        root: VizierPaths.data.appending(path: "Takes"))

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

    /// Recordings left behind by a crash or a failed encode, oldest first.
    public func unfinishedTakes() -> [TakeFiles] {
        let fm = FileManager.default
        guard let months = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return months.flatMap { month -> [TakeFiles] in
            let files = (try? fm.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == TakeFiles.recordingExtension }
                .map { TakeFiles(id: $0.deletingPathExtension().lastPathComponent, directory: month) }
        }
        .sorted { $0.id < $1.id }
    }
}
