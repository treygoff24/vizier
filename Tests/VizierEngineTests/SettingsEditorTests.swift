import Foundation
import Testing
@testable import VizierEngine

@Suite struct SettingsEditorTests {
    private func edit(_ text: String, to id: String = "gemini-clean") throws -> String {
        try SettingsEditor.replacingTopLevelString(named: "mode", with: id, in: text)
    }

    @Test func theStarterFileChangesOnlyTheModeValue() throws {
        let before = ConfigStore.starterSettings
        let after = try edit(before)
        #expect(after == before.replacingOccurrences(of: "\"mode\": \"\(VizierConfig.Settings().mode)\",\n  \"modes\"", with: "\"mode\": \"gemini-clean\",\n  \"modes\""))
        #expect(after.contains("// The mode every take runs through."))
        #expect(after.contains("\"mode\": \"verbatim\","), "nested transcriber modes stay")
        #expect(after.contains("\"mode\": \"VERBATIM\","))
        #expect(try ConfigStore.parseSettings(after).mode == "gemini-clean")
    }

    @Test func nestedModeKeysAreNotTheTopLevelOne() throws {
        let text = "{ \"modes\": [{ \"mode\": \"inner\", \"x\": { \"mode\": \"deeper\" } }], \"mode\": \"outer\" }"
        #expect(try edit(text, to: "new") == "{ \"modes\": [{ \"mode\": \"inner\", \"x\": { \"mode\": \"deeper\" } }], \"mode\": \"new\" }")
    }

    @Test func modeInsideCommentsAndStringValuesIsText() throws {
        // The decoys sit inside the object, at the depth where the real key lives, so a scanner
        // that fails to skip a comment or a string value sees a second key and refuses the edit.
        let text = """
        {
          // "mode": "commented",
          /* "mode": "blocked" */ "name": "mode",
          "mode": "real"
        }
        """
        let expected = text.replacingOccurrences(of: "\"mode\": \"real\"", with: "\"mode\": \"new\"")
        #expect(try edit(text, to: "new") == expected)
    }

    @Test func escapedQuotesInsideStringsDoNotEndThem() throws {
        // A scanner that closes the string at the escaped quote then reads `mode:` as a key.
        let text = "{ \"x\": \"a\\\" mode: \\\"fake\\\"\", \"mode\": \"real\" }"
        #expect(try edit(text, to: "new") == "{ \"x\": \"a\\\" mode: \\\"fake\\\"\", \"mode\": \"new\" }")
    }

    @Test func unquotedKeysAndSingleQuotedValuesAreJSON5() throws {
        let text = "{ mode: 'scribe', modes: [] }"
        #expect(try edit(text, to: "new") == "{ mode: \"new\", modes: [] }")
    }

    @Test func aMissingTopLevelModeIsAnError() {
        #expect(throws: SettingsEditor.Failure.missingKey("mode")) {
            try edit("{ \"modes\": [{ \"mode\": \"inner\" }] }")
        }
    }

    @Test func twoTopLevelModesAreAnError() {
        #expect(throws: SettingsEditor.Failure.duplicateKey("mode")) {
            try edit("{ \"mode\": \"a\", \"mode\": \"b\" }")
        }
    }

    @Test func aNonStringModeIsAnError() {
        #expect(throws: SettingsEditor.Failure.valueNotAString("mode")) {
            try edit("{ \"mode\": { \"id\": \"a\" } }")
        }
    }

    @Test func theNewValueIsEscaped() throws {
        #expect(try edit("{ \"mode\": \"a\" }", to: "q\"b\\c") == "{ \"mode\": \"q\\\"b\\\\c\" }")
    }

    @Test func controlCharactersInTheNewValueAreEscaped() throws {
        #expect(try edit("{ \"mode\": \"a\" }", to: "a\nb\tc\u{01}d") == "{ \"mode\": \"a\\nb\\tc\\u0001d\" }")
    }

    @Test func anUnclosedBlockCommentIsAnError() {
        #expect(throws: SettingsEditor.Failure.unterminated("comment")) {
            try edit("{ \"mode\": \"a\" /* never closed")
        }
    }

    @Test func aLineCommentMarkerInsideABlockCommentDoesNotEndIt() throws {
        // A scanner that switches to line-comment mode at the inner `//` would run to the newline,
        // miss `*/`, and then read the decoy `mode` key on the next line as the real one.
        let text = "{ /* // not a line comment\n \"mode\": \"decoy\" */ \"mode\": \"real\" }"
        #expect(try edit(text, to: "new") == "{ /* // not a line comment\n \"mode\": \"decoy\" */ \"mode\": \"new\" }")
    }
}
