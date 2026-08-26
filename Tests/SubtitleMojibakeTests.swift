import XCTest
@testable import Nuvio

/// The failure charset detection cannot see: text whose encoding is correct and whose contents
/// are not. Upstream's own cases are included, since a repair that misses what they reported
/// would be a repair in name only.
final class SubtitleMojibakeTests: XCTestCase {
    func testTheApostropheEveryoneReports() {
        XCTAssertEqual(SubtitleMojibake.sanitize("Itâ€™s great!"), "It’s great!")
    }

    func testTheSequencesUpstreamListed() {
        XCTAssertEqual(SubtitleMojibake.sanitize("â™ª lalala â™ª"), "♪ lalala ♪")
        XCTAssertEqual(SubtitleMojibake.sanitize("â™« song playing â™«"), "♫ song playing ♫")
        XCTAssertEqual(SubtitleMojibake.sanitize("â€˜Helloâ€™"), "‘Hello’")
        XCTAssertEqual(SubtitleMojibake.sanitize("â€œQuoteâ€\u{9D}"), "“Quote”")
        XCTAssertEqual(SubtitleMojibake.sanitize("Wait â€“ what â€” whyâ€¦"), "Wait – what — why…")
        XCTAssertEqual(SubtitleMojibake.sanitize("Â¿CÃ³mo estÃ¡s? Â¡Bien!"), "¿Cómo estás? ¡Bien!")
        XCTAssertEqual(SubtitleMojibake.sanitize("Â«HolaÂ»"), "«Hola»")
    }

    /// The point of undoing the transformation rather than tabulating it.
    ///
    /// The samples are not typed out — they are *generated* the way the damage is produced, by
    /// reading correct UTF-8 back as Latin-1. Typing them by hand is how the first draft of this
    /// test went wrong: the C1 controls inside a damaged multi-byte sequence are invisible, and
    /// dropping one silently changes the input.
    ///
    /// Latin-1 rather than Windows-1252, because Latin-1 maps all 256 byte values and so can
    /// damage anything. Windows-1252 leaves five positions undefined and Foundation refuses
    /// them in both directions, which is exactly why `windows1252Bytes` writes its own mapping.
    /// The Windows-1252 flavour of the same damage is covered by the typed cases above.
    func testAnyDoubleEncodingIsUndone() throws {
        for truth in [
            "\u{041F}\u{440}\u{438}\u{432}\u{435}\u{442}, \u{43C}\u{438}\u{440}",
            "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{4E16}\u{754C}",
            "\u{39A}\u{3B1}\u{3BB}\u{3B7}\u{3BC}\u{3AD}\u{3C1}\u{3B1}",
            "It\u{2019}s a \u{201C}quote\u{201D} \u{2014} really\u{2026}",
            "\u{266A} lalala \u{266A}",
            "K\u{F8}b en bl\u{E5} h\u{E6}r"
        ] {
            let broken = try XCTUnwrap(
                String(data: Data(truth.utf8), encoding: .isoLatin1),
                "could not damage this sample"
            )
            XCTAssertNotEqual(broken, truth, "the sample was not actually damaged")
            XCTAssertEqual(SubtitleMojibake.sanitize(broken), truth)
        }
    }

    /// The guard that matters most. A subtitle in real French is full of the same lead
    /// characters mojibake starts with, and rewriting it would break working tracks.
    func testHealthyAccentedProseIsLeftExactlyAsItIs() {
        for line in [
            "Le château est très beau.",
            "Ça va, mon frère ?",
            "Où êtes-vous allés ?",
            "Anaïs a déjà mangé.",
            "Größe und Maß",
            "El niño está aquí"
        ] {
            XCTAssertEqual(SubtitleMojibake.sanitize(line), line, "rewrote healthy text: \(line)")
        }
    }

    func testCleanTextIsUntouched() {
        let clean = "Hello, world! 123 ♪ ♫ “test”"
        XCTAssertEqual(SubtitleMojibake.sanitize(clean), clean)
    }

    /// Non-Latin text cannot even be encoded back to Windows-1252, so the repair declines it
    /// rather than mangling a Cyrillic or CJK track that decoded perfectly well.
    func testTextTheCodepageCannotHoldIsDeclined() {
        for line in ["Привет, мир", "こんにちは世界", "Καλημέρα κόσμε", "مرحبا بالعالم"] {
            XCTAssertEqual(SubtitleMojibake.sanitize(line), line)
        }
    }

    func testReplacementCharactersAreRemoved() {
        XCTAssertEqual(SubtitleMojibake.sanitize("Hello \u{FFFD}world\u{FFFD}"), "Hello world")
    }

    func testEmptyAndPlainInputSurvive() {
        XCTAssertEqual(SubtitleMojibake.sanitize(""), "")
        XCTAssertEqual(SubtitleMojibake.sanitize("1\n00:00:01,000 --> 00:00:02,000\nGo."),
                       "1\n00:00:01,000 --> 00:00:02,000\nGo.")
    }

    /// A whole cue, through the same path the engine uses, so the wiring is covered and not
    /// only the function.
    func testAnSrtBodyIsRepairedEndToEnd() {
        let broken = "1\n00:00:01,000 --> 00:00:03,000\nâ™ª Itâ€™s a long way â™ª\n"
        let data = Data(broken.utf8)

        let decoded = SubtitleLoader.decodeSubtitleText(data)

        XCTAssertTrue(decoded.contains("♪ It’s a long way ♪"), decoded)
    }

    /// Genuinely Windows-1252 bytes still decode by detection, and must not then be "repaired"
    /// a second time — the two stages have to compose.
    func testASingleByteTrackIsDecodedAndLeftAlone() {
        let data = "Le château est très beau.".data(using: .windowsCP1252)!

        XCTAssertEqual(SubtitleLoader.decodeSubtitleText(data), "Le château est très beau.")
    }
}
