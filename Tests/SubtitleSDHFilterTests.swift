import XCTest
@testable import Nuvio

/// The filter has to be conservative in one direction and thorough in the other: leaving a
/// sound effect on screen is untidy, but eating a line of dialogue is the same failure as the
/// dropped-overlapping-cue bug — invisible, and indistinguishable from a bad subtitle file.
final class SubtitleSDHFilterTests: XCTestCase {
    func testBracketedSoundEffectsAreRemoved() {
        XCTAssertEqual(SubtitleSDHFilter.strip("[DOOR CREAKS] Who's there?"), "Who's there?")
        XCTAssertEqual(SubtitleSDHFilter.strip("Wait. [gunshot]"), "Wait.")
    }

    /// A cue that was nothing but an effect leaves no empty box behind.
    func testCuesThatAreOnlyAnnotationAreDropped() {
        XCTAssertNil(SubtitleSDHFilter.strip("[THUNDER RUMBLING]"))
        XCTAssertNil(SubtitleSDHFilter.strip("- [SIGHS]"))
    }

    func testUpperCaseSpeakerLabelsAreRemoved() {
        XCTAssertEqual(SubtitleSDHFilter.strip("MAN: Get down!"), "Get down!")
        XCTAssertEqual(SubtitleSDHFilter.strip("WOMAN #2: Over here."), "Over here.")
        XCTAssertEqual(SubtitleSDHFilter.strip("- NARRATOR: It began in June."), "- It began in June.")
    }

    /// The half that matters more. A colon in ordinary dialogue is not a speaker label, and a
    /// filter that cannot tell the difference silently rewrites the film.
    func testOrdinaryDialogueWithAColonSurvives() {
        XCTAssertEqual(SubtitleSDHFilter.strip("But then: nothing."), "But then: nothing.")
        XCTAssertEqual(SubtitleSDHFilter.strip("It's 12:30 already."), "It's 12:30 already.")
        XCTAssertEqual(SubtitleSDHFilter.strip("Rule one: you don't talk about it."),
                       "Rule one: you don't talk about it.")
    }

    /// Parentheses are used in dialogue, so only the shouted ones are an SDH convention.
    func testOnlyShoutedParentheticalsAreRemoved() {
        XCTAssertEqual(SubtitleSDHFilter.strip("(LAUGHS) I knew it."), "I knew it.")
        XCTAssertEqual(SubtitleSDHFilter.strip("The one (from before) is fine."),
                       "The one (from before) is fine.")
    }

    func testMultiLineCuesKeepTheirRemainingLines() {
        let cue = "[PHONE RINGING]\nAre you going to get that?"
        XCTAssertEqual(SubtitleSDHFilter.strip(cue), "Are you going to get that?")
    }

    func testNonSDHTrackIsLeftAlone() {
        let dialogue = "I told you already.\nTwice, in fact."
        XCTAssertEqual(SubtitleSDHFilter.strip(dialogue), dialogue)
    }

    /// Cue timings are untouched; only the text changes, and emptied cues disappear entirely.
    func testCueListKeepsTimingsAndDropsEmptiedCues() {
        let cues = [
            SubtitleCue(start: 0, end: 2, text: "[MUSIC PLAYING]"),
            SubtitleCue(start: 2, end: 5, text: "MAN: We're late.")
        ]

        let filtered = SubtitleSDHFilter.strip(cues)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.text, "We're late.")
        XCTAssertEqual(filtered.first?.start, 2)
        XCTAssertEqual(filtered.first?.end, 5)
    }
}
