import XCTest
@testable import Nuvio

/// Offering the next episode once one has been finished.
///
/// Without the projection, Continue Watching holds only half-watched episodes: finishing one
/// takes the series off Home entirely and the viewer has to go and find episode four themselves.
final class NextUpProjectionTests: XCTestCase {
    private let past = Date(timeIntervalSince1970: 1_600_000_000)
    private let future = Date(timeIntervalSinceNow: 60 * 60 * 24 * 7)

    private func episode(_ season: Int, _ number: Int, released: Date? = nil) -> SeriesEpisodeRef {
        SeriesEpisodeRef(
            videoId: "tt1:\(season):\(number)", season: season, episode: number, released: released
        )
    }

    private var season: [SeriesEpisodeRef] {
        (1...5).map { episode(1, $0, released: past) }
    }

    func testTheEpisodeAfterTheOneJustFinishedIsOffered() {
        let next = NextUpProjection.next(
            in: season, isWatched: { _ in false }, after: (season: 1, episode: 2)
        )

        XCTAssertEqual(next?.episode, 3)
    }

    func testAlreadyWatchedEpisodesAreSkipped() {
        let watched: Set<String> = ["tt1:1:3", "tt1:1:4"]
        let next = NextUpProjection.next(
            in: season, isWatched: { watched.contains($0) }, after: (season: 1, episode: 2)
        )

        XCTAssertEqual(next?.episode, 5)
    }

    func testAFinishedSeriesOffersNothing() {
        let next = NextUpProjection.next(
            in: season, isWatched: { _ in true }, after: (season: 1, episode: 5)
        )

        XCTAssertNil(next)
    }

    func testTheSearchCrossesASeasonBoundary() {
        let episodes = [episode(1, 1, released: past), episode(1, 2, released: past),
                        episode(2, 1, released: past)]
        let next = NextUpProjection.next(
            in: episodes, isWatched: { _ in false }, after: (season: 1, episode: 2)
        )

        XCTAssertEqual(next?.season, 2)
        XCTAssertEqual(next?.episode, 1)
    }

    /// Episode ten must not sort before episode two, which a string comparison would do.
    func testDoubleDigitEpisodesOrderNumerically() {
        let episodes = (1...12).map { episode(1, $0, released: past) }
        let next = NextUpProjection.next(
            in: episodes.shuffled(), isWatched: { _ in false }, after: (season: 1, episode: 9)
        )

        XCTAssertEqual(next?.episode, 10)
    }

    /// Nothing watched yet: the series is not in Continue Watching for this reason at all, but
    /// the search still has to start somewhere sane rather than crash or skip episode one.
    func testWithNoAnchorTheFirstEpisodeIsOffered() {
        XCTAssertEqual(
            NextUpProjection.next(in: season, isWatched: { _ in false }, after: nil)?.episode,
            1
        )
    }

    // MARK: Airing

    /// An addon lists a whole season the day the first episode airs. Without the date check,
    /// every currently-airing series sits in the rail pointing at an episode that will not play.
    func testAnUnairedEpisodeIsNotOffered() {
        let episodes = [episode(1, 1, released: past), episode(1, 2, released: future)]

        XCTAssertNil(NextUpProjection.next(
            in: episodes, isWatched: { _ in false }, after: (season: 1, episode: 1)
        ))
    }

    func testUnairedEpisodesAreOfferedWhenTheViewerAsksForThem() {
        let episodes = [episode(1, 1, released: past), episode(1, 2, released: future)]
        let next = NextUpProjection.next(
            in: episodes, isWatched: { _ in false },
            after: (season: 1, episode: 1), allowsUnaired: true
        )

        XCTAssertEqual(next?.episode, 2)
    }

    /// Plenty of addons publish no date at all. Offering is the better failure: a viewer who
    /// presses it sees an empty source list, where hiding it loses an episode that did air.
    func testAnEpisodeWithNoDateIsOffered() {
        XCTAssertTrue(NextUpProjection.hasAired(episode(1, 1, released: nil)))
    }

