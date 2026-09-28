import XCTest
import SwiftUI
@testable import Nuvio

/// A palette built from one colour the viewer chose.
///
/// Upstream drives this with a three-colour hex dialog and an on-screen picker; the picker is the
/// bulk of that and the part worth not copying, because choosing a hue with a D-pad is the reason
/// nobody uses such a control. What is left is the derivation, and the derivation has to be right
/// or the viewer ends up with a theme they cannot navigate.
final class CustomThemePaletteTests: XCTestCase {
    func testAHexValueIsReadWithOrWithoutItsHash() {
        XCTAssertEqual(CustomThemePalette.components(fromHex: "#E5484D")?.red, 0xE5)
        XCTAssertEqual(CustomThemePalette.components(fromHex: "e5484d")?.green, 0x48)
        XCTAssertEqual(CustomThemePalette.components(fromHex: "  E5484D  ")?.blue, 0x4D)
    }

    /// Android writes these as `AARRGGBB`. The alpha is dropped rather than honoured: a
    /// translucent accent would make the focus ring unreadable against the picture.
    func testAnAndroidStyleValueLosesItsAlphaRatherThanItsColour() {
        XCTAssertEqual(
            CustomThemePalette.components(fromHex: "FFE5484D").map(CustomThemePalette.hex),
            "E5484D"
        )
    }

    /// A half-typed value has to be refused, not resolved. Resolving it to black would replace the
    /// viewer's theme with an unusable one while they were still typing.
    func testAnIncompleteValueIsRefused() {
        XCTAssertNil(CustomThemePalette.components(fromHex: "E54"))
        XCTAssertNil(CustomThemePalette.components(fromHex: "ZZZZZZ"))
        XCTAssertNil(CustomThemePalette.components(fromHex: ""))
    }

    func testAnUnreadableValueFallsBackToTheDefaultAccent() {
        let palette = ThemeColors.palette(for: .custom, accentHex: "nonsense")

        XCTAssertEqual(palette.secondary, CustomThemePalette.color(fromHex: CustomThemePalette.defaultHex))
    }

    // MARK: The derivation

    func testThePressedShadeIsDarkerThanTheAccent() {
        let accent = (red: 0xE5, green: 0x48, blue: 0x4D)
        let pressed = CustomThemePalette.shifted(accent, towards: 0, amount: 0.22)

        XCTAssertLessThan(pressed.red, accent.red)
        XCTAssertLessThan(pressed.green, accent.green)
    }

    func testTheFocusRingIsLighterThanTheAccent() {
        let accent = (red: 0xE5, green: 0x48, blue: 0x4D)
        let ring = CustomThemePalette.shifted(accent, towards: 255, amount: 0.35)

        XCTAssertGreaterThan(ring.green, accent.green)
    }

    /// The card is a surface text is read on, so it stays within a few points of neutral — it
    /// carries the accent's hue, not its saturation.
    func testTheCardStaysCloseToNeutral() {
        let card = CustomThemePalette.tintedSurface(
            (red: 0xE5, green: 0x48, blue: 0x4D), base: 20, weight: 0.05
        )

        XCTAssertLessThan(card.red, 60)
        XCTAssertLessThan(abs(card.red - card.green), 20)
    }

    /// The reason the `white` preset overrides `onSecondary` by hand. A pale accent with white
    /// text on it is a button nobody can read.
    func testAPaleAccentGetsDarkTextOnIt() {
        XCTAssertTrue(CustomThemePalette.prefersDarkForeground((red: 0xF5, green: 0xF5, blue: 0xF5)))
        XCTAssertFalse(CustomThemePalette.prefersDarkForeground((red: 0xE5, green: 0x48, blue: 0x4D)))
        XCTAssertFalse(CustomThemePalette.prefersDarkForeground((red: 0x10, green: 0x10, blue: 0x10)))
    }

    func testTheCustomThemeIsOfferedAlongsideThePresets() {
        XCTAssertTrue(AppTheme.allCases.contains(.custom))
        // And the presets are untouched by the accent, which is only read for the custom one.
        XCTAssertEqual(
            ThemeColors.palette(for: .ocean, accentHex: "FFFFFF").secondary,
            ThemeColors.palette(for: .ocean).secondary
        )
    }
}

/// The completions offered above the search field.
final class SearchSuggestionsTests: XCTestCase {
    private let catalogue = [
        "Jurassic Park", "Jurassic World", "The Wolf of Wall Street",
        "Slow Horses", "Parks and Recreation", "Interstellar"
    ]

    func testAnExactMatchOutranksAPrefixWhichOutranksASubstring() {
        XCTAssertEqual(SearchSuggestions.rank(title: "Jurassic Park", query: "jurassic park"), 0)
        XCTAssertEqual(SearchSuggestions.rank(title: "Jurassic Park", query: "juras"), 1)
        XCTAssertEqual(SearchSuggestions.rank(title: "Parks and Recreation", query: "recre"), 2)
    }

    func testWordsCanBeMatchedOutOfOrder() {
        XCTAssertEqual(
            SearchSuggestions.rank(title: "The Wolf of Wall Street", query: "wolf wall"), 3
        )
    }

