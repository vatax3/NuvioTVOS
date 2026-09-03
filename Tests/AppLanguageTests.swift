import XCTest
@testable import Nuvio

/// The picker was recorded as a platform constraint and was not one. These pin the two things
/// that would silently break it: an unknown stored value, and a language with no table.
final class AppLanguageTests: XCTestCase {
    func testAStoredCodeResolves() {
        XCTAssertEqual(AppLanguage.from("fr"), .french)
        XCTAssertEqual(AppLanguage.from("en"), .english)
    }

    /// Empty means "follow the television", which is the default and not an error.
    func testNothingStoredMeansSystem() {
        XCTAssertEqual(AppLanguage.from(nil), .system)
        XCTAssertEqual(AppLanguage.from(""), .system)
    }

    /// A code from a build that shipped more tables than this one must not become a picker entry
    /// that changes nothing.
    func testALanguageWeDoNotShipFallsBackToSystem() {
        XCTAssertEqual(AppLanguage.from("de"), .system)
        XCTAssertEqual(AppLanguage.from("zz"), .system)
    }

    /// Only what is actually in the bundle is offered.
    func testEveryOfferedLanguageHasATable() {
        for language in AppLanguage.allCases where language != .system {
            XCTAssertNotNil(
                Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                "\(language.rawValue) is offered but has no table"
            )
        }
    }

    /// Named in its own language, so somebody looking for French finds "Français".
    func testLanguagesAreNamedInThemselves() {
        XCTAssertEqual(AppLanguage.french.displayName, "Français")
        XCTAssertEqual(AppLanguage.english.displayName, "English")
    }

    /// Switching must actually change a lookup, and switching back must restore it. Uses a key
    /// whose two tables genuinely differ.
    func testChoosingALanguageChangesWhatIsLookedUp() {
        defer { L10n.use(.system) }
        L10n.use(.english)
        let english = L10n.text("navigation.library")
        L10n.use(.french)
        let french = L10n.text("navigation.library")
        XCTAssertNotEqual(english, french)
        XCTAssertEqual(french, "Bibliothèque")
    }
}
