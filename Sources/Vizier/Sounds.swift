import AVFoundation
import Foundation
import os

/// The four cues: start on the mic's first real audio, stop on the stop tap, problem when a take is
/// held or fails, cancel on Escape. They are the Sonar family of cues, rendered from synthesis
/// recipes into `Resources/Sounds`.
///
/// They play through the normal output at the main volume, not as system alert sounds: many people
/// keep the alert volume at zero, which would silence system sounds entirely.
final class Sounds {
    enum Cue: String, CaseIterable { case start, stop, problem, cancel }

    /// Full scale, over files raised 10 dB. At lower levels the cues were too quiet to hear over
    /// music. The files still peak near 0.6, so there is headroom left.
    static let volume: Float = 1.0

    private var players: [Cue: AVAudioPlayer] = [:]
    private let log = Logger(subsystem: "net.praxient.dictum", category: "sounds")

    /// Loads and primes every cue up front so a play costs no disk read. Outside the app bundle
    /// (`swift run`) there are no files and every cue is silent.
    init(directory: URL? = Bundle.main.resourceURL?.appending(path: "Sounds")) {
        guard let directory else { return }
        for cue in Cue.allCases {
            let url = directory.appending(path: "\(cue.rawValue).wav")
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = Self.volume
                player.prepareToPlay()
                players[cue] = player
            } catch {
                log.error("\(cue.rawValue, privacy: .public) sound did not load from \(url.path, privacy: .private): \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Settings' Sounds switch. Read at each cue, so turning it off takes effect at once.
    var isEnabled: () -> Bool = { AppPreferences.standard.soundsEnabled }

    func play(_ cue: Cue) {
        guard isEnabled(), let player = players[cue] else { return }
        player.currentTime = 0
        if !player.play() { log.error("\(cue.rawValue, privacy: .public) sound did not play") }
    }
}
