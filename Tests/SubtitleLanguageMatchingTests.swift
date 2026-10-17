import XCTest
@testable import Nuvio

/// A preferred subtitle language that matched nothing, silently.
///
/// `SubtitleSelector` compared raw strings with `hasPrefix`, so a viewer who chose Spanish and a
/// track tagged `spa` — which is what OpenSubtitles, the addon we install by default, serves —
/// produced **no match at all**. Not a lower rank: nothing, so the preference found no track and
/// the automatic selection fell through to whatever the file listed first. The same for `fr`
/// against `fre`/`fra`, `de` against `ger`/`deu`, `nl` against `dut`/`nld`.
///
/// This is 1.0.38's `slang` defect in a second place, and the aggravating detail is that
/// `MediaLanguage.normalise` was written for exactly this comparison and this path never called
/// it. The tests therefore pin the *behaviour through the selector*, not the normaliser — the
/// normaliser was already correct and already covered.
@MainActor
final class SubtitleLanguageMatchingTests: XCTestCase {
    private func subtitle(_ id: String, lang: String) -> Subtitle {
        Subtitle(id: id, url: "https://example.test/\(id).srt", lang: lang, addonName: nil)
    }

    // MARK: The pairs that did not match

    /// One assertion per pair, because each is a language a viewer could have had silently denied.
    func testATwoLetterPreferenceMatchesTheThreeLetterTrack() {
        let pairs = [
            ("es", "spa"), ("es", "esp"), ("es", "spn"),
            ("fr", "fre"), ("fr", "fra"),
            ("de", "ger"), ("de", "deu"),
            ("nl", "dut"), ("nl", "nld"),
            ("zh", "chi"), ("zh", "zho"),
            ("pt", "por"), ("pt", "pob"),
            ("el", "gre"), ("cs", "cze")
        ]

        for (preference, trackCode) in pairs {
            let tracks = [subtitle("other", lang: "fin"), subtitle("wanted", lang: trackCode)]
            XCTAssertEqual(
                SubtitleSelector.autoSelection(tracks, preferred: preference)?.id,
                "wanted",
                "\(preference) must match a track tagged \(trackCode)"
            )
        }
    }

    /// And the other direction, because the preference is a catalogue code but a *track* can be
    /// the two-letter one while the stored preference came from an older build.
    func testAThreeLetterPreferenceMatchesTheTwoLetterTrack() {
        let tracks = [subtitle("other", lang: "fin"), subtitle("wanted", lang: "es")]
        XCTAssertEqual(
            SubtitleSelector.autoSelection(tracks, preferred: "spa")?.id, "wanted"
        )
    }

    /// Ranking, not only selection: the picker's order was wrong in the same way, so a Spanish
    /// viewer's tracks sat below every other language in the list.
    func testOrderingRanksTheNormalisedMatchFirst() {
        let tracks = [
            subtitle("fi", lang: "fin"),
            subtitle("es", lang: "spa"),
            subtitle("de", lang: "ger")
        ]

        let ordered = SubtitleSelector.order(
            tracks, preferred: "es", secondary: "de", onlyPreferred: false
        )

        XCTAssertEqual(ordered.map(\.id), ["es", "de", "fi"])
    }

    /// With *only my languages* on, the failure was worse than a bad order: the filter kept
    /// nothing, so the picker was empty for a viewer whose tracks were all present.
    func testOnlyPreferredDoesNotEmptyThePickerForAThreeLetterTrack() {
        let tracks = [subtitle("fi", lang: "fin"), subtitle("es", lang: "spa")]

        let ordered = SubtitleSelector.order(
            tracks, preferred: "es", secondary: "", onlyPreferred: true
        )

        XCTAssertEqual(ordered.map(\.id), ["es"])
    }

    // MARK: Region subtags

