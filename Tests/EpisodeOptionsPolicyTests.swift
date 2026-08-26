import XCTest
@testable import Nuvio

/// Which rows a long press on an episode offers.
final class EpisodeOptionsPolicyTests: XCTestCase {
    private func context(
        watched: Bool = false,
        progress: Bool = false,
        seasonWatched: Bool = false,
        hasPrevious: Bool = false,
        comments: Bool = false
    ) -> EpisodeOptionsPolicy.Context {
        .init(
            isWatched: watched, hasProgress: progress, isSeasonWatched: seasonWatched,
            hasPreviousEpisodes: hasPrevious, canOpenComments: comments
        )
    }

    /// The overlay must not make the common case harder to reach than the rare one — pressing
    /// the card already plays, so the row that does the same thing leads.
    func testPlayLeads() {
        XCTAssertEqual(EpisodeOptionsPolicy.actions(for: context()).first, .play)
    }

    /// The gap this closes: before it, an episode could only be marked watched by playing it
    /// past the threshold or by marking the whole series.
    func testMarkingOneEpisodeIsAlwaysOffered() {
        XCTAssertTrue(EpisodeOptionsPolicy.actions(for: context()).contains(.markWatched))
        XCTAssertTrue(
            EpisodeOptionsPolicy.actions(for: context(watched: true)).contains(.markUnwatched)
        )
    }

    func testTheWatchedRowIsNeverBothAtOnce() {
        for watched in [true, false] {
            let rows = EpisodeOptionsPolicy.actions(for: context(watched: watched))
                .filter { $0 == .markWatched || $0 == .markUnwatched }
            XCTAssertEqual(rows.count, 1)
        }
    }

    func testTheSeasonRowFollowsTheSeasonNotTheEpisode() {
        XCTAssertTrue(
            EpisodeOptionsPolicy.actions(for: context(watched: true, seasonWatched: false))
                .contains(.markSeasonWatched)
        )
        XCTAssertTrue(
            EpisodeOptionsPolicy.actions(for: context(watched: false, seasonWatched: true))
                .contains(.markSeasonUnwatched)
        )
    }

    /// On the first episode of the first season there is nothing before it, and a row that does
    /// nothing is worse than one that is absent.
    func testCatchUpIsOnlyOfferedWhenThereIsSomethingToCatchUpOn() {
        XCTAssertFalse(
            EpisodeOptionsPolicy.actions(for: context()).contains(.markPreviousWatched)
        )
        XCTAssertTrue(
            EpisodeOptionsPolicy.actions(for: context(hasPrevious: true)).contains(.markPreviousWatched)
        )
    }

    func testStartingOverNeedsSomethingToStartOverFrom() {
        XCTAssertFalse(EpisodeOptionsPolicy.actions(for: context()).contains(.startFromBeginning))
        XCTAssertTrue(
            EpisodeOptionsPolicy.actions(for: context(progress: true)).contains(.startFromBeginning)
        )
    }

    func testCommentsFollowTheSameConditionsAsTheTitlesOwnButton() {
        XCTAssertFalse(EpisodeOptionsPolicy.actions(for: context()).contains(.openComments))
        XCTAssertTrue(
            EpisodeOptionsPolicy.actions(for: context(comments: true)).contains(.openComments)
        )
    }

    /// Seven identical rows make an irreversible choice as easy to hit as a safe one.
    func testOnlyTheUndoingRowsAreMarkedDestructive() {
        XCTAssertEqual(
            Set(EpisodeOptionsPolicy.Action.allCases.filter(\.isDestructive)),
            [.markUnwatched, .markSeasonUnwatched]
        )
    }

    func testEveryRowHasASymbol() {
        for action in EpisodeOptionsPolicy.Action.allCases {
            XCTAssertFalse(action.systemImage.isEmpty, "\(action) has no symbol")
        }
    }
}

