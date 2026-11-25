import XCTest
@testable import Nuvio

/// Upstream's Simkl completion rules (1.2.0-beta.4): `SimklRewatchPolicyTest`'s threshold cases,
/// `PlayerContentEndPolicy` and `LocalCompletionThresholdTest`.
final class SimklCompletionTests: XCTestCase {
    func testTheViewersThresholdIsKeptInsideItsRange() {
        XCTAssertEqual(SimklCompletion.thresholdPercent(userThreshold: 87, contentEnd: nil), 87)
        XCTAssertEqual(SimklCompletion.coercedThreshold(40), 80)
        XCTAssertEqual(SimklCompletion.coercedThreshold(120), 100)
    }

    func testTheCreditsMarkerWins() {
        XCTAssertEqual(SimklCompletion.thresholdPercent(userThreshold: 95, contentEnd: 91.4), 91)
    }

    /// Under Simkl's own bar a stop is not counted, so the marker cannot be the completion point.
    func testAMarkerBelowSimklsBarIsDropped() {
        XCTAssertEqual(SimklCompletion.thresholdPercent(userThreshold: 90, contentEnd: 70), 90)
    }

    func testNonsenseFallsBackToSimklsBar() {
        XCTAssertEqual(SimklCompletion.resolvedPercent(userThreshold: .nan, contentEnd: nil), 80)
        XCTAssertEqual(SimklCompletion.minProgress(.infinity), 80)
        XCTAssertEqual(SimklCompletion.minProgress(99.9), 99)
    }

    func testTheContentEndIsTheEarliestOutroReadFiveSecondsEarly() {
        let segments = [
            SkipSegment(kind: .intro, start: 30, end: 60),
            SkipSegment(kind: .outro, start: 1_350, end: 1_400),
            SkipSegment(kind: .movieCredits, start: 1_300, end: 1_400),
        ]
        let percent = try? XCTUnwrap(SimklCompletion.contentEndPercent(segments: segments, duration: 1_400))
        XCTAssertEqual(percent ?? 0, (1_300 - 5) / 1_400 * 100, accuracy: 0.0001)
        XCTAssertNil(SimklCompletion.contentEndPercent(segments: [SkipSegment(kind: .outro, start: 1_500, end: 1_600)], duration: 1_400))
        XCTAssertNil(SimklCompletion.contentEndPercent(segments: segments, duration: 0))
    }

    /// `localCompletionThresholdFor`: only ever raises the bar.
    func testTheLocalThresholdOnlyRises() {
        XCTAssertEqual(SimklCompletion.localThreshold(base: 0.95, simklPercent: 80), 0.95)
        XCTAssertEqual(SimklCompletion.localThreshold(base: 0.95, simklPercent: 98), 0.98)
        XCTAssertEqual(SimklCompletion.localThreshold(base: 0.95, simklPercent: nil), 0.95)
    }

    /// A playback row is a position the account keeps open: it never reads as watched.
    func testASimklPlaybackRowStaysResumable() throws {
        let item = SimklClient.PlaybackItem(
            contentId: "tt1", type: .movie, title: "x", poster: nil, season: nil, episode: nil,
            progress: 97, durationSeconds: 6_000, pausedAt: nil
        )
        let row = try XCTUnwrap(RemoteProgressService.progress(from: item, threshold: 0.95))
        XCTAssertTrue(row.isInProgress(threshold: 0.95))
        let early = try XCTUnwrap(RemoteProgressService.progress(from: SimklClient.PlaybackItem(
            contentId: "tt1", type: .movie, title: "x", poster: nil, season: nil, episode: nil,
            progress: 40, durationSeconds: 6_000, pausedAt: nil
        ), threshold: 0.95))
        XCTAssertEqual(early.fraction, 0.4, accuracy: 0.0001)
    }
}
