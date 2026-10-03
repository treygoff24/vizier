import Foundation
import VizierEngine

// Contracts the Linux desktop adapter lanes share.
// The coordinator owns this file; a lane that needs a change says so instead of editing it.

/// The desktop session the daemon runs in, read from the environment it was started with.
public struct DesktopSession: Sendable, Equatable, Codable {
    public enum Display: String, Sendable, Codable { case x11, wayland, none }
    /// The compositor or desktop family, which decides the injection route.
    public enum Family: String, Sendable, Codable { case gnome, kde, wlroots, hyprland, cosmic, other }

    public var display: Display
    public var family: Family
    /// `XDG_CURRENT_DESKTOP` as given, for doctor output.
    public var currentDesktop: String

    public init(display: Display, family: Family, currentDesktop: String) {
        self.display = display
        self.family = family
        self.currentDesktop = currentDesktop
    }
}

/// One adapter's readiness, for `vizier doctor` and for choosing a route at paste time.
public struct AdapterProbe: Sendable, Equatable, Codable {
    public var name: String
    public var available: Bool
    public var detail: String
    /// A command or step that makes it available, when it is not.
    public var fix: String?

    public init(name: String, available: Bool, detail: String, fix: String? = nil) {
        self.name = name
        self.available = available
        self.detail = detail
        self.fix = fix
    }
}

/// The key chord that pastes: Ctrl+V in most apps, Ctrl+Shift+V in terminals.
public enum PasteChord: String, Sendable, Codable, Equatable {
    case ctrlV = "ctrl+v"
    case ctrlShiftV = "ctrl+shift+v"
}

/// Puts text on the clipboard so a paste chord (or the user) can paste it.
public protocol ClipboardWriter: Sendable {
    var name: String { get }
    func probe() async -> AdapterProbe
    /// Returns once the text is published and this process (or its helper) still serves it.
    /// Throws when it could not be published; the caller then must not claim the clipboard.
    func publish(_ text: String) async throws
}

/// Sends a paste chord to the focused window.
public protocol KeySender: Sendable {
    var name: String { get }
    func probe() async -> AdapterProbe
    /// Throws only when no part of the chord can have reached the focused window; once a key may
    /// have gone out it returns, so the caller never retries a paste that may have landed (A16).
    func send(_ chord: PasteChord) async throws
}

/// The focused window as far as the desktop lets us see it.
public struct FocusedWindow: Sendable, Equatable {
    /// The app's name for the board and history, or "" when unknown.
    public var appName: String
    /// The app's process id, when known.
    public var pid: Int32?
    /// True when the focused app is known to be a terminal (paste with Ctrl+Shift+V); nil when unknown.
    public var isTerminal: Bool?

    public init(appName: String, pid: Int32?, isTerminal: Bool?) {
        self.appName = appName
        self.pid = pid
        self.isTerminal = isTerminal
    }
}

public protocol FocusReader: Sendable {
    func focusedWindow() async -> FocusedWindow?
}

/// A global shortcut source: calls `onToggle`/`onCancel` on the main actor when its keys fire.
public protocol HotkeySource: AnyObject, Sendable {
    var name: String { get }
    func probe() async -> AdapterProbe
    /// Registers the shortcuts; may show the desktop's consent dialog, so it runs from
    /// `vizier setup` or daemon start, never during a take.
    func start(onToggle: @escaping @MainActor @Sendable () -> Void, onCancel: @escaping @MainActor @Sendable () -> Void) async throws
    func stop() async
}
