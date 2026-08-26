import XCTest
@testable import Nuvio

/// Which episodes "mark this series watched" touches, and — more to the point — which it leaves.
final class SeriesWatchedWalkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func episode(
        _ season: Int, _ number: Int, released: TimeInterval? = nil
    ) -> SeriesEpisodeRef {
        SeriesEpisodeRef(
            videoId: "tt1:\(season):\(number)",
            season: season,
            episode: number,
            released: released.map { now.addingTimeInterval($0) }
        )
    }

    // MARK: What is marked

    func testEveryAiredEpisodeIsMarked() {
        let marked = SeriesWatchedWalk.episodesToMark(
            in: [episode(1, 1), episode(1, 2), episode(2, 1)], now: now
        )
        XCTAssertEqual(marked.map(\.videoId), ["tt1:1:1", "tt1:1:2", "tt1:2:1"])
    }

    /// Season zero is not part of the run somebody means when they say they have watched a
    /// series, and Trakt's own "watch all" leaves it alone too.
    func testSpecialsAreLeftAlone() {
        let marked = SeriesWatchedWalk.episodesToMark(
            in: [episode(0, 1), episode(0, 2), episode(1, 1)], now: now
        )
        XCTAssertEqual(marked.map(\.videoId), ["tt1:1:1"])
    }

    /// Marking a future episode watched is a lie that lasts: it keeps the episode out of Next Up
    /// on the day it finally airs, which is exactly when it matters.
    func testUnairedEpisodesAreLeftAlone() {
        let marked = SeriesWatchedWalk.episodesToMark(
            in: [
                episode(1, 1, released: -86_400),
                episode(1, 2, released: -60),
                episode(1, 3, released: 86_400)
            ],
            now: now
        )
        XCTAssertEqual(marked.map(\.episode), [1, 2])
    }

    /// An addon that published no date is the common case, and hiding those would mark nothing
    /// at all for most series. `NextUpProjection` makes the same call for the same reason.
    func testAnEpisodeWithNoDateCountsAsAired() {
        XCTAssertEqual(
            SeriesWatchedWalk.episodesToMark(in: [episode(1, 1)], now: now).count, 1
        )
    }

    /// The addon's order is not the viewer's order.
    func testTheWalkIsInViewingOrder() {
        let marked = SeriesWatchedWalk.episodesToMark(
            in: [episode(2, 1), episode(1, 10), episode(1, 2)], now: now
        )
        XCTAssertEqual(marked.map(\.order), marked.map(\.order).sorted())
        XCTAssertEqual(marked.map(\.videoId), ["tt1:1:2", "tt1:1:10", "tt1:2:1"])
    }

    // MARK: What is cleared

    /// The undo has to leave nothing behind, so it takes the specials too — clearing an episode
    /// that was never marked costs nothing, and leaving one marked is a series that will not go
    /// back to unwatched.
    func testClearingTakesEverythingIncludingSpecialsAndUnaired() {
        let episodes = [episode(0, 1), episode(1, 1), episode(1, 2, released: 86_400)]
        XCTAssertEqual(SeriesWatchedWalk.episodesToClear(in: episodes).count, 3)
    }

    func testClearingIsAlsoInOrder() {
        let cleared = SeriesWatchedWalk.episodesToClear(in: [episode(2, 1), episode(1, 1)])
        XCTAssertEqual(cleared.map(\.videoId), ["tt1:1:1", "tt1:2:1"])
    }

    // MARK: Whether to walk at all

    /// The distinction the whole feature turns on: an empty list is a series nobody has opened,
    /// not a series with no episodes. Reporting success having marked nothing is the failure the
    /// films-only rule used to avoid.
    func testAnUnknownSeriesCannotBeWalked() {
        XCTAssertFalse(SeriesWatchedWalk.canWalk([]))
    }

    /// And a series known only by its specials is still unknown for this purpose — walking it
    /// would mark nothing.
    func testASeriesOfNothingButSpecialsCannotBeWalked() {
        XCTAssertFalse(SeriesWatchedWalk.canWalk([episode(0, 1), episode(0, 2)]))
    }

    func testAKnownSeriesCanBeWalked() {
        XCTAssertTrue(SeriesWatchedWalk.canWalk([episode(1, 1)]))
        XCTAssertTrue(SeriesWatchedWalk.canWalk([episode(0, 1), episode(1, 1)]))
    }

    /// A series whose every episode is still to air can be walked — it just marks nothing yet.
    /// That is a different answer from "unknown", and conflating them would hide the row for a
    /// series the viewer is waiting on.
    func testASeriesEntirelyUnairedIsStillKnown() {
        let unaired = [episode(1, 1, released: 86_400)]

        XCTAssertTrue(SeriesWatchedWalk.canWalk(unaired))
        XCTAssertTrue(SeriesWatchedWalk.episodesToMark(in: unaired, now: now).isEmpty)
    }

    // MARK: The seeding bound

    /// Home draws the rail on its first frame. A viewer with thirty series in progress must not
    /// pay thirty addon round trips for it.
    func testSeedingIsBounded() {
        XCTAssertLessThanOrEqual(SeriesEpisodeCatalogue.seedLimit, 6)
        XCTAssertGreaterThan(SeriesEpisodeCatalogue.seedLimit, 0)
    }
}
