/// The right-hand modifier keys Vizier accepts as its hotkey.
///
/// Right Command is the default: it belongs to dictation, leaving Left Command for ordinary
/// shortcuts. Right Option and Right Control are the
/// alternatives for people whose Right Command does other work. Each has a physical key code and a
/// device bit in the event's flags that is set only while that one key is down.
public enum HotkeyModifier: String, Sendable, CaseIterable, Equatable {
    case rightCommand
    case rightOption
    case rightControl

    /// The virtual key code of the physical key (kVK_RightCommand, kVK_RightOption, kVK_RightControl).
    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: 0x36
        case .rightOption: 0x3D
        case .rightControl: 0x3E
        }
    }

    /// The device-dependent flag bit for this side only: NX_DEVICERCMDKEYMASK, NX_DEVICERALTKEYMASK,
    /// NX_DEVICERCTLKEYMASK. The combined Command/Option/Control flags are also set by the left key,
    /// so a press is read from this bit.
    public var deviceMask: UInt64 {
        switch self {
        case .rightCommand: 0x10
        case .rightOption: 0x40
        case .rightControl: 0x2000
        }
    }

    public var displayName: String {
        switch self {
        case .rightCommand: "Right Command"
        case .rightOption: "Right Option"
        case .rightControl: "Right Control"
        }
    }

    /// "Right ⌘": the short form for tags and labels.
    public var legend: String { "Right \(keycap)" }

    /// The keycap legend, as printed on a Mac keyboard.
    public var keycap: String {
        switch self {
        case .rightCommand: "⌘"
        case .rightOption: "⌥"
        case .rightControl: "⌃"
        }
    }
}

/// Turns modifier-change events into presses of the chosen right-hand modifier.
///
/// A take starts or stops the moment the key goes down, with no wait for the release and no check
/// for a chord. The press is read from the key's right-hand device bit in the event's flags, not
/// the combined modifier flag, which the left key also sets; so a release of the right key while the
/// left key is held is not mistaken for a press.
public struct RightModifierKey: Sendable {
    public static let keyCode: UInt16 = HotkeyModifier.rightCommand.keyCode
    /// NX_DEVICERCMDKEYMASK: set while the right-hand Command key is down.
    public static let deviceRightCommandMask: UInt64 = HotkeyModifier.rightCommand.deviceMask

    public let modifier: HotkeyModifier
    private var isDown = false

    public init(_ modifier: HotkeyModifier = .rightCommand) {
        self.modifier = modifier
    }

    /// True exactly once per physical press of the chosen key.
    public mutating func isPress(keyCode: UInt16, flags: UInt64) -> Bool {
        guard keyCode == modifier.keyCode else { return false }
        let down = flags & modifier.deviceMask != 0
        defer { isDown = down }
        return down && !isDown
    }

    /// Forgets the key's state, as when the event tap was disabled and events were missed.
    public mutating func reset() {
        isDown = false
    }
}

/// The name the hotkey had while Right Command was the only choice.
public typealias RightCommandKey = RightModifierKey
