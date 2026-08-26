import XCTest
@testable import Nuvio

/// Which resume points a Continue Watching removal takes off the tracking account.
///
/// Deleting from somebody's Trakt or Simkl account is not a local edit, so the matching gets a
/// test of its own — the failures worth guarding against are deleting too much, not too little.
final class RemoteResumePointRemovalTests: XCTestCase {
    private let sessions = [
        RemoteResumePointRemoval.Session(sessionId: 1, contentId: "tt0903747", season: 1, episode: 3),
        RemoteResumePointRemoval.Session(sessionId: 2, contentId: "tt0903747", season: 2, episode: 1),
        RemoteResumePointRemoval.Session(sessionId: 3, contentId: "tt1375666", season: nil, episode: nil),
        RemoteResumePointRemoval.Session(sessionId: 4, contentId: "tt2560140", season: 1, episode: 1)
    ]

    /// Continue Watching removes a title, not an episode — so with no coordinates every session
    /// for that title goes. A series left with one stale episode point comes straight back.
    func testWithNoCoordinatesEverySessionForTheTitleGoes() {
        XCTAssertEqual(
            RemoteResumePointRemoval.sessions(in: sessions, contentId: "tt0903747"),
            [1, 2]
        )
    }

    func testNothingElseIsTouched() {
        let removed = RemoteResumePointRemoval.sessions(in: sessions, contentId: "tt0903747")
        XCTAssertFalse(removed.contains(3))
        XCTAssertFalse(removed.contains(4))
    }

    func testAFilmMatchesOnItsOwn() {
        XCTAssertEqual(RemoteResumePointRemoval.sessions(in: sessions, contentId: "tt1375666"), [3])
    }

    /// Both coordinates or neither. One without the other would be a half-specified match, and
    /// the safe reading of "season 2, no episode" is not "every episode of season 2".
    func testBothCoordinatesNarrowTheMatch() {
        XCTAssertEqual(
            RemoteResumePointRemoval.sessions(in: sessions, contentId: "tt0903747", season: 2, episode: 1),
            [2]
        )
        XCTAssertEqual(
            RemoteResumePointRemoval.sessions(in: sessions, contentId: "tt0903747", season: 2),
            [1, 2],
            "a season with no episode is not a narrowing"
        )
    }

    func testCoordinatesThatMatchNothingRemoveNothing() {
        XCTAssertTrue(
            RemoteResumePointRemoval.sessions(
                in: sessions, contentId: "tt0903747", season: 9, episode: 9
            ).isEmpty
        )
    }

    func testIdsAreComparedCaseInsensitivelyAndTrimmed() {
        XCTAssertEqual(
            RemoteResumePointRemoval.sessions(in: sessions, contentId: "  TT0903747 "),
            [1, 2]
        )
    }

    /// The one that would be a disaster: an empty id matching everything and clearing somebody's
    /// entire resume list.
    func testAnEmptyIdRemovesNothing() {
        XCTAssertTrue(RemoteResumePointRemoval.sessions(in: sessions, contentId: "").isEmpty)
        XCTAssertTrue(RemoteResumePointRemoval.sessions(in: sessions, contentId: "   ").isEmpty)
    }

    func testAnUnknownTitleRemovesNothing() {
        XCTAssertTrue(
            RemoteResumePointRemoval.sessions(in: sessions, contentId: "tt0000000").isEmpty
        )
    }

    func testNoSessionsAtAllIsNotAnError() {
        XCTAssertTrue(RemoteResumePointRemoval.sessions(in: [], contentId: "tt0903747").isEmpty)
    }
}
