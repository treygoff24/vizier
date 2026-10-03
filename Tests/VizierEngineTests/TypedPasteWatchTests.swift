import Testing
@testable import VizierEngine

@Suite struct TypedPasteWatchTests {
    @Test func withNoTakeThereIsNoNote() {
        let watch = TypedPasteWatch()
        // Inside the window of a stop at time zero, so a missing stop cannot pass as one at zero.
        #expect(watch.note(at: 1) == nil)
    }

    @Test func aCommandVBeforeViziersPasteIsNotedAsSuch() {
        var watch = TypedPasteWatch()
        watch.takeStopped(at: 10)
        #expect(watch.note(at: 10.2) == "typed Cmd+V 200 ms after the stop tap, before Vizier's paste")
    }

    @Test func aCommandVAfterViziersPasteCarriesBothTimings() {
        var watch = TypedPasteWatch()
        watch.takeStopped(at: 10)
        watch.pasted(at: 10.25)
        #expect(watch.note(at: 14.15) == "typed Cmd+V 4150 ms after the stop tap, 3900 ms after Vizier's paste")
    }

    @Test func aCommandVPastTheWindowIsNotNoted() {
        var watch = TypedPasteWatch()
        watch.takeStopped(at: 10)
        watch.pasted(at: 10.25)
        #expect(watch.note(at: 10 + TypedPasteWatch.window) == nil)
    }

    @Test func aTakeThatEndedWithoutAPasteLeavesNothingToNote() {
        var watch = TypedPasteWatch()
        watch.takeStopped(at: 10)
        watch.endedWithoutPaste()
        #expect(watch.note(at: 10.3) == nil)
    }

    @Test func aNewTakeClearsTheLastPaste() {
        var watch = TypedPasteWatch()
        watch.takeStopped(at: 10)
        watch.pasted(at: 10.3)
        watch.takeStopped(at: 10.8)
        #expect(watch.note(at: 10.9) == "typed Cmd+V 100 ms after the stop tap, before Vizier's paste")
    }
}
