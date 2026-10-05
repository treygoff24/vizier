import Foundation
import Glibc
import VizierEngine

/// Never reports the mic as denied: Linux has no per-app microphone permission to refuse, and a
/// mic that cannot be opened surfaces as a capture failure with its own remark.
@MainActor
public final class LinuxMicPermission: MicPermission {
    public init() {}
    public func microphoneDenied() -> Bool { false }
}

/// The focused app for the board and history. The desktop's readers are asynchronous and the
/// board's probe calls are not, so the name comes from the latest answer, refreshed in the
/// background at each call and every second while a take is active (a first name at the start of
/// a take may be the one from the last refresh, empty if there was none). The pid that decides
/// where the paste goes is never taken from that cache: `focusAtStop` reads the desktop afresh
/// and the session waits for it.
@MainActor
public final class LinuxFocusProbe: FocusProbe {
    private let reader: any FocusReader
    private var latest: FocusedWindow?
    private var polling: Task<Void, Never>?
    private var refreshing = false

    public init(reader: any FocusReader) { self.reader = reader }

    public func destinationName() -> String {
        refresh()
        return latest?.appName ?? ""
    }

    /// The cached answer; display only. The stop uses `focusAtStop()`.
    public func focusedProcess() -> Int32? {
        refresh()
        return latest?.pid
    }

    /// A fresh, awaited read at the stop. Nil when the desktop cannot say (the paste is then not
    /// held for a focus change, since there is nothing to compare).
    public func focusAtStop() async -> Int32? {
        let window = await reader.focusedWindow()
        latest = window
        return window?.pid
    }

    /// Starts or stops the one-second poll; the presentation drives it as takes begin and end.
    public func setPolling(_ on: Bool) {
        polling?.cancel(); polling = nil
        guard on else { return }
        refresh()
        let interval: Duration = reader is CosmicFocusReader ? .seconds(3) : .seconds(1)
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.refresh()
            }
        }
    }

    public func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task { [reader] in
            let window = await reader.focusedWindow()
            self.latest = window
            self.refreshing = false
        }
    }
}

/// A control that refreshes its secret snapshot when `vizier key set|delete` says the keys changed.
@MainActor
public protocol KeyRefreshing: AnyObject {
    /// Starts a refresh and returns at once.
    func keysChanged()
}

/// The real take session plus the things that must stop with it: the global shortcut, the
/// portal's remote-desktop session and the secret refresher. The daemon sees only `TakeControl`.
@MainActor
public final class LinuxControl: TakeControl, KeyRefreshing {
    public let session: TakeSession
    public let presentation: LinuxPresentation
    /// Why the hotkey is not running, or what it is; for `vizier setup` and logs.
    public private(set) var hotkeyDetail = "not started"
    private var hotkey: (any HotkeySource)?
    /// A source whose `start` has not returned yet, and the task running it.
    private var registering: (any HotkeySource)?
    private var registration: Task<Void, Never>?
    private var shutdownBegan = false
    private var portal: PortalRemoteDesktop?
    private let secrets: SnapshotSecretStore?
    private var refresher: Task<Void, Never>?

    init(session: TakeSession, presentation: LinuxPresentation, portal: PortalRemoteDesktop?, secrets: SnapshotSecretStore? = nil) {
        self.session = session
        self.presentation = presentation
        self.portal = portal
        self.secrets = secrets
    }

    public func toggle() throws(TakeCommandError) -> TakeStatus { try session.toggle() }
    public func start() throws(TakeCommandError) -> TakeStatus { try session.start() }
    public func stop() throws(TakeCommandError) -> TakeStatus { try session.stop() }
    public func cancel() throws(TakeCommandError) -> TakeStatus { try session.cancel() }
    public func status() -> TakeStatus { session.status() }

    public func keysChanged() {
        guard let secrets, !shutdownBegan else { return }
        Task { await secrets.refresh() }
    }

