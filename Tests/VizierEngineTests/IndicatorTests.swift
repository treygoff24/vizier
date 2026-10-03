import Foundation
import Testing
@testable import VizierEngine

@Suite struct WordLineTests {
    private func render(_ line: WordLine) -> String {
        line.plates.map { $0.settled ? $0.text : "(\($0.text))" }.joined(separator: " ")
    }

    @Test func interimWordsSettleAfterHoldingThroughARevision() {
        var line = WordLine()
        line.update(settled: "", pending: "the zorblex quaxil is")
        #expect(render(line) == "(the) (zorblex) (quaxil) (is)")
        line.update(settled: "", pending: "the zorblex quaxil is ready now")
        #expect(render(line) == "the zorblex quaxil is (ready) (now)")
    }

    @Test func aRevisedWordTurnsBackToATailPlate() {
        var line = WordLine()
        line.update(settled: "", pending: "a b c d e")
        line.update(settled: "", pending: "a b c d e f")
        #expect(render(line) == "a b c d (e) (f)")
        line.update(settled: "", pending: "a B c d e f g")
        #expect(render(line) == "a (B) c d e (f) (g)")
    }

    @Test func finalsAreSettledAtOnce() {
        var line = WordLine()
        line.update(settled: "Zorblex quaxil.", pending: "then more")
        #expect(render(line) == "Zorblex quaxil. (then) (more)")
    }

    @Test func finishingShowsThePastedTextAllSettled() {
        var line = WordLine()
        line.update(settled: "", pending: "um the zorblex")
        line.finish("The Zorblex.")
        #expect(render(line) == "The Zorblex.")
    }

    @Test func pastSixtyFourPlatesTheRowKeepsTheNewestFortyAndStaysPut() {
        var line = WordLine()
        let words = (1...65).map { "w\($0)" }
        line.update(settled: words.joined(separator: " "), pending: "")
        #expect(line.plates.count == 40)
        #expect(line.plates.first?.text == "w26")
        #expect(line.plates.last?.text == "w65")
        line.update(settled: (words + ["w66"]).joined(separator: " "), pending: "")
        #expect(line.plates.count == 41)
        #expect(line.plates.first?.text == "w26")
    }

    @Test func aLineThatShrinksBelowTheTrimShowsItsNewestWords() {
        var line = WordLine()
        line.update(settled: (1...65).map { "w\($0)" }.joined(separator: " "), pending: "")
        line.finish((1...20).map { "v\($0)" }.joined(separator: " "))
        #expect(line.plates.count == 20)
        #expect(line.plates.first?.text == "v1")
    }
}

@Suite struct LevelMeterTests {
    private func meanSquare(db: Double) -> Float { Float(pow(10, db / 10)) }

    @Test func mapsSixtyTwoDecibelsBelowFullScaleToDarkAndMinusTwentyTwoToFull() {
        #expect(LevelMeter.target(meanSquare: 0) == 0)
        #expect(abs(LevelMeter.target(meanSquare: meanSquare(db: -62))) < 1e-6)
        #expect(abs(LevelMeter.target(meanSquare: meanSquare(db: -42)) - 0.5) < 1e-6)
        #expect(abs(LevelMeter.target(meanSquare: meanSquare(db: -22)) - 1) < 1e-6)
        #expect(LevelMeter.target(meanSquare: meanSquare(db: -10)) == 1)
        #expect(LevelMeter.target(meanSquare: 1) == 1)
    }

    @Test func risesInTwentyFourMillisecondsAndFallsInOneFifty() {
        var meter = LevelMeter()
        let loud = meanSquare(db: -10)
        meter.step(meanSquare: loud, seconds: 0.024)
        #expect(abs(meter.level - (1 - exp(-1))) < 1e-9)
        meter.step(meanSquare: loud, seconds: 1)
        let top = meter.level
        meter.step(meanSquare: 0, seconds: 0.150)
        #expect(abs(meter.level - top * exp(-1)) < 1e-9)
    }
}
