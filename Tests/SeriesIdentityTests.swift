import XCTest
@testable import Nuvio

/// When two content ids name the same show.
final class SeriesIdentityTests: XCTestCase {
    private struct Row: Equatable {
        var contentId: String
        var imdbId: String?
        var activity: Date
    }

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    private func dedupe(_ rows: [Row]) -> [Row] {
        SeriesIdentity.deduplicated(
            rows, contentId: \.contentId, imdbId: \.imdbId, activity: \.activity
        )
    }

    // MARK: The key

    /// The bridge: an anime addon's own id, whose metadata still carries the IMDb id.
    func testTheImdbIdIsWhatSiblingsAgreeOn() {
        XCTAssertEqual(
            SeriesIdentity.canonicalKey(contentId: "kitsu:12345", imdbId: "tt0903747"),
            SeriesIdentity.canonicalKey(contentId: "tmdb:1396", imdbId: "tt0903747")
        )
    }

    /// An addon may hand the IMDb id back as the content id itself, and that has to reach the
    /// same key as a row that carries it separately.
    func testAnImdbContentIdReachesTheSameKey() {
        XCTAssertEqual(
            SeriesIdentity.canonicalKey(contentId: "tt0903747", imdbId: nil),
            SeriesIdentity.canonicalKey(contentId: "kitsu:12345", imdbId: "tt0903747")
        )
    }

    func testCaseAndPaddingDoNotMakeANewShow() {
        XCTAssertEqual(
            SeriesIdentity.canonicalKey(contentId: "x", imdbId: "  TT0903747 "),
            SeriesIdentity.canonicalKey(contentId: "x", imdbId: "tt0903747")
        )
    }

    /// A title with no IMDb id keys on itself, so it groups with nothing. That is the right
    /// answer: there is no evidence it is anybody's sibling, and guessing would merge two shows.
    func testATitleWithNoImdbIdGroupsWithNothing() {
        let a = SeriesIdentity.canonicalKey(contentId: "kitsu:1", imdbId: nil)
        let b = SeriesIdentity.canonicalKey(contentId: "kitsu:2", imdbId: nil)

        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, "kitsu:1")
    }

    /// Something that is not an IMDb id must not be treated as one, or every row carrying the
    /// same rubbish would merge into a single show.
    func testANonImdbValueIsNotUsedAsTheBridge() {
        XCTAssertEqual(
            SeriesIdentity.canonicalKey(contentId: "kitsu:1", imdbId: "unknown"),
            "kitsu:1"
        )
        XCTAssertNotEqual(
            SeriesIdentity.canonicalKey(contentId: "kitsu:1", imdbId: "unknown"),
            SeriesIdentity.canonicalKey(contentId: "kitsu:2", imdbId: "unknown")
        )
    }

    func testAnEmptyImdbIdIsNoImdbId() {
        XCTAssertEqual(
            SeriesIdentity.canonicalKey(contentId: "kitsu:1", imdbId: "   "),
            "kitsu:1"
        )
    }

    // MARK: Deduplicating

    /// The bug: two episodes watched through two addons, one show, two rows in the rail, each
    /// offering a different next episode.
    func testOneShowWatchedThroughTwoAddonsIsOneRow() {
        let rows = [
            Row(contentId: "tt0903747", imdbId: "tt0903747", activity: at(0)),
            Row(contentId: "kitsu:12345", imdbId: "tt0903747", activity: at(100))
        ]
        let kept = dedupe(rows)

        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.contentId, "kitsu:12345", "the one last watched")
    }

    /// Most recent rather than first or most complete: the row a viewer last touched is the
    /// addon they are actually watching it on.
    func testTheMostRecentRowWinsWhicheverOrderTheyArrive() {
        let older = Row(contentId: "a", imdbId: "tt1", activity: at(0))
        let newer = Row(contentId: "b", imdbId: "tt1", activity: at(100))

        XCTAssertEqual(dedupe([older, newer]).first?.contentId, "b")
        XCTAssertEqual(dedupe([newer, older]).first?.contentId, "b")
    }

    /// A rail that reshuffles on every refresh is its own bug, so ties keep the order they
    /// arrived in.
    func testATieKeepsTheIncomingOrder() {
        let rows = [
            Row(contentId: "a", imdbId: "tt1", activity: at(0)),
            Row(contentId: "b", imdbId: "tt1", activity: at(0))
        ]
        XCTAssertEqual(dedupe(rows).map(\.contentId), ["a"])
        XCTAssertEqual(dedupe(rows.reversed()).map(\.contentId), ["b"])
    }

    func testDifferentShowsAreUntouched() {
        let rows = [
            Row(contentId: "tt1", imdbId: "tt1", activity: at(0)),
            Row(contentId: "tt2", imdbId: "tt2", activity: at(100)),
            Row(contentId: "kitsu:9", imdbId: nil, activity: at(50))
        ]
        XCTAssertEqual(dedupe(rows).count, 3)
    }

    /// Order is what the rail draws, so everything that survives has to stay where it was.
    func testSurvivingRowsKeepTheirRelativeOrder() {
        let rows = [
            Row(contentId: "first", imdbId: "tt1", activity: at(0)),
            Row(contentId: "second", imdbId: "tt2", activity: at(0)),
            Row(contentId: "third", imdbId: "tt3", activity: at(0))
        ]
        XCTAssertEqual(dedupe(rows).map(\.contentId), ["first", "second", "third"])
    }

    /// Three ids for one show collapse to one, not two.
    func testThreeSiblingsCollapseToOne() {
        let rows = [
            Row(contentId: "tt1", imdbId: "tt1", activity: at(0)),
            Row(contentId: "kitsu:1", imdbId: "tt1", activity: at(200)),
            Row(contentId: "tmdb:1", imdbId: "tt1", activity: at(100))
        ]
        let kept = dedupe(rows)

        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.contentId, "kitsu:1")
    }

    func testNothingIsNotAnError() {
        XCTAssertTrue(dedupe([]).isEmpty)
    }
}
