import AppKit

/// Vizier lives in the menu bar, so it has no dock icon until one of its windows (Settings,
/// Onboarding, History) is open; "Show in Dock" keeps the icon permanently.
enum DockPolicy {
    /// `.regular` (dock icon, app switcher) while any Vizier window is open or Show in Dock is on;
    /// `.accessory` (menu bar only) otherwise.
    static func activationPolicy(openWindows: Int, showInDock: Bool) -> NSApplication.ActivationPolicy {
        showInDock || openWindows > 0 ? .regular : .accessory
    }

    /// A window counts as one the user opened when it is titled, not a panel, and on screen or
    /// minimized to the dock. The popover, the strip, and the status item's window are panels or
    /// borderless and never count.
    struct WindowFacts: Equatable {
        var id: ObjectIdentifier
        var isTitled: Bool
        var isPanel: Bool
        var isVisible: Bool
        var isMiniaturized: Bool

        var countsAsOpen: Bool { isTitled && !isPanel && (isVisible || isMiniaturized) }

        init(id: ObjectIdentifier, isTitled: Bool, isPanel: Bool, isVisible: Bool, isMiniaturized: Bool) {
            self.id = id
            self.isTitled = isTitled
            self.isPanel = isPanel
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
        }

        init(_ window: NSWindow) {
            self.init(id: ObjectIdentifier(window), isTitled: window.styleMask.contains(.titled), isPanel: window is NSPanel,
                      isVisible: window.isVisible, isMiniaturized: window.isMiniaturized)
        }
    }

    /// How many of `windows` count as open, leaving out the one that is closing.
    static func openWindowCount(_ windows: [WindowFacts], excluding closing: ObjectIdentifier? = nil) -> Int {
        windows.filter { $0.id != closing && $0.countsAsOpen }.count
    }
}

/// Applies `DockPolicy` as windows come and go. Window counts are read from `NSApp.windows`, with
/// the window that is closing left out, because its close notification arrives while it is still
/// visible.
final class DockController {
    private let preferences: AppPreferences
    private let apply: (NSApplication.ActivationPolicy) -> Void
    private let windows: () -> [DockPolicy.WindowFacts]
    private let activate: () -> Void
    private var observers: [NSObjectProtocol] = []
    private(set) var current: NSApplication.ActivationPolicy

    init(
        preferences: AppPreferences,
        current: NSApplication.ActivationPolicy = .accessory,
        windows: @escaping () -> [DockPolicy.WindowFacts] = { NSApp.windows.map { DockPolicy.WindowFacts($0) } },
        apply: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
        activate: @escaping () -> Void = { NSApp.activate() }
    ) {
        self.activate = activate
        self.preferences = preferences
        self.current = current
        self.windows = windows
        self.apply = apply
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let closing = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.refresh(excluding: closing) }
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh(excluding closing: ObjectIdentifier? = nil) {
        let open = DockPolicy.openWindowCount(windows(), excluding: closing)
        let wanted = DockPolicy.activationPolicy(openWindows: open, showInDock: preferences.showInDock)
        guard wanted != current else { return }
        current = wanted
        apply(wanted)
        // Moving to .regular from .accessory leaves the app inactive; bring it forward so the window
        // that caused the change is not buried.
        if wanted == .regular, open > 0 { activate() }
    }
}
