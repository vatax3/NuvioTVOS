import XCTest
@testable import Nuvio

/// Where a subtitle sits, on both renderers.
///
/// Two things were reported and they turned out to be one cause. The line sat "a bit high" —
/// both renderers permanently reserved about a tenth of the picture for a transport bar that is
/// hidden almost all the time. And the position control "changed almost nothing" — the stored
/// number was read as display points by the overlay and as tenths of a percent of frame height
/// by mpv, so on the engine most viewers use it was worth about half as much.
final class SubtitlePlacementTests: XCTestCase {
    // MARK: The default position

    /// mpv's own `sub-margin-y` is 22, which is the position essentially every other player puts
    /// a subtitle at. Landing on it is the point of the baseline, not a coincidence.
    func testTheDefaultMatchesMpvsOwnMargin() {
        let margin = SubtitlePlacement.mpvMarginY(offset: 0, controlsVisible: false)

        XCTAssertEqual(margin, 22.67, accuracy: 1)
    }

    /// Roughly 3% of the picture, where it used to be about 10%.
    func testTheDefaultIsNotLiftedAwayFromTheBottom() {
        let inset = SubtitlePlacement.inset(offset: 0, controlsVisible: false)

        XCTAssertEqual(inset, 17, accuracy: 0.001)
        // Two points per `dp` on a 1080-high screen.
        XCTAssertLessThan(inset * 2 / 1080, 0.04)
    }

    // MARK: One number, two renderers

    /// The defect itself. A given offset has to move both renderers the same distance, or the
    /// one control means two different things depending on which engine opened the file.
    func testBothRenderersMoveByTheSameFractionOfTheScreen() {
        let offset: Double = 50
        let overlayPoints = (
            SubtitlePlacement.inset(offset: offset, controlsVisible: false)
                - SubtitlePlacement.inset(offset: 0, controlsVisible: false)
        ) * 2
        let mpvUnits = SubtitlePlacement.mpvMarginY(offset: offset, controlsVisible: false)
            - SubtitlePlacement.mpvMarginY(offset: 0, controlsVisible: false)

        XCTAssertEqual(overlayPoints / 1080, mpvUnits / 720, accuracy: 0.0001)
    }

    func testAPositiveOffsetLiftsAndANegativeOneLowers() {
        let base = SubtitlePlacement.inset(offset: 0, controlsVisible: false)

        XCTAssertGreaterThan(SubtitlePlacement.inset(offset: 30, controlsVisible: false), base)
        XCTAssertLessThan(SubtitlePlacement.inset(offset: -10, controlsVisible: false), base)
    }

    /// Worth having as a number rather than a feeling: one step of the control has to be visible
    /// on a television. Five units is ten points of a 1080-high screen.
    func testOneStepOfTheControlIsVisible() {
        let step = (
            SubtitlePlacement.inset(offset: 5, controlsVisible: false)
                - SubtitlePlacement.inset(offset: 0, controlsVisible: false)
        ) * 2

        XCTAssertEqual(step, 10, accuracy: 0.001)
    }

    // MARK: The transport allowance

    /// Paid while the transport is up, and only then. Reserving it permanently is what put every
    /// line too high in the first place.
    func testTheLineLiftsWhileTheTransportIsUp() {
        XCTAssertEqual(
            SubtitlePlacement.inset(offset: 0, controlsVisible: true)
                - SubtitlePlacement.inset(offset: 0, controlsVisible: false),
            SubtitlePlacement.controlsLift,
            accuracy: 0.001
        )
    }

    func testTheLiftAppliesToMpvToo() {
        XCTAssertGreaterThan(
            SubtitlePlacement.mpvMarginY(offset: 0, controlsVisible: true),
            SubtitlePlacement.mpvMarginY(offset: 0, controlsVisible: false)
        )
    }

    /// The old permanent inset, now paid only on the timer. Checking the number keeps the
    /// with-transport position exactly where viewers were used to seeing it.
    func testWithTheTransportUpTheLineIsWhereItUsedToAlwaysBe() {
        XCTAssertEqual(
            SubtitlePlacement.inset(offset: 0, controlsVisible: true), 77, accuracy: 0.001
        )
    }

    // MARK: Bounds

    /// A stored value from a future build, or a viewer holding the control down, must not park
    /// the line off the picture.
    func testAnAbsurdOffsetIsClamped() {
        XCTAssertEqual(
            SubtitlePlacement.inset(offset: 9_000, controlsVisible: false),
            SubtitlePlacement.inset(
                offset: SubtitlePlacement.offsetRange.upperBound, controlsVisible: false
            )
        )
        XCTAssertEqual(
            SubtitlePlacement.inset(offset: -9_000, controlsVisible: false),
            SubtitlePlacement.inset(
                offset: SubtitlePlacement.offsetRange.lowerBound, controlsVisible: false
            )
        )
    }

    /// And the bottom of the range still leaves the line on screen rather than below the edge.
    func testTheLowestOffsetStaysInsideThePicture() {
        XCTAssertGreaterThanOrEqual(
            SubtitlePlacement.inset(
                offset: SubtitlePlacement.offsetRange.lowerBound, controlsVisible: false
            ),
            0
        )
    }
}