    /// Re-reads the keys every `interval`, so a key seeded behind the daemon's back is found.
    func startRefreshing(every interval: Duration) {
        guard let secrets else { return }
        refresher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await secrets.refresh()
            }
        }
    }

    /// Shutdown, with one deadline for all of it: new commands are refused and hotkey callbacks
    /// dropped at once, the hotkey (a registration still in progress included) is stopped while the
    /// session winds down, then pending notifications are flushed or abandoned and the portal is
    /// closed, each only for what is left of `deadline`. True when nothing was left in flight.
    public func quiesce(until deadline: ContinuousClock.Instant) async -> Bool {
        shutdownBegan = true
        refresher?.cancel(); refresher = nil
        registration?.cancel(); registration = nil
        let sources = [registering, hotkey].compactMap { $0 }
        registering = nil; hotkey = nil
        let hotkeys = Task {
            await Bounded.run(until: deadline) { for source in sources { await source.stop() } }
        }
        var complete = await session.quiesce(until: deadline)
        if !(await hotkeys.value) { complete = false }
        if !(await presentation.drain(until: deadline)) { complete = false }
        if let portal {
            self.portal = nil
            if !(await Bounded.run(until: deadline) { await portal.stop() }) { complete = false }
        }
        return complete
    }

    func noteHotkey(_ detail: String) { hotkeyDetail = detail }

    /// Starts registering the hotkey in the background (a first run may wait on the desktop's
    /// consent dialog), keeping the task so shutdown can cancel it.
    func beginHotkey(_ source: any HotkeySource) {
        registration = Task { [weak self] in await self?.startHotkey(source) }
    }

    /// Starts the hotkey source; the shortcuts call the session's own toggle and cancel. A refused
    /// command (a toggle while finalizing) is dropped: the take's notification says where it is.
    /// Shutdown during the registration drops the callbacks, stops the source and rejects the late
    /// success.
    func startHotkey(_ source: any HotkeySource) async {
        guard !shutdownBegan else { return }
        registering = source
        do {
            try await source.start(
                onToggle: { [weak self] in guard let self, !self.shutdownBegan else { return }; _ = try? self.session.toggle() },
                onCancel: { [weak self] in guard let self, !self.shutdownBegan else { return }; _ = try? self.session.cancel() })
        } catch {
            if registering === source { registering = nil }
            hotkeyDetail = shutdownBegan ? "stopped" : "\(source.name) did not start: \(error)"
            return
        }
        if registering === source { registering = nil }
        guard !shutdownBegan else {
            await source.stop()
            hotkeyDetail = "stopped"
            return
        }
        hotkey = source
        hotkeyDetail = "\(source.name) active"
    }
}

/// Composes the daemon's real take session from the Linux adapters.
@MainActor
public enum LinuxRuntime {
    public enum HotkeyChoice {
        case automatic, none
        case source(any HotkeySource)
    }

    public struct Options {
        public var environment: [String: String]
        public var configDirectory: URL
        public var dataDirectory: URL
        /// The recorder argv; nil resolves `VIZIER_RECORDER_COMMAND`, then pw-record, then parec.
        public var recorderCommand: [String]?
        /// The desktop; nil reads it from `environment`.
        public var desktop: DesktopSession?
        /// Where notifications go; nil uses D-Bus, then notify-send. `silent` shows none.
        public var notificationSink: (any NotificationSink)?
        public var silent = false
        /// The global shortcut: `.automatic` starts the portal's GlobalShortcuts on GNOME, KDE and
        /// Hyprland and nothing elsewhere (compositor binds run `vizier toggle`); tests pass a fake.
        public var hotkey = HotkeyChoice.automatic
        /// Replaces the secret chain (tests).
        public var secrets: (any SecretStore)?
        public var useSecretService = true
        public var soundsEnabled = true
        /// Tries the desktop portals (RemoteDesktop paste, GlobalShortcuts) on GNOME, KDE and Hyprland.
        public var usePortals = true
        public var prePasteDelay: Duration = .milliseconds(100)
        public var engines: TakeEngines = .standard
        /// How long `make` waits for the first read of the keys before it goes on without them.
        public var secretsLoadWait: Duration = .seconds(3)
        /// How often the daemon re-reads the keys.
        public var secretsRefreshInterval: Duration = .seconds(60)

        public init(environment: [String: String], configDirectory: URL, dataDirectory: URL) {
            self.environment = environment
            self.configDirectory = configDirectory
            self.dataDirectory = dataDirectory
        }
    }

    /// The recorder command: an explicit argv, else `VIZIER_RECORDER_COMMAND` split on spaces and tabs
    /// (no quoting, escaping or shell expansion: quotes and `$` stay literal characters), else
    /// pw-record, else parec when only it is installed, else pw-record (its absence is then reported).
    public static func recorderCommand(environment: [String: String], explicit: [String]? = nil) -> [String] {
        if let explicit, !explicit.isEmpty { return explicit }
        if let line = environment["VIZIER_RECORDER_COMMAND"] {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if !words.isEmpty { return words }
        }
        if ProcessRunner.resolve("pw-record", environment: environment) == nil,
           ProcessRunner.resolve("parec", environment: environment) != nil {
            return ["parec", "--raw", "--rate=16000", "--channels=1", "--format=s16le"]
        }
        return PipeCapture.defaultCommand
    }

    /// Whether the sounds switch is on: `VIZIER_SOUNDS=off` (or 0, false, no) turns the cues off.
    public static func soundsEnabled(environment: [String: String]) -> Bool {
        !["off", "0", "false", "no"].contains((environment["VIZIER_SOUNDS"] ?? "").lowercased())
    }

