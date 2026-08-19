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
}