    func testAiringIsMeasuredAgainstNowNotTheOrder() {
        XCTAssertTrue(NextUpProjection.hasAired(episode(1, 1, released: past)))
        XCTAssertFalse(NextUpProjection.hasAired(episode(1, 1, released: future)))
    }

    // MARK: The anchor

    /// `next_up_from_furthest_episode` off: going back to rewatch episode two offers episode
    /// three, rather than jumping past everything to the finale you saw out of order.
    func testTheAnchorFollowsTheMostRecentlyWatchedByDefault() {
        let watched = [
            (episode: episode(1, 8), watchedAt: past),
            (episode: episode(1, 2), watchedAt: past.addingTimeInterval(3600))
        ]

        let anchor = NextUpProjection.anchor(watched: watched, fromFurthest: false)
        XCTAssertEqual(anchor?.episode, 2)
    }

    func testTheAnchorCanFollowTheFurthestInstead() {
        let watched = [
            (episode: episode(1, 8), watchedAt: past),
            (episode: episode(1, 2), watchedAt: past.addingTimeInterval(3600))
        ]

        let anchor = NextUpProjection.anchor(watched: watched, fromFurthest: true)
        XCTAssertEqual(anchor?.episode, 8)
    }

    func testNoWatchedEpisodesMeansNoAnchor() {
        XCTAssertNil(NextUpProjection.anchor(watched: [], fromFurthest: true))
    }
}

/// A series the viewer has finished every aired episode of.
final class CaughtUpSeriesTests: XCTestCase {
    /// The regression this exists to prevent: upstream dropped a caught-up series from the rail
    /// the day a new episode aired — the exact moment it becomes interesting again.
    func testACaughtUpSeriesIsNeverDroppedFromTheRail() {
        XCTAssertFalse(CaughtUpSeries.shouldDropFromContinueWatching(nextEpisodeHasAired: true))
        XCTAssertFalse(CaughtUpSeries.shouldDropFromContinueWatching(nextEpisodeHasAired: false))
    }

    func testTheBadgeIsWhatChanges() {
        XCTAssertEqual(CaughtUpSeries.action(nextEpisodeHasAired: true), .keepAndClearBadge)
        XCTAssertEqual(CaughtUpSeries.action(nextEpisodeHasAired: false), .keepWithBadge)
    }
}

/// Waving a suggestion away.
final class NextUpDismissalTests: XCTestCase {
    func testDismissingAndRecognisingIt() {
        let keys = NextUpDismissal.adding(contentId: "tt1", to: [])

        XCTAssertTrue(NextUpDismissal.isDismissed(contentId: "tt1", keys: keys))
        XCTAssertFalse(NextUpDismissal.isDismissed(contentId: "tt2", keys: keys))
    }

    func testDismissingTwiceDoesNotAccumulate() {
        var keys = NextUpDismissal.adding(contentId: "tt1", to: [])
        keys = NextUpDismissal.adding(contentId: "tt1", to: keys)

        XCTAssertEqual(keys, ["tt1"])
    }

    /// Watching it again spends the dismissal. Otherwise one wave-away silences the series for
    /// good, including seasons that have not aired yet.
    func testWatchingAgainClearsIt() {
        let keys = NextUpDismissal.adding(contentId: "tt1", to: ["tt2"])
        let cleared = NextUpDismissal.clearing(contentId: "tt1", from: keys)

        XCTAssertEqual(cleared, ["tt2"])
    }

    func testClearingSomethingUndismissedChangesNothing() {
        XCTAssertEqual(NextUpDismissal.clearing(contentId: "tt9", from: ["tt1"]), ["tt1"])
    }

    /// The dismissal is per series, not per episode: dismissing means "stop offering me this
    /// show", and a per-episode key would resurface the moment the next one aired.
    func testTheKeyIgnoresTheEpisode() {
        XCTAssertEqual(NextUpDismissal.key(contentId: " tt1 "), "tt1")
    }
}
