import XCTest
@testable import Nuvio

/// Whether a newer build exists, decided from the sideloading feed.
final class AppUpdateCheckTests: XCTestCase {
    private func feed(_ versions: [(String, String)]) -> Data {
        let entries = versions.map {
            """
            {"version": "\($0.0)", "buildVersion": "1", "date": "2026-08-26",
             "localizedDescription": "\($0.1)",
             "downloadURL": "https://github.com/vatax3/NuvioTVOS/releases/download/v\($0.0)/Nuvio-\($0.0)-tvOS-unsigned.ipa",
             "size": 1}
            """
        }.joined(separator: ",")
        return Data(#"{"apps": [{"versions": [\#(entries)]}]}"#.utf8)
    }

    // MARK: Comparing versions

    /// The reason this is not a string compare. Lexically "1.0.9" sorts *after* "1.0.23", which
    /// would announce an update backwards for nine releases out of every ten.
    func testDoubleDigitPatchesCompareAsNumbers() {
        XCTAssertTrue(AppUpdateCheck.isNewer("1.0.23", than: "1.0.9"))
        XCTAssertFalse(AppUpdateCheck.isNewer("1.0.9", than: "1.0.23"))
    }

    func testTheSameVersionIsNotAnUpdate() {
        XCTAssertFalse(AppUpdateCheck.isNewer("1.0.23", than: "1.0.23"))
    }

    func testEveryComponentCounts() {
        XCTAssertTrue(AppUpdateCheck.isNewer("1.1.0", than: "1.0.99"))
        XCTAssertTrue(AppUpdateCheck.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertFalse(AppUpdateCheck.isNewer("1.0.99", than: "1.1.0"))
    }

    /// A running build ahead of the feed is a development build, not an update.
    func testABuildAheadOfTheFeedIsNotOfferedAnUpdate() {
        XCTAssertFalse(AppUpdateCheck.isNewer("1.0.23", than: "1.0.24"))
    }

    func testShortAndLongFormsOfTheSameVersionAreEqual() {
        XCTAssertFalse(AppUpdateCheck.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(AppUpdateCheck.isNewer("1.1.0", than: "1.1"))
        XCTAssertTrue(AppUpdateCheck.isNewer("1.1.1", than: "1.1"))
    }

    func testGarbageComponentsDoNotAnnounceAnUpdate() {
        XCTAssertFalse(AppUpdateCheck.isNewer("", than: "1.0.23"))
        XCTAssertFalse(AppUpdateCheck.isNewer("nightly", than: "1.0.23"))
    }

    // MARK: Reading the feed

    func testTheNewestEntryIsTheOneOffered() {
        let available = AppUpdateCheck.available(
            in: feed([("1.0.24", "New things"), ("1.0.23", "Older")]), current: "1.0.23"
        )

        XCTAssertEqual(available?.version, "1.0.24")
        XCTAssertEqual(available?.notes, "New things")
        XCTAssertTrue(available?.downloadURL.hasSuffix("Nuvio-1.0.24-tvOS-unsigned.ipa") ?? false)
    }

    func testNothingIsOfferedWhenTheFeedMatches() {
        XCTAssertNil(AppUpdateCheck.available(in: feed([("1.0.23", "")]), current: "1.0.23"))
    }

    /// A feed that fails to parse, is empty, or names a version with no download must produce
    /// silence rather than a card the viewer cannot act on.
    func testAnUnusableFeedOffersNothing() {
        XCTAssertNil(AppUpdateCheck.newest(in: Data("<html>".utf8)))
        XCTAssertNil(AppUpdateCheck.newest(in: Data(#"{"apps": []}"#.utf8)))
        XCTAssertNil(AppUpdateCheck.newest(in: Data(#"{"apps": [{"versions": []}]}"#.utf8)))
        XCTAssertNil(AppUpdateCheck.newest(
            in: Data(#"{"apps": [{"versions": [{"version": "1.0.24", "downloadURL": ""}]}]}"#.utf8)
        ))
    }

    func testTheFeedItReadsIsTheOneAltStoreReads() {
        XCTAssertEqual(
            AppUpdateCheck.feedURL,
            "https://raw.githubusercontent.com/vatax3/NuvioTVOS/main/altstore-source.json"
        )
    }
}
