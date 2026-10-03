import Testing
@testable import VizierEngine

// Synthetic words only. Real replacement lists live in ~/.config/vizier and never in the repo.
@Suite struct WordReplacerTests {
    private func replace(_ text: String, _ lines: String) throws -> String {
        try WordReplacer(rules: ReplacementsFile.parse(lines)).apply(to: text)
    }

    @Test func replacesWholeWordsCaseInsensitively() throws {
        #expect(try replace("Ship the Zorbex build, then ZORBEX again.", "zorbex -> Zorblex") ==
            "Ship the Zorblex build, then Zorblex again.")
    }

    @Test func leavesMatchesInsideLargerWords() throws {
        #expect(try replace("concatenate the cat", "cat -> dog") == "concatenate the dog")
        #expect(try replace("cats and bobcat", "cat -> dog") == "cats and bobcat")
    }

    @Test func punctuationAndDigitsAreBoundariesOrNot() throws {
        #expect(try replace("(qux), qux. \"qux\"", "qux -> Q") == "(Q), Q. \"Q\"")
        #expect(try replace("qux2 and 2qux", "qux -> Q") == "qux2 and 2qux")
    }

    @Test func everyVariantOnALineMapsToItsReplacement() throws {
        let rules = "plin ko, plinko, plink oh -> Plinko"
        #expect(try replace("plin ko then Plink Oh then plinko", rules) == "Plinko then Plinko then Plinko")
    }

    @Test func longestVariantWinsAtAPosition() throws {
        let rules = "grav -> G\ngrav port -> Gravport"
        #expect(try replace("open grav port and grav", rules) == "open Gravport and G")
    }

    @Test func outputIsNeverReplacedAgain() throws {
        // Upstream applied rules one after another, so "alpha" could chain through to "gamma".
        let rules = "alpha -> beta\nbeta -> gamma"
        #expect(try replace("alpha beta", rules) == "beta gamma")
    }

    @Test func replacementTextIsLiteral() throws {
        #expect(try replace("price tag", "price -> $1 \\0") == "$1 \\0 tag")
    }

    @Test func regexCharactersInVariantsAreLiteral() throws {
        #expect(try replace("use c++ or c", "c++ -> CPP") == "use CPP or c")
    }

    @Test func nonSpacedScriptsMatchAsSubstrings() throws {
        // The boundary class already ignores Han neighbors; a Latin neighbor shows the substring path.
        #expect(try replace("東京都に行く", "東京 -> Tokyo") == "Tokyo都に行く")
        #expect(try replace("go東京", "東京 -> Tokyo") == "goTokyo")
    }

    @Test func decomposedTextMatchesComposedVariant() throws {
        let decomposed = "cafe\u{0301} open"
        #expect(try replace(decomposed, "café -> Cafe") == "Cafe open")
    }

    @Test func noRulesLeavesTextAlone() throws {
        #expect(try replace("anything at all", "# only a comment\n\n") == "anything at all")
    }
}

@Suite struct ReplacementsFileTests {
    @Test func parsesCommentsBlanksAndArrowsInReplacements() throws {
        let rules = try ReplacementsFile.parse("# header\n\nfoo, bar -> a -> b, c\r\n  \n")
        #expect(rules == [ReplacementRule(variants: ["foo", "bar"], replacement: "a -> b, c")])
    }

    @Test func rejectsALineWithoutArrow() {
        #expect(throws: ReplacementsFile.LineError(line: 2, reason: "missing \"->\" between the words and their replacement")) {
            try ReplacementsFile.parse("ok -> fine\nbroken line\n")
        }
    }

    @Test func rejectsEmptySides() {
        #expect(throws: ReplacementsFile.LineError.self) { try ReplacementsFile.parse("foo ->  \n") }
        #expect(throws: ReplacementsFile.LineError.self) { try ReplacementsFile.parse(" , -> bar\n") }
    }

    @Test func rejectsTheSameVariantOnTwoLines() {
        #expect(throws: ReplacementsFile.LineError(line: 2, reason: "\"FOO\" already has a rule on line 1")) {
            try ReplacementsFile.parse("foo -> a\nFOO -> b\n")
        }
    }

    @Test func aHashInsideALineIsNotAComment() throws {
        #expect(try ReplacementsFile.parse("c sharp -> C#") == [ReplacementRule(variants: ["c sharp"], replacement: "C#")])
    }
}
