import Foundation
import Glibc
import VizierEngine

/// The daemon's cues: `start.wav`, `stop.wav`, `problem.wav`, `cancel.wav`, played with `pw-play`,
/// else `paplay`, else `aplay`. The player is a detached child, so a cue never blocks the main
/// actor and never delays a take; with no player or no sound files it is silent.
@MainActor
public final class LinuxSounds: SoundPlayer {
    public static let players = ["pw-play", "paplay", "aplay"]

    private let environment: [String: String]
    public let directory: URL?
    public let player: String?
    private let enabled: Bool

    /// `enabled` false is the switch for sounds off (the daemon reads `VIZIER_SOUNDS=off`).
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, directory: URL? = nil, enabled: Bool = true) {
        self.environment = environment
        self.directory = directory ?? Self.locate(environment: environment)
        player = Self.players.first { ProcessRunner.resolve($0, environment: environment) != nil }
        self.enabled = enabled
    }

    public func play(_ sound: TakeSound) {
        guard enabled, let player, let file = directory?.appending(path: "\(sound.rawValue).wav"),
              FileManager.default.isReadableFile(atPath: file.path) else { return }
        let argv = [player, file.path]
        let environment = environment
        // Plays on its own; the helper is left running and reaped once it ends.
        Task.detached { _ = try? await ProcessRunner.spawnDetached(argv, environment: environment, settle: .milliseconds(50)) }
    }

    /// Where the cues are: `$VIZIER_SOUNDS_DIR`, `../share/vizier/sounds` beside the binary, each
    /// `$XDG_DATA_HOME` / `$XDG_DATA_DIRS` entry's `vizier/sounds`, then the repository's
    /// `Resources/Sounds` when the binary runs from a `.build` folder.
    public static func locate(environment: [String: String], executable: URL? = nil) -> URL? {
        var candidates: [URL] = []
        if let path = environment["VIZIER_SOUNDS_DIR"], path.hasPrefix("/") { candidates.append(URL(filePath: path)) }
        let binary = executable ?? currentExecutable()
        if let binary {
            candidates.append(binary.deletingLastPathComponent().appending(path: "../share/vizier/sounds").standardized)
        }
        var data: [String] = []
        if let home = environment["XDG_DATA_HOME"], home.hasPrefix("/") { data.append(home) }
        else { data.append(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share").path) }
        data += (environment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        candidates += data.map { URL(filePath: $0).appending(path: "vizier/sounds") }
        if var directory = binary?.deletingLastPathComponent() {
            for _ in 0..<6 {
                candidates.append(directory.appending(path: "Resources/Sounds"))
                directory.deleteLastPathComponent()
            }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "start.wav").path) }
    }

    private static func currentExecutable() -> URL? {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")).map { URL(filePath: $0) }
    }
}
