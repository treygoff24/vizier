import Testing
@testable import VizierEngine

/// Synthetic sentences in the shapes Scribe and Gemini VERBATIM write fillers.
@Suite struct FillerFilterTests {
    @Test(arguments: [
        // Scribe's comma-framed fillers
        ("Um, the zorblex runs.", "The zorblex runs."),
        ("Okay. Uh, before the quaxil ships.", "Okay. Before the quaxil ships."),
        ("Point it at the, uh, gantry file.", "Point it at the gantry file."),
        ("I need you to, um, uh, set up the quaxil.", "I need you to set up the quaxil."),
        ("Send it to the agent, uh, Zorblex.", "Send it to the agent, Zorblex."),
        ("Mm, pretty straightforward.", "Pretty straightforward."),
        ("Keep the stuff, uh.", "Keep the stuff."),
        ("Is that right, uh?", "Is that right?"),
        // Gemini VERBATIM's bare fillers
        ("we save um ideas for uh stuff", "we save ideas for stuff"),
        // Cut-off fragments
        ("I didn't just s- skip it.", "I didn't just skip it."),
        ("when you say, like, w- when you run it", "when you say, when you run it"),
        ("S- so the quaxil works.", "So the quaxil works."),
        ("Then go- going to the gantry.", "Then going to the gantry."),
        ("Point it at the- the quaxil.", "Point it at the quaxil."),
        // A whole word trailed off on, then a thinking sound live Scribe wrote for the pause
        ("all the goals we desire and- Mm-hmm ... works for the zorblex.", "all the goals we desire and works for the zorblex."),
        ("We need the- quaxil first.", "We need the quaxil first."),
        ("So I was thinking, hmm, maybe the quaxil.", "So I was thinking, maybe the quaxil."),
        ("Ship it. Hmm... let me think.", "Ship it. Let me think."),
        // A trailing-off filler is not a sentence end, and an ended sentence keeps its own stop
        ("Ship the rest of this. Um... But yeah, go.", "Ship the rest of this. But yeah, go."),
        ("Ship it, um... but wait.", "Ship it, but wait."),
        ("Is it done? Uh?", "Is it done?"),
        // Apple's comma-set-off "you know", "I mean", and "like"
        ("It runs, you know, on the quaxil.", "It runs, on the quaxil."),
        ("Point it at the, you know, gantry file.", "Point it at the gantry file."),
        ("We shipped the zorblex, I mean, the quaxil.", "We shipped the zorblex, the quaxil."),
        ("It was, like, a lot of quaxil.", "It was a lot of quaxil."),
        ("Rank them by, like, five.", "Rank them by, five."),
        ("The gantry, like, runs.", "The gantry, runs."),
        ("Send, like, the zorblex.", "Send, the zorblex."),
        ("I, like, love the gantry.", "I love the gantry."),
        ("Ok, so, You know, I mean, like, it works.", "Ok, so, it works."),
        // Nothing but fillers
        ("Um, uh.", ""),
        ("", ""),
    ])
    func removesFillersAndMendsTheGap(input: String, expected: String) {
        #expect(FillerFilter.apply(to: input) == expected)
    }

    @Test(arguments: [
        "Cut the quaxil to 10 mm long.",
        "Go to the ER now.",
        "The UM campus is open.",
        "Uh-huh, that works.",
        "Mm-hmm.",
        "Both pre- and post-launch checks pass.",
        "The x-ray of the zorblex is fine.",
        "I, I want the, the gantry.",
        "Hmm, not sure about the quaxil.",
        "Mm-hmm, that works. Hmm?",
        "Wait for it... Then ship.",
        "Well — the zorblex; it runs.",
        // The same words, not set off by commas on both sides, are speech
        "I like it.",
        "I like the zorblex, and the quaxil.",
        "Do you know the quaxil?",
        "Do you know, I think so.",
        "You know, it works.",
        "What I mean is the zorblex.",
        "I mean, it works.",
        "It was big, I mean it.",
        "Like, the zorblex runs.",
        "It runs like, the quaxil.",
        "Things like the gantry, you know the one.",
        "Things, like the gantry, run.",
        "It worked, you know.",
        "Ship it, like.",
        "Did it run, I mean?",
        "It worked, you know; it did.",
    ])
    func leavesEveryOtherWordAlone(input: String) {
        #expect(FillerFilter.apply(to: input) == input)
    }

    @Test func keepsLineBreaks() {
        #expect(FillerFilter.apply(to: "Um, first line.\nSecond, uh, line.") == "First line.\nSecond, line.")
    }
}
