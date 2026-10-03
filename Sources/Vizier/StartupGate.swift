import AppKit
import Darwin
import VizierEngine
import os

/// What the app checks in `main`, before it moves, opens, or creates any data: that no other copy
/// is running, and that the Dictum-era folders moved cleanly. Either problem stops the launch with
/// a message, and nothing is written, so the user can fix it and open Vizier again.
///
/// Another copy shares the bundle id (an installed Dictum, a second Vizier.app). Starting beside it
/// would move the folders out from under it, and startup recovery would close its take in progress
/// as abandoned. The other copy is never quit or signalled from here: it may be mid-take.
enum StartupGate {
    /// Another running app with this bundle id.
    struct RunningCopy: Equatable, Sendable {
        var pid: pid_t
        var name: String?
        var path: String?
    }

    enum Stop: Equatable {
        case anotherCopyRunning(RunningCopy)
        /// The migration outcomes that block the launch.
        case migrationNeedsAttention([UserDataMigration.Outcome])
    }

    /// The bundle id every copy shares, Dictum-era copies included. A binary run outside a bundle
    /// (`swift run`) has none of its own, and still must not start beside the installed app.
    static let bundleID = "net.praxient.dictum"

    /// How many times a copy that is still listed is looked for again, `pause` apart, before it
    /// counts as running: a copy that was just told to quit (an update's relaunch, install.sh)
    /// can linger in the list for a moment.
    static let lookups = 8

    /// Decides whether the app may start. `runningCopies` lists the apps with our bundle id;
    /// `migrate` runs the folder migration and is called only when no other copy is running, so a
    /// running copy's folders are never moved. Nil means start.
    static func check(
        ownPID: pid_t, runningCopies: () -> [RunningCopy], pause: () -> Void, migrate: () -> [UserDataMigration.Outcome]
    ) -> Stop? {
        for attempt in 1...lookups {
            guard let other = runningCopies().first(where: { $0.pid != ownPID }) else { break }
            if attempt == lookups { return .anotherCopyRunning(other) }
            pause()
        }
        let blocking = migrate().filter(\.blocksLaunch)
        return blocking.isEmpty ? nil : .migrationNeedsAttention(blocking)
    }

    /// The live check: the running-application list, quarter-second pauses, the real migration.
    static func checkLive() -> Stop? {
        check(
            ownPID: ProcessInfo.processInfo.processIdentifier,
            runningCopies: liveRunningCopies,
            pause: { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25)) },
            migrate: { UserDataMigration.run() })
    }

    private static func liveRunningCopies() -> [RunningCopy] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            // A process that has already exited is no copy, whatever the list still says.
            .filter { !$0.isTerminated && (kill($0.processIdentifier, 0) == 0 || errno == EPERM) }
            .map { RunningCopy(pid: $0.processIdentifier, name: $0.localizedName, path: $0.bundleURL?.path) }
    }

    // MARK: - The message

    struct Message: Equatable {
        var title: String
        var body: String
        /// What the "Show in Finder" button selects (full paths); empty means no such button.
        var items: [String]
    }

    static func message(for stop: Stop, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Message {
        switch stop {
        case .anotherCopyRunning(let other):
            let name = other.name ?? "Vizier"
            let place = other.path.map { " (\(tilde($0, home: home)))" } ?? ""
            return Message(
                title: "Another copy of Vizier is already running",
                body: "\(name)\(place) is open in the menu bar. Vizier was called Dictum before, and the two cannot run at once. "
                    + "Quit the other copy from its menu bar icon, then open Vizier again. This copy changed nothing.",
                items: [])
        case .migrationNeedsAttention(let outcomes):
            let lines = outcomes.compactMap { line(for: $0) }
            return Message(
                title: "Vizier could not move your Dictum data",
                body: lines.joined(separator: "\n\n")
                    + "\n\nVizier has not started and changed nothing, so nothing is lost. Open Vizier again when this is sorted out.",
                items: outcomes.flatMap(paths(of:)).map { home + "/" + $0 })
        }
    }

    private static func line(for outcome: UserDataMigration.Outcome) -> String? {
        switch outcome {
        case .moved, .oldEmpty:
            return nil
        case .bothPresent(let old, let new):
            return "Both ~/\(old) and ~/\(new) exist, and Vizier will not choose between them. "
                + "Vizier uses ~/\(new). Keep the one you want there: move the other out of the way (to the Desktop, say)."
        case .failed(let from, let to, let code):
            return "~/\(from) could not be renamed to ~/\(to) (\(String(cString: strerror(code)))). "
                + "It is still where it was. Check that you can write to the folder that holds it, or rename it yourself."
        }
    }

    private static func paths(of outcome: UserDataMigration.Outcome) -> [String] {
        switch outcome {
        case .moved, .oldEmpty: []
        case .bothPresent(let old, let new): [old, new]
        case .failed(let from, _, _): [from]
        }
    }

    private static func tilde(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The app delegate for a launch the gate stopped: it shows the message, and quits. It opens and
/// creates nothing, and never touches the other copy.
final class StoppedLaunchDelegate: NSObject, NSApplicationDelegate {
    private let message: StartupGate.Message
    private let code: Int32

    init(_ stop: StartupGate.Stop) {
        let message = StartupGate.message(for: stop)
        self.message = message
        code = if case .anotherCopyRunning = stop { 0 } else { 1 }
        Logger(subsystem: "net.praxient.dictum", category: "launch")
            .notice("launch stopped: \(message.title, privacy: .public)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message.title
        alert.informativeText = message.body
        alert.addButton(withTitle: "Quit")
        if !message.items.isEmpty { alert.addButton(withTitle: "Show in Finder") }
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(message.items.map { URL(filePath: $0) })
        }
        exit(code)
    }
}
