import XCTest
@testable import Nuvio

/// The label the Continue Watching card and the sources screen now share.
final class WatchProgressLabelTests: XCTestCase {
    private func progress(position: Double, duration: Double) -> WatchProgress {
        WatchProgress(
            contentId: "tt0000001", contentType: "movie",
            videoId: "tt0000001", season: nil, episode: nil,
            positionSeconds: position, durationSeconds: duration, updatedAt: .distantPast
        )
    }

    func testMidwayNamesTheMinutesLeft() {
        let label = progress(position: 1_200, duration: 3_600).remainingLabel
        XCTAssertTrue(label.contains("40"), "forty minutes remain; got \(label)")
    }

    func testUnderAMinuteLeftReadsAsAlmostDone() {
        let label = progress(position: 3_570, duration: 3_600).remainingLabel
        XCTAssertFalse(label.contains("0 "), "zero minutes is not a sentence; got \(label)")
        XCTAssertEqual(label, L10n.text("card.almost_done", fallback: "Almost done"))
    }

    /// A row that arrived before a duration was known must not divide by zero or claim progress.
    func testAZeroDurationIsSafeAndClaimsNoProgress() {
        let entry = progress(position: 0, duration: 0)
        XCTAssertEqual(entry.fraction, 0)
        XCTAssertEqual(entry.remainingSeconds, 0)
        XCTAssertEqual(entry.remainingLabel, L10n.text("card.almost_done", fallback: "Almost done"))
    }

    /// A position past the end is a rounding artefact of a finished file, not negative time.
    func testAPositionPastTheEndNeverGoesNegative() {
        let entry = progress(position: 3_610, duration: 3_600)
        XCTAssertEqual(entry.remainingSeconds, 0)
        XCTAssertEqual(entry.fraction, 1)
    }
}
