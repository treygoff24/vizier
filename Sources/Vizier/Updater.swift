import VizierEngine
import Foundation
import Sparkle

/// In-app updates through Sparkle. The feed URL and the EdDSA public key come from Info.plist
/// (SUFeedURL, SUPublicEDKey); an update is applied only if its archive verifies against that key.
/// The menu and About items call `checkForUpdates()`; `canCheckForUpdates` is false while a check
/// is already running, for enabling those items.
final class Updater: NSObject {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    /// Starts Sparkle's scheduled checks. It stays off outside an .app bundle (`swift run` has no
    /// Info.plist feed and no embedded framework) and in any copy that is not Developer ID signed:
    /// a contributor's ad-hoc build must never run the production updater.
    func start() {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app", Self.isDeveloperIDSigned() else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// This process's own code signature is valid and is a Developer ID Application signature
    /// (`UpdateEligibility.developerIDRequirement`); a team identifier alone does not qualify.
    static func isDeveloperIDSigned() -> Bool {
        UpdateEligibility.currentProcessMayRunUpdater()
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// The user-initiated "Check for Updates…" action: shows Sparkle's own window with the result.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// `Vizier --version` prints the bundle's version and whether this copy's signature lets the updater run, and exits before any app setup. It also proves the
/// binary found Sparkle.framework through its rpath, since dyld resolves it before main runs.
enum VersionCommand {
    static func run(_ arguments: [String]) -> Int32? {
        guard arguments.contains("--version") else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        print("Vizier \(version) (\(build)), updater \(Updater.isDeveloperIDSigned() ? "eligible" : "off: not Developer ID signed")")
        return 0
    }
}
