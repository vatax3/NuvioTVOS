import XCTest
@testable import Nuvio

/// Reported: a French television always landing on a Finnish subtitle track, one row above the
/// French forced track the file itself marked as default.
///
/// Two causes. `subtitle_preferred_language` defaulted to empty, so no `slang` list ever reached
/// mpv; and we had overridden `subs-fallback` to `yes`, which widens the fallback to *any* track
/// when the language preference finds nothing. The preferred language now defaults to the
/// device's own, which is the choice the viewer could not even make — "Device language" was
/// offered for audio and not for subtitles.
@MainActor
final class SubtitleSelectionDefaultsTests: XCTestCase {
    private func subtitle(_ id: String, lang: String) -> Subtitle {
        Subtitle(id: id, url: id, lang: lang, addonName: nil)
    }

    /// The trap this nearly walked into: `device` is a placeholder, not a language tag. Passed
    /// through unresolved it matches no track at all, so the automatic selection would have
    /// silently stopped choosing anything — a different bug wearing the same symptom.
    func testThePlaceholderIsNotATrackLanguage() {
        let tracks = [subtitle("fi", lang: "fin"), subtitle("fr", lang: "fre")]
        XCTAssertNil(
            SubtitleSelector.autoSelection(tracks, preferred: "device"),
            "the raw placeholder must not be handed to track matching"
        )
        XCTAssertNotNil(
            SubtitleSelector.autoSelection(tracks, preferred: "fre"),
            "a resolved code selects normally"
        )
    }

    /// The default, and that it resolves rather than reaching the engine as the literal word.
    func testThePreferredLanguageDefaultsToTheDeviceAndResolves() {
        let settings = AppSettings()
        XCTAssertEqual(settings.player.subtitlePreferredLanguage, "device")

        let resolved = settings.subtitleTrackLanguages
        XCTAssertFalse(resolved.contains("device"), "the placeholder must not survive resolution")
        XCTAssertEqual(resolved.first, Locale.current.language.languageCode?.identifier)
    }

    /// Choosing "None" has to remain possible: it stores an empty string, which is a value and
    /// not an absence, so the new default does not override it.
    func testChoosingNoneStillTurnsAutomaticSelectionOff() {
        let settings = AppSettings()
        let original = settings.player.subtitlePreferredLanguage
        settings.player.subtitlePreferredLanguage = ""
        XCTAssertEqual(settings.player.subtitlePreferredLanguage, "")
        XCTAssertTrue(settings.subtitleTrackLanguages.isEmpty)
        settings.player.subtitlePreferredLanguage = original
    }
}

/// The HDR diagnostic added alongside: source colorimetry against what libplacebo is actually
/// presenting. A missing answer has to read as unknown — claiming the output matches the source
/// when we cannot see it is the one way this diagnostic must not fail.
final class PlaybackColorimetryTests: XCTestCase {
    func testBothHalvesAreJoined() {
        XCTAssertEqual(MPVEngine.colorimetry(gamma: "pq", primaries: "bt.2020"), "pq · bt.2020")
    }

    func testOneHalfIsEnough() {
        XCTAssertEqual(MPVEngine.colorimetry(gamma: "pq", primaries: nil), "pq")
        XCTAssertEqual(MPVEngine.colorimetry(gamma: nil, primaries: "bt.709"), "bt.709")
    }

    func testNothingKnownReadsAsUnknownRatherThanAsAMatch() {
        XCTAssertNil(MPVEngine.colorimetry(gamma: nil, primaries: nil))
        XCTAssertNil(MPVEngine.colorimetry(gamma: "", primaries: "  "))
    }
}