    /// A viewer asking for Portuguese means the Brazilian track as well. The old `hasPrefix`
    /// comparison got this one case right, and it had to survive the fix — trading a silent miss
    /// on `spa` for a silent miss on `pt-BR` would be no improvement.
    func testARegionalVariantStillMatchesTheLanguage() {
        let tracks = [subtitle("br", lang: "pt-BR")]
        XCTAssertEqual(SubtitleSelector.autoSelection(tracks, preferred: "pt")?.id, "br")
    }

    /// And the direction the prefix comparison never handled: the catalogue offers
    /// *Portuguese (Brazil)* as its own choice, so choosing it must reach a plain `pt` track
    /// rather than nothing.
    func testChoosingARegionReachesTheUnmarkedTrack() {
        let tracks = [subtitle("pt", lang: "por")]
        XCTAssertEqual(SubtitleSelector.autoSelection(tracks, preferred: "pt-BR")?.id, "pt")
    }

    /// Reaching it does not mean preferring it: an exact regional match outranks the same
    /// language from elsewhere, whichever order the addon listed them in.
    func testTheExactRegionIsPreferredOverTheSameLanguageElsewhere() {
        let tracks = [subtitle("plain", lang: "pt"), subtitle("brazil", lang: "pt-BR")]

        XCTAssertEqual(SubtitleSelector.autoSelection(tracks, preferred: "pt-BR")?.id, "brazil")
        XCTAssertEqual(
            SubtitleSelector.order(tracks, preferred: "pt-BR", secondary: "", onlyPreferred: false)
                .map(\.id),
            ["brazil", "plain"]
        )
    }

    // MARK: What must not start matching

    /// The guard on the whole change: normalising must not make unrelated codes equal. `sq` is
    /// Albanian and `sr` is Serbian, and both have three-letter forms that look alike.
    func testNormalisingDoesNotCollapseDifferentLanguages() {
        let tracks = [subtitle("albanian", lang: "alb"), subtitle("serbian", lang: "srp")]

        XCTAssertEqual(SubtitleSelector.autoSelection(tracks, preferred: "sq")?.id, "albanian")
        XCTAssertEqual(SubtitleSelector.autoSelection(tracks, preferred: "sr")?.id, "serbian")
    }

    /// Serbo-Croatian is left alone deliberately. It is a macrolanguage covering Serbian, Croatian
    /// and Bosnian, so resolving it to one of them would be a guess dressed as a normalisation —
    /// upstream's own fix for it was about the *label*, not the matching.
    func testSerboCroatianIsNotResolvedToOneOfItsLanguages() {
        let tracks = [subtitle("hbs", lang: "hbs")]

        XCTAssertNil(SubtitleSelector.autoSelection(tracks, preferred: "sr"))
        XCTAssertNil(SubtitleSelector.autoSelection(tracks, preferred: "hr"))
        XCTAssertEqual(SubtitleSelector.autoSelection(tracks, preferred: "hbs")?.id, "hbs")
    }

    /// The placeholder is not a language tag, and resolving codes must not have changed that.
    func testThePlaceholderStillMatchesNothing() {
        let tracks = [subtitle("fi", lang: "fin"), subtitle("fr", lang: "fre")]
        XCTAssertNil(SubtitleSelector.autoSelection(tracks, preferred: "device"))
    }

    // MARK: The label

    /// `displayLanguage` asked Foundation directly, which answers for 639-1 and leaves the
    /// three-letter forms unresolved — so a Spanish track was labelled `SPA` in the picker, and
    /// grouping by language made `SPA` its own group beside `Spanish`.
    func testAThreeLetterTrackIsNamedRatherThanShouted() {
        let spanish = subtitle("es", lang: "spa").displayLanguage

        XCTAssertNotEqual(spanish, "SPA")
        XCTAssertEqual(spanish, subtitle("es2", lang: "es").displayLanguage)
    }

    /// Grouping follows the label, so the two spellings of one language are now one group.
    func testTwoSpellingsOfOneLanguageAreOneGroup() {
        let groups = SubtitleSelector.group(
            [subtitle("a", lang: "spa"), subtitle("b", lang: "es")], mode: .byLanguage
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.items.count, 2)
    }
}
