import Foundation

/// What Settings and the popover need of the updater. `Updater.shared` is the real one; it cannot
/// check in an ad-hoc build, where Sparkle never starts, so those items show disabled.
protocol UpdateChecking {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

extension Updater: UpdateChecking {}

/// The words next to a disabled Check for Updates.
enum UpdateHint {
    static let unsigned = "Updates come with the signed release."
}

struct FakeUpdater: UpdateChecking {
    var canCheck: Bool
    var canCheckForUpdates: Bool { canCheck }
    func checkForUpdates() {}
}
