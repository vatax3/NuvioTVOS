import XCTest
@testable import Nuvio

/// Which recorded position the *Play* button on a series resumes from.
///
/// `next_up_from_furthest_episode` anchors on the deepest episode touched, and that is the right
/// answer for exactly the case it was written for and the wrong one the moment that episode is
/// finished. Both halves are pinned here: the rewatch the preference exists for must keep
/// working, and the episode actually in progress must be reachable.
final class NextUpAnchorTests: XCTestCase {
    private let threshold = 0.9
    private let day: TimeInterval = 60 * 60 * 24
    private var epoch: Date { Date(timeIntervalSince1970: 1_600_000_000) }

    private func progress(
        season: Int,
        episode: Int,
        fraction: Double,
        daysAgo: Double
    ) -> WatchProgress {
        WatchProgress(
            contentId: "tt0944947",
            contentType: "series",
            videoId: "tt0944947:\(season):\(episode)",
            season: season,
            episode: episode,
            positionSeconds: 3_000 * fraction,
            durationSeconds: 3_000,
            updatedAt: epoch.addingTimeInterval(-daysAgo * day)
        )
    }

    // MARK: The defect

    /// The report, in one test. S05E01 was finished, so the furthest anchor has nothing left to
    /// resume — and the episode the viewer is halfway through cannot be reached from the button.
    func testAnEpisodeInProgressBeatsAFinishedFurthestEpisode() {
        let finished = progress(season: 5, episode: 1, fraction: 1, daysAgo: 4)
        let inProgress = progress(season: 2, episode: 3, fraction: 0.4, daysAgo: 1)

        let anchor = NextUpAnchor.resolve(
            furthest: finished, entries: [finished, inProgress], threshold: threshold
        )

        XCTAssertEqual(anchor?.videoId, inProgress.videoId)
    }

    /// The other half. A rewatch of an early episode must not drag the series backwards, which is
    /// the whole reason the furthest anchor exists — so when the furthest episode is *itself*
    /// unfinished and more recent, it keeps the button.
    func testAMoreRecentUnfinishedFurthestEpisodeKeepsTheAnchor() {
        let furthest = progress(season: 5, episode: 4, fraction: 0.3, daysAgo: 1)
        let older = progress(season: 1, episode: 2, fraction: 0.5, daysAgo: 30)

        let anchor = NextUpAnchor.resolve(
            furthest: furthest, entries: [furthest, older], threshold: threshold
        )

        XCTAssertEqual(anchor?.videoId, furthest.videoId)
    }

    // MARK: Ordering

    func testTheMostRecentInProgressEpisodeWins() {
        let older = progress(season: 1, episode: 2, fraction: 0.5, daysAgo: 10)
        let newer = progress(season: 3, episode: 7, fraction: 0.2, daysAgo: 2)

        let anchor = NextUpAnchor.resolve(
            furthest: nil, entries: [older, newer], threshold: threshold
        )

        XCTAssertEqual(anchor?.videoId, newer.videoId)
    }

    /// Two rows written in the same second are a binge, and the later episode is the one the
    /// viewer actually got to.
    func testATieGoesToTheDeeperEpisode() {
        let earlier = progress(season: 2, episode: 1, fraction: 0.3, daysAgo: 1)
        let later = progress(season: 2, episode: 2, fraction: 0.3, daysAgo: 1)

        let anchor = NextUpAnchor.resolve(
            furthest: nil, entries: [later, earlier], threshold: threshold
        )

        XCTAssertEqual(anchor?.videoId, later.videoId)
    }

    // MARK: What does not count as a resume point

    /// A few seconds is a mis-press or a title card, not a place to come back to — and treating
    /// it as one would hand the button to whatever the viewer last opened by accident.
    func testASecondOrTwoIsNotAResumePoint() {
        let glance = progress(season: 4, episode: 1, fraction: 0.005, daysAgo: 1)
        let furthest = progress(season: 6, episode: 1, fraction: 1, daysAgo: 20)

        let anchor = NextUpAnchor.resolve(
            furthest: furthest, entries: [glance, furthest], threshold: threshold
        )

        XCTAssertEqual(anchor?.videoId, furthest.videoId)
    }

    func testAFinishedEpisodeIsNotAResumePoint() {
        let finished = progress(season: 2, episode: 2, fraction: 0.95, daysAgo: 1)

        let anchor = NextUpAnchor.resolve(
            furthest: nil, entries: [finished], threshold: threshold
        )

        XCTAssertNil(anchor)
    }

    /// Finished is judged against the viewer's own threshold, not a constant: someone who calls
    /// 80% watched has different resume points from someone who calls 95% watched.
    func testTheViewersThresholdDecidesWhatCountsAsFinished() {
        let late = progress(season: 2, episode: 2, fraction: 0.85, daysAgo: 1)

        XCTAssertNil(NextUpAnchor.resolve(furthest: nil, entries: [late], threshold: 0.8))
        XCTAssertEqual(
            NextUpAnchor.resolve(furthest: nil, entries: [late], threshold: 0.95)?.videoId,
            late.videoId
        )
    }

    // MARK: Degenerate input

    func testNoProgressAtAllAnchorsOnNothing() {
        XCTAssertNil(NextUpAnchor.resolve(furthest: nil, entries: [], threshold: threshold))
    }

    /// Nothing resumable and a furthest row still has an answer — the caller takes the episode
    /// *after* it, which is what makes finishing a season offer the next one.
    func testAFinishedSeriesStillAnchorsOnItsLastEpisode() {
        let finished = progress(season: 8, episode: 6, fraction: 1, daysAgo: 1)

        let anchor = NextUpAnchor.resolve(
            furthest: finished, entries: [finished], threshold: threshold
        )

        XCTAssertEqual(anchor?.videoId, finished.videoId)
    }
}
