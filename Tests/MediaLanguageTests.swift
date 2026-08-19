import XCTest
@testable import Nuvio

final class MediaLanguageTests: XCTestCase {
    func testCatalogueMatchesTheAndroidList() {
        XCTAssertEqual(MediaLanguage.all.count, 78)
        XCTAssertTrue(MediaLanguage.all.contains { $0.code == "pt-br" })
        XCTAssertTrue(MediaLanguage.all.contains { $0.code == "es-419" })
    }

    /// Files label a French track `fre` about as often as `fra`, and a viewer's preference has
    /// to match both or auto-selection silently does nothing.
    func testBibliographicCodesResolveToTheCatalogueSpelling() {
        XCTAssertEqual(MediaLanguage.normalise("fre"), "fr")
        XCTAssertEqual(MediaLanguage.normalise("fra"), "fr")
        XCTAssertEqual(MediaLanguage.normalise("ger"), "de")
        XCTAssertEqual(MediaLanguage.normalise("dut"), "nl")
        XCTAssertEqual(MediaLanguage.normalise("cze"), "cs")
    }

    func testRegionsAreKeptWhenTheCatalogueListsThemAndDroppedOtherwise() {
        XCTAssertEqual(MediaLanguage.normalise("pt-BR"), "pt-br")
        XCTAssertEqual(MediaLanguage.normalise("en-GB"), "en")
        XCTAssertEqual(MediaLanguage.normalise("es_419"), "es-419")
    }

    func testUnknownCodesSurviveRatherThanBecomingEmpty() {
        XCTAssertEqual(MediaLanguage.normalise("qqq"), "qqq")
        XCTAssertNil(MediaLanguage.named(""))
        XCTAssertNil(MediaLanguage.named(nil))
    }

    func testNamesAreResolvedForBothCodeLengths() {
        XCTAssertEqual(MediaLanguage.named("fr"), MediaLanguage.named("fre"))
        XCTAssertNotNil(MediaLanguage.named("ja"))
    }
}
