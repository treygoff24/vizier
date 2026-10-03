import Foundation
import Synchronization
import VizierEngine

/// Owns only Vizier's two installed helper jobs. Cloud modes never load them.
///
/// Most users have no local mode and no helper launch agents. For them this type does nothing:
/// no launchctl call at launch, none at quit. It acts only when the config has a mode that uses a
/// local engine, or when a helper's launch-agent plist is installed (so it can keep that job off
/// while no mode needs it). The config is re-read only when its file changes.
final class LocalModels {
    nonisolated private static let labels = ["net.praxient.dictum.whisper", "net.praxient.dictum.cleanup"]

    private var timer: Timer?
    /// What the last apply asked for. Nil until this type has asked launchctl for anything.
    private var requested: (Bool, Bool)?
    private var configStamp: ConfigStamp?
    private var hasLocalMode = false
    private var wantsWhisper = false
    private var wantsCleanup = false
    private let queue = DispatchQueue(label: "net.praxient.dictum.local-models")
    /// Set at quit so a queued apply cannot bootstrap a job after stop() has booted it out.
    nonisolated private static let stopped = Mutex(false)

    private struct ConfigStamp: Equatable {
        var modified: Date?
        var size: Int?
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    nonisolated private static func plistURL(_ label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private func currentStamp() -> ConfigStamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: ConfigStore.standard.settingsURL.path)
        return ConfigStamp(modified: attributes?[.modificationDate] as? Date, size: (attributes?[.size] as? NSNumber)?.intValue)
    }

    private func refresh() {
        // A stat per tick; the config is parsed only after the file changed.
        let stamp = currentStamp()
        if stamp != configStamp {
            configStamp = stamp
            let config = ConfigStore.standard.load().config
            let mode = config.activeMode
            wantsWhisper = mode.transcriber.engine == "local-whisper"
            wantsCleanup = mode.cleanup?.engine == "local-cleanup"
            hasLocalMode = config.settings.modes.contains {
                $0.transcriber.engine == "local-whisper" || $0.cleanup?.engine == "local-cleanup"
            }
        }
        let installed = Self.labels.contains { FileManager.default.fileExists(atPath: Self.plistURL($0).path) }
        // Nothing to manage: no local mode and no helper installed. Never run launchctl.
        guard hasLocalMode || installed else { return }
        let wanted = (wantsWhisper, wantsCleanup)
        if let requested, requested == wanted { return }
        requested = wanted
        queue.async { Self.apply(whisper: wanted.0, cleanup: wanted.1) }
    }

    /// Quit-time shutdown. Skipped when nothing was started; otherwise the launchctl calls are
    /// spawned and not waited for, so quitting never blocks on them.
    func stop() {
        timer?.invalidate()
        Self.stopped.withLock { $0 = true }
        guard let requested else { return }
        for (label, on) in zip(Self.labels, [requested.0, requested.1]) where on {
            let job = "gui/\(getuid())/\(label)"
            Self.spawn(["disable", job])
            Self.spawn(["bootout", job])
        }
    }

    nonisolated private static func process(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    nonisolated private static func spawn(_ arguments: [String]) {
        try? process(arguments).run()
    }

    nonisolated private static func run(_ arguments: [String]) -> Bool {
        let process = process(arguments)
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }

    nonisolated private static func apply(whisper: Bool, cleanup: Bool) {
        for (label, needed) in zip(labels, [whisper, cleanup]) {
            let domain = "gui/\(getuid())"
            let job = "\(domain)/\(label)"
            let loaded = run(["print", job])
            if needed {
                if !loaded {
                    if stopped.withLock({ $0 }) { return }
                    _ = run(["enable", job])
                    _ = run(["bootstrap", domain, plistURL(label).path])
                    // Keep it disabled for the next login; this app owns its lifetime.
                    _ = run(["disable", job])
                }
            } else {
                _ = run(["disable", job])
                if loaded { _ = run(["bootout", job]) }
            }
        }
    }
}