    /// Builds the session and starts its crash recovery; commands are refused with
    /// `startup_not_ready` until that finishes. History that cannot open leaves takes running with
    /// no history rows.
    public static func make(_ options: Options) async throws -> LinuxControl {
        let environment = options.environment
        let log = Logger(subsystem: "net.praxient.vizier", category: "runtime")
        let config = ConfigStore(directory: options.configDirectory)
        try config.writeStarterFilesIfMissing()
        let store = TakeStore(root: options.dataDirectory.appending(path: "Takes"))
        let history: HistoryStore?
        do { history = try HistoryStore(databaseURL: options.dataDirectory.appending(path: "history.sqlite"), takesRoot: store.root) }
        catch {
            history = nil
            log.error("history did not open; takes run without history rows: \(String(describing: error), privacy: .private)")
        }
        let recorder = TakeRecorder(capture: PipeCapture(command: recorderCommand(environment: environment, explicit: options.recorderCommand)))
        // The session reads keys from an in-memory snapshot, refreshed off the main actor, so a
        // stalled keyring can never block it. The first read is waited for, but only briefly.
        let secrets = SnapshotSecretStore(source: options.secrets ?? LinuxSecretStore(environment: environment, configDirectory: options.configDirectory, useSecretService: options.useSecretService))
        _ = await Bounded.run(until: .now + options.secretsLoadWait) { await secrets.refresh() }

        let desktop = options.desktop ?? DesktopSession.detect(environment: environment)
        let helpers = HelperEnvironment(variables: environment, distro: DistroFamily.detect())
        var plan = await DesktopRoutes.make(session: desktop, env: helpers, allowYdotool: environment["VIZIER_YDOTOOL"] == "1")
        let portalDesktop = desktop.display != .none && [.gnome, .kde].contains(desktop.family)
        var portal: PortalRemoteDesktop?
        if options.usePortals && portalDesktop {
            let candidate = PortalRemoteDesktop()
            // A stored consent token restores at once; a first run may be waiting on the user, so it is bounded.
            if await prepared(candidate, within: .seconds(20)), await candidate.probe().available {
                plan.writers.insert(candidate, at: 0)
                plan.senders.insert(candidate, at: 0)
                portal = candidate
            } else {
                await candidate.stop()
                log.notice("the RemoteDesktop portal is not ready; run vizier setup")
            }
        }
        let reader = FocusReaders.make(for: desktop, env: helpers)
        let focus = LinuxFocusProbe(reader: reader)
        let paster = LinuxPaster(plan: plan, focus: reader, prePasteDelay: options.prePasteDelay)

        let sink: (any NotificationSink)? = options.silent ? nil : (options.notificationSink ?? FallbackNotificationSink.standard(environment: environment))
        let presentation = LinuxPresentation(sink: sink, modeName: { config.load().config.activeMode.name })
        presentation.onActiveChanged = { focus.setPolling($0) }
        let sounds = LinuxSounds(environment: environment, enabled: options.soundsEnabled && soundsEnabled(environment: environment))

        let session = TakeSession(
            config: config, store: store, recorder: recorder, history: history, secrets: secrets,
            presentation: presentation, sounds: sounds, microphone: LinuxMicPermission(), focus: focus,
            paster: paster, remarks: .linux, speech: .none, engines: options.engines, log: Logger(subsystem: "net.praxient.vizier", category: "take"))
        session.warmUpCapture()
        // The socket is published after `make` returns, so waiting here keeps a client from
        // seeing a daemon whose crash recovery is still running.
        await session.recoverUnfinishedTakes().value
        let control = LinuxControl(session: session, presentation: presentation, portal: portal, secrets: secrets)
        control.startRefreshing(every: options.secretsRefreshInterval)
        let source: (any HotkeySource)?
        switch options.hotkey {
        case .automatic: source = options.usePortals ? hotkeySource(for: desktop) : nil
        case .none: source = nil
        case .source(let custom): source = custom
        }
        if let source {
            // Off the startup path: a first run may wait on the desktop's consent dialog.
            control.beginHotkey(source)
        } else {
            control.noteHotkey("no portal on this desktop; bind `vizier toggle` and `vizier cancel` in the compositor")
        }
        return control
    }

    /// Runs `prepare()`, giving up after `limit` (the task is left to finish on its own).
    private static func prepared(_ portal: PortalRemoteDesktop, within limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await portal.prepare()) != nil }
            group.addTask { try? await Task.sleep(for: limit); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// The hotkey source for this desktop, when a portal is the road to one.
    public static func hotkeySource(for desktop: DesktopSession) -> (any HotkeySource)? {
        guard desktop.display != .none, [.gnome, .kde, .hyprland].contains(desktop.family) else { return nil }
        return PortalGlobalShortcuts()
    }
}
