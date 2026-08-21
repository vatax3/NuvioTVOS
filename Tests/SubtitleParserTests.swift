import XCTest
@testable import Nuvio

final class SubtitleParserTests: XCTestCase {
    func testParserPreservesUnicodeDialogue() {
        let subtitle = """
        1
        00:00:01,000 --> 00:00:03,000
        こんにちは — مرحباً

        """

        let cues = SubtitleParser.parse(subtitle)

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first?.text, "こんにちは — مرحباً")
    }

    func testParserStripsMarkupWithoutDiscardingAccentedCharacters() {
        let subtitle = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000 align:start
        <i>Déjà vu &amp; voilà</i>

        """

        XCTAssertEqual(SubtitleParser.parse(subtitle).first?.text, "Déjà vu & voilà")
    }

    // MARK: Charset detection

    /// The failure the old fallback chain could not catch. Windows-1252 decodes essentially any
    /// byte, so `String(data:encoding:.windowsCP1252)` never returned nil and every encoding
    /// behind it was unreachable — a Cyrillic subtitle came back as confident mojibake rather
    /// than as an error worth falling through on.
    func testCyrillicSubtitleIsNotDecodedAsWesternEuropean() {
        let line = "Привет, как дела?"
        guard let data = line.data(using: .windowsCP1251) else {
            return XCTFail("the fixture itself must encode as CP1251")
        }
        XCTAssertNotNil(
            String(data: data, encoding: .windowsCP1252),
            "the premise: CP1252 accepts these bytes rather than rejecting them"
        )

        XCTAssertEqual(SubtitleLoader.decodeSubtitleText(data), line)
    }

    func testGreekSubtitleSurvivesDetection() {
        let line = "Καλημέρα, τι κάνεις;"
        guard let data = line.data(using: .windowsCP1253) else {
            return XCTFail("the fixture itself must encode as CP1253")
        }
        XCTAssertEqual(SubtitleLoader.decodeSubtitleText(data), line)
    }

    /// UTF-8 is checked before detection runs: it is the common case, it validates itself, and a
    /// buffer that decodes cleanly should never be handed to a guess.
    func testValidUTF8IsNeverPassedToTheDetector() {
        let line = "こんにちは — مرحباً"
        XCTAssertEqual(SubtitleLoader.decodeSubtitleText(Data(line.utf8)), line)
    }

    /// A byte order mark must not survive into the text. Left in, it becomes a real U+FEFF in
    /// front of the first cue number, and the first cue of the file never parses.
    func testByteOrderMarkIsStrippedRatherThanDecoded() {
        let line = "1"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(line.data(using: .utf16LittleEndian)!)
        XCTAssertEqual(SubtitleLoader.decodeSubtitleText(utf16), line)

        var utf16BE = Data([0xFE, 0xFF])
        utf16BE.append(line.data(using: .utf16BigEndian)!)
        XCTAssertEqual(SubtitleLoader.decodeSubtitleText(utf16BE), line)

        // The common one: Windows editors write this in front of every SRT they save.
        var utf8 = Data([0xEF, 0xBB, 0xBF])
        utf8.append(Data(line.utf8))
        XCTAssertEqual(SubtitleLoader.decodeSubtitleText(utf8), line)
    }

    /// The whole point of stripping it: a BOM-marked file parses to the same cues as a bare one.
    func testFirstCueOfABOMMarkedFileStillParses() {
        let srt = "1\n00:00:01,000 --> 00:00:03,000\nDéjà vu\n\n"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(srt.utf8))

        let cues = SubtitleParser.parse(SubtitleLoader.decodeSubtitleText(data))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first?.text, "Déjà vu")
    }

    // MARK: Simultaneous cues

    private func showing(_ cues: [SubtitleCue], at time: Double) -> [String] {
        SubtitleTrackController.showing(
            cues,
            at: time,
            longestCue: SubtitleTrackController.longestCueDuration(in: cues)
        ).map(\.text)
    }

    private let overlappingDialogue = [
        SubtitleCue(start: 0, end: 4, text: "Where were you?"),
        SubtitleCue(start: 2, end: 6, text: "Nowhere."),
        SubtitleCue(start: 10, end: 12, text: "Later.")
    ]

    /// Two speakers talking over each other. Returning one cue dropped the other, and lost
    /// dialogue looks like a subtitle that was simply never written.
    func testOverlappingCuesAreAllReturned() {
        XCTAssertEqual(showing(overlappingDialogue, at: 3), ["Where were you?", "Nowhere."])
    }

    /// A cue whose neighbour has not started yet, and one whose neighbour has already ended.
    func testOnlyCuesCoveringTheInstantAreReturned() {
        XCTAssertEqual(showing(overlappingDialogue, at: 5), ["Nowhere."])
        XCTAssertEqual(showing(overlappingDialogue, at: 8), [])
        XCTAssertEqual(showing(overlappingDialogue, at: 11), ["Later."])
    }

    /// A cue ends on its end stamp rather than covering it, so back-to-back cues never both show.
    func testCueBoundariesDoNotOverlapEachOther() {
        let backToBack = [
            SubtitleCue(start: 0, end: 2, text: "First"),
            SubtitleCue(start: 2, end: 4, text: "Second")
        ]
        XCTAssertEqual(showing(backToBack, at: 2), ["Second"])
    }

    /// A seek backwards must find what is on screen there, not what was on screen before it —
    /// and the backward walk must not be fooled by a long gap between cues.
    func testSeekingAcrossALongGapFindsTheCuesAtTheNewPosition() {
        let sparse = [
            SubtitleCue(start: 0, end: 2, text: "First"),
            SubtitleCue(start: 100, end: 102, text: "Last")
        ]
        XCTAssertEqual(showing(sparse, at: 101), ["Last"])
        XCTAssertEqual(showing(sparse, at: 1), ["First"])
        XCTAssertEqual(showing(sparse, at: 50), [])
    }

    func testEmptyTrackShowsNothing() {
        XCTAssertEqual(showing([], at: 0), [])
    }
}
