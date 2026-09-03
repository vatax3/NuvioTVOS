import XCTest
@testable import Nuvio

final class PostPlayRecommendationTests: XCTestCase {
    private func preview(_ id: String, _ name: String = "Film") -> MetaPreview {
        MetaPreview(id: id, type: .movie, rawType: "movie", name: name)
    }

    // MARK: Timing

    func testAFilmOffersRecommendationsAtTheThreshold() {
        XCTAssertTrue(PostPlayRecommendation.shouldShow(
            contentType: .movie, positionSeconds: 90, durationSeconds: 100, thresholdPercent: 90
        ))
    }

    func testAFilmShortOfTheThresholdOffersNothing() {
        XCTAssertFalse(PostPlayRecommendation.shouldShow(
            contentType: .movie, positionSeconds: 89, durationSeconds: 100, thresholdPercent: 90
        ))
    }

    /// The next-episode card owns the end of an episode. Two overlays due at the same instant is
    /// how one gets drawn over the other.
    func testASeriesIsLeftToTheNextEpisodeCard() {
        XCTAssertFalse(PostPlayRecommendation.shouldShow(
            contentType: .series, positionSeconds: 99, durationSeconds: 100, thresholdPercent: 90
        ))
    }

    /// A stream whose duration has not resolved yet reports 0. Dividing by it would show the
    /// overlay on the first frame.
    func testAnUnknownDurationShowsNothing() {
        XCTAssertFalse(PostPlayRecommendation.shouldShow(
            contentType: .movie, positionSeconds: 10, durationSeconds: 0, thresholdPercent: 90
        ))
    }

    func testThresholdsOutsideTheRangeAreClamped() {
        XCTAssertEqual(PostPlayRecommendation.clampThreshold(10), 80)
        XCTAssertEqual(PostPlayRecommendation.clampThreshold(140), 100)
        XCTAssertEqual(PostPlayRecommendation.clampThreshold(88), 88)
    }

    /// A threshold below the floor must not become a film that offers recommendations halfway.
    func testAnAbsurdThresholdStillWaitsUntilEightyPercent() {
        XCTAssertFalse(PostPlayRecommendation.shouldShow(
            contentType: .movie, positionSeconds: 50, durationSeconds: 100, thresholdPercent: 5
        ))
        XCTAssertTrue(PostPlayRecommendation.shouldShow(
            contentType: .movie, positionSeconds: 80, durationSeconds: 100, thresholdPercent: 5
        ))
    }

    // MARK: Prefetch

    func testTheFetchStartsBeforeTheOverlayIsDue() {
        XCTAssertEqual(PostPlayRecommendation.prefetchProgress(thresholdPercent: 90), 0.85, accuracy: 0.0001)
        XCTAssertLessThan(
            PostPlayRecommendation.prefetchProgress(thresholdPercent: 90),
            0.90
        )
    }

    func testPrefetchFollowsAClampedThreshold() {
        XCTAssertEqual(PostPlayRecommendation.prefetchProgress(thresholdPercent: 200), 0.95, accuracy: 0.0001)
    }

    // MARK: The carousel

    func testTheSelectionStopsAtBothEndsRatherThanWrapping() {
        XCTAssertEqual(PostPlayRecommendation.step(selection: 0, by: -1, count: 5), 0)
        XCTAssertEqual(PostPlayRecommendation.step(selection: 4, by: 1, count: 5), 4)
        XCTAssertEqual(PostPlayRecommendation.step(selection: 2, by: 1, count: 5), 3)
    }

    func testTheArrowsKnowWhenTheyAreDead() {
        XCTAssertFalse(PostPlayRecommendation.canStep(selection: 0, by: -1, count: 5))
        XCTAssertTrue(PostPlayRecommendation.canStep(selection: 0, by: 1, count: 5))
        XCTAssertFalse(PostPlayRecommendation.canStep(selection: 0, by: 1, count: 1))
    }

    func testAnEmptyListHasNoSelectionToMove() {
        XCTAssertEqual(PostPlayRecommendation.step(selection: 0, by: 1, count: 0), 0)
        XCTAssertFalse(PostPlayRecommendation.canStep(selection: 0, by: 1, count: 0))
    }

    // MARK: Cards

    /// The film that just played is the one thing certain not to be a recommendation.
    func testTheFilmYouJustWatchedIsNotRecommendedBackToYou() {
        let cards = PostPlayRecommendation.cards(
            from: [preview("tt1"), preview("tt2")], excluding: "tt1"
        )
        XCTAssertEqual(cards.map(\.id), ["tt2"])
    }

    func testDuplicatesFromSeveralSourcesCollapse() {
        let cards = PostPlayRecommendation.cards(
            from: [preview("tt2"), preview("tt2"), preview("tt3")], excluding: "tt1"
        )
        XCTAssertEqual(cards.map(\.id), ["tt2", "tt3"])
    }

    func testTheRowIsCappedAtWhatARemoteCanReach() {
        let many = (1...40).map { preview("tt\($0)") }
        XCTAssertEqual(
            PostPlayRecommendation.cards(from: many, excluding: "none").count,
            PostPlayRecommendation.maximumCards
        )
    }
}
