import Testing
@testable import VizierEngine

@Suite struct RightCommandKeyTests {
    // Flags as macOS reports them: the combined Command flag plus a device bit per side.
    private let command: UInt64 = 0x10_0000
    private let rightBit = RightCommandKey.deviceRightCommandMask
    private let leftBit: UInt64 = 0x08

    @Test func pressingRightCommandFiresOnTheWayDown() {
        var key = RightCommandKey()
        #expect(key.isPress(keyCode: 0x36, flags: command | rightBit) == true)
        #expect(key.isPress(keyCode: 0x36, flags: 0) == false)
    }

    @Test func eachPressFiresOnce() {
        var key = RightCommandKey()
        #expect(key.isPress(keyCode: 0x36, flags: command | rightBit) == true)
        #expect(key.isPress(keyCode: 0x36, flags: 0) == false)
        #expect(key.isPress(keyCode: 0x36, flags: command | rightBit) == true)
    }

    @Test func releasingRightCommandWhileLeftCommandIsHeldIsNotAPress() {
        var key = RightCommandKey()
        _ = key.isPress(keyCode: 0x36, flags: command | rightBit | leftBit)
        #expect(key.isPress(keyCode: 0x36, flags: command | leftBit) == false)
        // The next press must still register, or a take could not be stopped.
        #expect(key.isPress(keyCode: 0x36, flags: command | rightBit | leftBit) == true)
    }

    @Test func leftCommandNeverFires() {
        var key = RightCommandKey()
        // Left Command going down while Right Command's bit is already set, as after a missed event.
        #expect(key.isPress(keyCode: 0x37, flags: command | leftBit | rightBit) == false)
    }

    @Test func aRepeatedDownEventWithoutAReleaseFiresOnce() {
        var key = RightCommandKey()
        _ = key.isPress(keyCode: 0x36, flags: command | rightBit)
        #expect(key.isPress(keyCode: 0x36, flags: command | rightBit) == false)
    }

    @Test func otherModifiersHeldStillStartATake() {
        var key = RightCommandKey()
        let shift: UInt64 = 0x2_0000
        #expect(key.isPress(keyCode: 0x36, flags: command | rightBit | shift) == true)
    }

    @Test func aMissedReleaseIsForgottenOnReset() {
        var key = RightCommandKey()
        _ = key.isPress(keyCode: 0x36, flags: command | rightBit)
        key.reset()
        #expect(key.isPress(keyCode: 0x36, flags: command | rightBit) == true)
    }

    // MARK: configurable right-hand modifier

    @Test func eachChoiceHasItsOwnKeyCodeAndDeviceBit() {
        #expect(HotkeyModifier.rightCommand.keyCode == 0x36)
        #expect(HotkeyModifier.rightOption.keyCode == 0x3D)
        #expect(HotkeyModifier.rightControl.keyCode == 0x3E)
        #expect(HotkeyModifier.rightCommand.deviceMask == 0x10)   // NX_DEVICERCMDKEYMASK
        #expect(HotkeyModifier.rightOption.deviceMask == 0x40)    // NX_DEVICERALTKEYMASK
        #expect(HotkeyModifier.rightControl.deviceMask == 0x2000) // NX_DEVICERCTLKEYMASK
        #expect(Set(HotkeyModifier.allCases.map(\.keyCode)).count == 3)
        #expect(Set(HotkeyModifier.allCases.map(\.deviceMask)).count == 3)
    }

    @Test func rightOptionFiresOnItsOwnKeyAndSideBit() {
        let option: UInt64 = 0x8_0000
        let leftOption: UInt64 = 0x20
        var key = RightModifierKey(.rightOption)
        #expect(key.isPress(keyCode: 0x3D, flags: option | HotkeyModifier.rightOption.deviceMask) == true)
        #expect(key.isPress(keyCode: 0x3D, flags: 0) == false)
        // Left Option never fires, even with the right bit stale in the flags.
        #expect(key.isPress(keyCode: 0x3A, flags: option | leftOption | HotkeyModifier.rightOption.deviceMask) == false)
    }

    @Test func rightControlFiresOnItsOwnKeyAndSideBit() {
        let control: UInt64 = 0x4_0000
        let leftControl: UInt64 = 0x01
        var key = RightModifierKey(.rightControl)
        #expect(key.isPress(keyCode: 0x3E, flags: control | HotkeyModifier.rightControl.deviceMask) == true)
        #expect(key.isPress(keyCode: 0x3E, flags: control | leftControl) == false) // right released, left held
        #expect(key.isPress(keyCode: 0x3E, flags: control | HotkeyModifier.rightControl.deviceMask | leftControl) == true)
    }

    @Test func aChoiceIgnoresTheOtherRightHandModifiers() {
        var key = RightModifierKey(.rightOption)
        #expect(key.isPress(keyCode: 0x36, flags: command | rightBit) == false)   // Right Command
        #expect(key.isPress(keyCode: 0x3E, flags: 0x4_0000 | HotkeyModifier.rightControl.deviceMask) == false) // Right Control
        var command = RightModifierKey(.rightCommand)
        #expect(command.isPress(keyCode: 0x3D, flags: 0x8_0000 | HotkeyModifier.rightOption.deviceMask) == false)
    }

    @Test func theDefaultIsRightCommandAndTheOldNameStillWorks() {
        #expect(RightModifierKey().modifier == .rightCommand)
        #expect(RightCommandKey().modifier == .rightCommand)
        #expect(HotkeyModifier(rawValue: "rightOption") == .rightOption)
        #expect(HotkeyModifier(rawValue: "leftOption") == nil)
    }
}
