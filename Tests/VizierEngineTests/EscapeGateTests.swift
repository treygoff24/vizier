import Testing
@testable import VizierEngine

@Suite struct EscapeGateTests {
    @Test func idleEscapePassesThrough() {
        var gate = EscapeGate()
        #expect(gate.keyDown(at: 10, isRepeat: false, takeIsCancelable: false) == .pass)
        #expect(gate.keyUp() == .pass)
    }

    @Test func oneEscapeCancelsAndIsSwallowedWithItsRelease() {
        var gate = EscapeGate()
        #expect(gate.keyDown(at: 10, isRepeat: false, takeIsCancelable: true) == .swallowAndCancel)
        #expect(gate.keyUp() == .swallow)
    }

    @Test func mashedEscapesInsideTheWindowAreSwallowedWithoutASecondCancel() {
        var gate = EscapeGate()
        _ = gate.keyDown(at: 10, isRepeat: false, takeIsCancelable: true)
        _ = gate.keyUp()
        // The take is gone after the cancel, and the presses keep coming.
        for t in [10.15, 10.4, 10.7, 10.99] {
            #expect(gate.keyDown(at: t, isRepeat: false, takeIsCancelable: false) == .swallow)
            #expect(gate.keyUp() == .swallow)
        }
    }

    @Test func aPressWhileTheCancelIsStillInFlightDoesNotCancelTwice() {
        var gate = EscapeGate()
        _ = gate.keyDown(at: 10, isRepeat: false, takeIsCancelable: true)
        _ = gate.keyUp()
        #expect(gate.keyDown(at: 10.05, isRepeat: false, takeIsCancelable: true) == .swallow)
    }

    @Test func theWindowIsFixedFromTheCancelAndDoesNotSlide() {
        var gate = EscapeGate()
        _ = gate.keyDown(at: 10, isRepeat: false, takeIsCancelable: true)
        _ = gate.keyUp()
        _ = gate.keyDown(at: 10.9, isRepeat: false, takeIsCancelable: false)
        _ = gate.keyUp()
        #expect(gate.keyDown(at: 11.0, isRepeat: false, takeIsCancelable: false) == .pass)
        #expect(gate.keyUp() == .pass)
    }

    @Test func aHeldCancelKeyStaysSwallowedPastTheWindow() {
        var gate = EscapeGate()
        _ = gate.keyDown(at: 10, isRepeat: false, takeIsCancelable: true)
        #expect(gate.keyDown(at: 10.5, isRepeat: true, takeIsCancelable: false) == .swallow)
        #expect(gate.keyDown(at: 12.0, isRepeat: true, takeIsCancelable: false) == .swallow)
        #expect(gate.keyUp() == .swallow)
    }

    @Test func aHeldIdleKeyKeepsPassing() {
        var gate = EscapeGate()
        #expect(gate.keyDown(at: 10, isRepeat: false, takeIsCancelable: false) == .pass)
        #expect(gate.keyDown(at: 10.5, isRepeat: true, takeIsCancelable: false) == .pass)
        #expect(gate.keyUp() == .pass)
    }

    @Test func aLaterTakeCanBeCanceledAgain() {
        var gate = EscapeGate()
        _ = gate.keyDown(at: 10, isRepeat: false, takeIsCancelable: true)
        _ = gate.keyUp()
        #expect(gate.keyDown(at: 20, isRepeat: false, takeIsCancelable: true) == .swallowAndCancel)
    }
}