/// Which episodes a season-level or catch-up action actually touches.
final class EpisodeWatchedSpanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func episode(_ season: Int, _ number: Int, released: TimeInterval? = nil) -> SeriesEpisodeRef {
        SeriesEpisodeRef(
            videoId: "tt1:\(season):\(number)", season: season, episode: number,
            released: released.map { now.addingTimeInterval($0) }
        )
    }

    private lazy var series = [
        episode(0, 1),
        episode(1, 1), episode(1, 2), episode(1, 3),
        episode(2, 1), episode(2, 2, released: 86_400)
    ]

    // MARK: A season

    func testASeasonTakesOnlyItsOwnAiredEpisodes() {
        XCTAssertEqual(
            EpisodeWatchedSpan.season(1, in: series, now: now).map(\.videoId),
            ["tt1:1:1", "tt1:1:2", "tt1:1:3"]
        )
        XCTAssertEqual(
            EpisodeWatchedSpan.season(2, in: series, now: now).map(\.episode),
            [1], "the unaired second episode is left alone"
        )
    }

    /// Same rule as the series walk: specials are not part of the run.
    func testSeasonZeroIsNotASeason() {
        XCTAssertTrue(EpisodeWatchedSpan.season(0, in: series, now: now).isEmpty)
    }

    // MARK: Catching up

    /// Across seasons, because that is what the row means. Somebody starting at season two and
    /// marking everything before it watched means season one, not the nothing before it within
    /// its own season.
    func testCatchingUpCrossesSeasonBoundaries() {
        let caught = EpisodeWatchedSpan.precedingAndIncluding(
            episode(2, 1), in: series, now: now
        )
        XCTAssertEqual(caught.map(\.videoId), ["tt1:1:1", "tt1:1:2", "tt1:1:3", "tt1:2:1"])
    }

    /// "This and everything before it" includes this one — the viewer is saying they are up to
    /// here, not up to just before here.
    func testCatchingUpIncludesTheEpisodeItself() {
        let caught = EpisodeWatchedSpan.precedingAndIncluding(episode(1, 2), in: series, now: now)
        XCTAssertEqual(caught.map(\.episode), [1, 2])
    }

    func testCatchingUpSkipsSpecialsAndUnaired() {
        let caught = EpisodeWatchedSpan.precedingAndIncluding(
            episode(2, 9), in: series, now: now
        )
        XCTAssertFalse(caught.contains { $0.season == 0 })
        XCTAssertFalse(caught.contains { $0.videoId == "tt1:2:2" })
    }

    // MARK: Is the season done

    func testASeasonIsWatchedOnlyWhenEveryAiredEpisodeIs() {
        let watched: Set<String> = ["tt1:1:1", "tt1:1:2"]
        XCTAssertFalse(
            EpisodeWatchedSpan.isSeasonWatched(1, in: series, isWatched: watched.contains, now: now)
        )

        let all: Set<String> = ["tt1:1:1", "tt1:1:2", "tt1:1:3"]
        XCTAssertTrue(
            EpisodeWatchedSpan.isSeasonWatched(1, in: series, isWatched: all.contains, now: now)
        )
    }

    /// An unaired episode must not hold a finished season open, or the row says "mark season
    /// watched" on a season that is watched.
    func testAnUnairedEpisodeDoesNotHoldASeasonOpen() {
        XCTAssertTrue(
            EpisodeWatchedSpan.isSeasonWatched(
                2, in: series, isWatched: { $0 == "tt1:2:1" }, now: now
            )
        )
    }

    /// A season with nothing aired is not watched — nobody could have watched it, and saying
    /// yes would offer to un-watch it.
    func testASeasonWithNothingAiredIsNotWatched() {
        let future = [episode(3, 1, released: 86_400)]
        XCTAssertFalse(
            EpisodeWatchedSpan.isSeasonWatched(3, in: future, isWatched: { _ in true }, now: now)
        )
    }

    func testAnUnknownSeasonIsNotWatched() {
        XCTAssertFalse(
            EpisodeWatchedSpan.isSeasonWatched(9, in: series, isWatched: { _ in true }, now: now)
        )
    }
}
