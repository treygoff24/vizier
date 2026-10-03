import VizierEngine
import Testing

@Suite struct PasteTextTests {
    @Test func aTakeEndsWithOneSpaceSoTheNextTakeStartsANewWord() {
        let first = PasteText.separated("Go do that as well.")
        let second = PasteText.separated("I think we're good.")
        #expect(first == "Go do that as well. ")
        #expect(first + second == "Go do that as well. I think we're good. ")
    }

    @Test func textAlreadyEndingInWhitespaceGetsNoSecondSpace() {
        #expect(PasteText.separated("First paragraph.\n\n") == "First paragraph.\n\n")
        #expect(PasteText.separated("trailing ") == "trailing ")
        #expect(PasteText.separated("") == "")
    }
}