    /// Each query word has to consume a *different* title word, or a repeated word would match
    /// anything containing it once.
    func testAWordCannotBeMatchedTwiceByTheSameTitleWord() {
        XCTAssertNil(SearchSuggestions.rank(title: "The Wolf", query: "wolf wolf"))
    }

    func testASingleWordThatDoesNotAppearIsNotAMatch() {
        XCTAssertNil(SearchSuggestions.rank(title: "Interstellar", query: "jurassic"))
    }

    /// The mistake upstream records: sorting equal ranks alphabetically put five titles ahead of
    /// *Jurassic Park* for "juras", past the few completions a television keyboard shows.
    func testTiesKeepTheAddonsOwnRelevanceOrder() {
        let ranked = SearchSuggestions.ranked(
            names: ["Jurassic Park", "Jurassic World"], query: "juras"
        )

        XCTAssertEqual(ranked, ["Jurassic Park", "Jurassic World"])
    }

    func testBetterMatchesComeFirstWhateverOrderTheyArrivedIn() {
        let ranked = SearchSuggestions.ranked(
            names: ["Parks and Recreation", "Jurassic Park"], query: "park"
        )

        // "Parks and Recreation" is a prefix match, so it wins over the substring — despite the
        // other one being the more famous film.
        XCTAssertEqual(ranked.first, "Parks and Recreation")
    }

    func testTheStripIsCapped() {
        let many = (0..<40).map { "Jurassic \($0)" }

        XCTAssertEqual(SearchSuggestions.ranked(names: many, query: "juras").count, SearchSuggestions.maximum)
    }

    func testDuplicatesAcrossAddonsAreOfferedOnce() {
        let ranked = SearchSuggestions.ranked(
            names: ["Jurassic Park", "jurassic park", "Jurassic World"], query: "juras"
        )

        XCTAssertEqual(ranked.count, 2)
    }

    // MARK: Merging catalogs

    /// One position at a time, so whichever addon answered first cannot fill the strip on its own.
    func testCatalogsAreInterleavedRatherThanConcatenated() {
        let merged = SearchSuggestions.merged(byCatalog: [["A1", "A2", "A3"], ["B1", "B2"]])

        XCTAssertEqual(merged, ["A1", "B1", "A2", "B2", "A3"])
    }

    func testMergingDropsDuplicatesWhicheverCatalogTheyCameFrom() {
        let merged = SearchSuggestions.merged(byCatalog: [["A1", "Shared"], ["Shared", "B2"]])

        XCTAssertEqual(merged, ["A1", "Shared", "B2"])
    }

    func testMergingNothingIsNotAFailure() {
        XCTAssertTrue(SearchSuggestions.merged(byCatalog: []).isEmpty)
        XCTAssertTrue(SearchSuggestions.merged(byCatalog: [[], []]).isEmpty)
    }
}

/// When the launch screen is on screen.
final class StartupSplashPolicyTests: XCTestCase {
    func testTheSplashCoversALaunchHeadingForHome() {
        XCTAssertTrue(
            StartupSplashPolicy.showsSplash(enabled: true, isComplete: false, destination: .home)
        )
        XCTAssertTrue(
            StartupSplashPolicy.showsSplash(enabled: true, isComplete: false, destination: .loading)
        )
    }

    /// A cold launch into a deep link is one whose destination the viewer already named. Covering
    /// it with a logo delays the only thing they asked for.
    func testADeepLinkIsNotCoveredByALogo() {
        XCTAssertFalse(
            StartupSplashPolicy.showsSplash(enabled: true, isComplete: false, destination: .content)
        )
    }

    /// First run is its own branded first impression; a logo in front of it would be the second
    /// full-screen thing between the viewer and the app they just installed.
    func testFirstRunIsNotCoveredEither() {
        XCTAssertFalse(
            StartupSplashPolicy.showsSplash(enabled: true, isComplete: false, destination: .setup)
        )
    }

    func testItGoesAwayWhenStartupFinishes() {
        XCTAssertFalse(
            StartupSplashPolicy.showsSplash(enabled: true, isComplete: true, destination: .home)
        )
    }

    func testItIsNeverShownWhenSwitchedOff() {
        for destination in [
            StartupSplashPolicy.Destination.loading, .setup, .home, .content
        ] {
            XCTAssertFalse(
                StartupSplashPolicy.showsSplash(
                    enabled: false, isComplete: false, destination: destination
                )
            )
        }
    }

    // MARK: Not two loading states at once

    /// The reason the second rule exists. The splash and Home's skeleton rails both say "still
    /// getting ready", and drawing them together stacks two of them on one screen.
    func testHomesLoaderWaitsForTheSplashToFinish() {
        XCTAssertFalse(
            StartupSplashPolicy.showsHomeLoader(
                isLoading: true, splashEnabled: true, isComplete: false
            )
        )
    }

    /// And takes over once it has, so a slow addon does not leave an empty screen.
    func testHomesLoaderTakesOverAfterwards() {
        XCTAssertTrue(
            StartupSplashPolicy.showsHomeLoader(
                isLoading: true, splashEnabled: true, isComplete: true
            )
        )
    }

    func testHomesLoaderIsUnaffectedWhenTheSplashIsOff() {
        XCTAssertTrue(
            StartupSplashPolicy.showsHomeLoader(
                isLoading: true, splashEnabled: false, isComplete: false
            )
        )
    }
}
