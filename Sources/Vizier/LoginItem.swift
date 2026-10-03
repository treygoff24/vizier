import Foundation
import ServiceManagement
import os

/// Open at Login, through `SMAppService.mainApp`. Only an installed bundle registers: the copy in
/// `/Applications` (where a DMG's drag-to-install puts it) or in `~/Applications`. A build bundle
/// never does, so a development build cannot register itself. The first launch from an installed
/// bundle turns it on once, and the default is recorded so a later "off" stays off.
enum LoginItem {
    private static let log = Logger(subsystem: "net.praxient.dictum", category: "login-item")
    private static let defaultAppliedKey = "loginItemDefaultApplied"
    private static let registeredPathKey = "loginItemRegisteredPath"
    /// Set before a repoint unregisters, cleared by the register that follows when it succeeds.
    static let pendingRepointKey = "loginItemRepointPending"
    static let bundleName = "Vizier.app"

    /// The folders an installed Vizier may live in.
    static func installFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(filePath: "/Applications", directoryHint: .isDirectory), home.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// True when `bundle` is `Vizier.app` directly inside `/Applications` or `~/Applications`, after
    /// resolving symlinks. Anything else, a `build/` folder above all, is not installed.
    static func isInstalledLocation(_ bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let resolved = bundle.resolvingSymlinksInPath().standardizedFileURL
        return installFolders(home: home).contains { folder in
            resolved.path == folder.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(bundleName).path
        }
    }

    static var isInstalledBundle: Bool { isInstalledLocation(Bundle.main.bundleURL) }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// The live service, the standard defaults, and this bundle's place: what the functions below
    /// act on unless a test hands them a fake.
    struct Context {
        var service: any LoginItemService = SMAppService.mainApp
        var defaults: UserDefaults = .standard
        var installed: Bool = LoginItem.isInstalledBundle
        var currentPath: String = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func applyDefaultOnce(_ context: Context = Context()) {
        guard context.installed, !context.defaults.bool(forKey: defaultAppliedKey) else { return }
        context.defaults.set(true, forKey: defaultAppliedKey)
        if context.service.status != .enabled { register(context) }
    }

    /// Background Task Management records a path with an app login item, and a copy that moved
    /// (Dictum.app became Vizier.app on 2026-10-03; or a move between the two Applications folders)
    /// may be left registered at the old path. When Open at Login is on and the path recorded at the
    /// last registration is not this bundle's (builds before this one recorded none), register again
    /// here. A copy whose login item is off stays off.
    static func needsRepoint(status: SMAppService.Status, recordedPath: String?, currentPath: String) -> Bool {
        status == .enabled && recordedPath != currentPath
    }

    /// Re-registers a login item left at another path. The intent is saved before the unregister
    /// and cleared only by a register that succeeds, so a register that fails after the unregister
    /// (which leaves the item off, where `needsRepoint` no longer sees it) is tried again at the
    /// next launch instead of turning Open at Login off for good. The user turning it off in
    /// Settings cancels the intent.
    static func repointIfMoved(_ context: Context = Context()) {
        guard context.installed else { return }
        if context.defaults.bool(forKey: pendingRepointKey) {
            log.notice("an earlier launch could not register Open at Login again; trying once more")
        } else {
            let recorded = context.defaults.string(forKey: registeredPathKey)
            guard needsRepoint(status: context.service.status, recordedPath: recorded, currentPath: context.currentPath) else { return }
            log.notice("Open at Login was registered for another path; registering this one")
            context.defaults.set(true, forKey: pendingRepointKey)
            unregister(context)
        }
        register(context)
    }

    /// Settings' switch: on registers, off unregisters (and drops a repoint still waiting to be
    /// retried, so a later launch does not turn it back on). Approval opens System Settings.
    static func setEnabled(_ on: Bool, _ context: Context = Context()) {
        if on {
            if context.service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } else { register(context) }
        } else {
            context.defaults.removeObject(forKey: pendingRepointKey)
            unregister(context)
        }
    }

    private static func register(_ context: Context) {
        guard context.installed else {
            log.notice("not an installed bundle; Open at Login left alone")
            return
        }
        do {
            try context.service.register()
            context.defaults.set(context.currentPath, forKey: registeredPathKey)
            context.defaults.removeObject(forKey: pendingRepointKey)
            log.notice("registered to open at login; status \(String(describing: context.service.status), privacy: .public)")
        } catch {
            log.error("could not register to open at login: \(String(describing: error), privacy: .private)")
        }
    }

    private static func unregister(_ context: Context) {
        do {
            try context.service.unregister()
            log.notice("unregistered from open at login")
        } catch {
            log.error("could not unregister from open at login: \(String(describing: error), privacy: .private)")
        }
    }
}

/// What Open at Login needs of `SMAppService.mainApp`, so tests use a fake.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// What the settings window needs of Open at Login, so previews and tests use a fake.
enum LoginItemState: Equatable {
    case on, off
    /// Registered, but the user must approve it in System Settings.
    case needsApproval
    /// Running from somewhere that cannot register (a build folder).
    case notInstalled
}

protocol LoginItemControlling {
    var state: LoginItemState { get }
    func setEnabled(_ on: Bool)
}

struct LiveLoginItem: LoginItemControlling {
    var state: LoginItemState {
        guard LoginItem.isInstalledBundle else { return .notInstalled }
        switch LoginItem.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    func setEnabled(_ on: Bool) { LoginItem.setEnabled(on) }
}
