import XCTest
@testable import Nuvio

/// When the subtitle line is allowed to move back down.
///
/// The lift itself shipped in 1.0.46 and reached mpv in 1.0.47; this is the half that was missing
/// from both. The transport hides on its own timer, which lands in the middle of a sentence far
/// more often than not, and dropping the line at that moment slides the words out from under the
/// reader. Upstream fixed the same defect in 1.1.0-beta.8.
final class SubtitleLiftSettlingTests: XCTestCase {
    private func settled(
        target: Double,
        applied: Double,
        isImmediate: Bool = false,
        hasCueOnScreen: Bool = true,
        hasWaitedOut: Bool = false
    ) -> Double {
        SubtitlePlacement.settledLift(
            target: target,
            applied: applied,
            isImmediate: isImmediate,
            hasCueOnScreen: hasCueOnScreen,
            hasWaitedOut: hasWaitedOut
        )
    }

    /// Going up is never deferred: whatever caused it is already drawn over the line.
    func testRaisingIsImmediate() {
        XCTAssertEqual(settled(target: 120, applied: 0), 120)
    }

    func testNoChangeIsNoChange() {
        XCTAssertEqual(settled(target: 120, applied: 120), 120)
    }

    /// The case the rule exists for.
    func testDroppingWaitsWhileALineIsBeingRead() {
        XCTAssertEqual(settled(target: 0, applied: 120), 120)
    }

    /// Between cues there is nothing to disturb, so the line drops at once.
    func testDroppingWithNoCueOnScreenIsImmediate() {
        XCTAssertEqual(settled(target: 0, applied: 120, hasCueOnScreen: false), 0)
    }

    /// The appearance panel is open: the position is the thing being looked at, so it must be
    /// the real one and it must move the moment it is changed.
    func testDroppingIsImmediateWhileThePositionIsBeingPreviewed() {
        XCTAssertEqual(settled(target: 0, applied: 120, isImmediate: true), 0)
    }

    /// A paused frame with one long cue would otherwise hold the line up for as long as it sits
    /// there, which is the opposite failure.
    func testDroppingHappensAnywayOnceTheWaitExpires() {
        XCTAssertEqual(settled(target: 0, applied: 120, hasWaitedOut: true), 0)
    }

    func testTheWaitIsUpstreamsThreeSeconds() {
        XCTAssertEqual(SubtitlePlacement.dropTimeout, 3)
    }
}
