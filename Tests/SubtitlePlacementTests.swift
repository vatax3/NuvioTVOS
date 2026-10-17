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
        let margin = SubtitlePlacement.mpvMarginY(offset: 0, obstructions: .init())

        XCTAssertEqual(margin, 22.67, accuracy: 1)
    }

    /// Roughly 3% of the picture, where it used to be about 10%.
    func testTheDefaultIsNotLiftedAwayFromTheBottom() {
        let inset = SubtitlePlacement.inset(offset: 0, obstructions: .init())

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
            SubtitlePlacement.inset(offset: offset, obstructions: .init())
                - SubtitlePlacement.inset(offset: 0, obstructions: .init())
        ) * 2
        let mpvUnits = SubtitlePlacement.mpvMarginY(offset: offset, obstructions: .init())
            - SubtitlePlacement.mpvMarginY(offset: 0, obstructions: .init())

        XCTAssertEqual(overlayPoints / 1080, mpvUnits / 720, accuracy: 0.0001)
    }

    func testAPositiveOffsetLiftsAndANegativeOneLowers() {
        let base = SubtitlePlacement.inset(offset: 0, obstructions: .init())

        XCTAssertGreaterThan(SubtitlePlacement.inset(offset: 30, obstructions: .init()), base)
        XCTAssertLessThan(SubtitlePlacement.inset(offset: -10, obstructions: .init()), base)
    }

    /// Worth having as a number rather than a feeling: one step of the control has to be visible
    /// on a television. Five units is ten points of a 1080-high screen.
    func testOneStepOfTheControlIsVisible() {
        let step = (
            SubtitlePlacement.inset(offset: 5, obstructions: .init())
                - SubtitlePlacement.inset(offset: 0, obstructions: .init())
        ) * 2

        XCTAssertEqual(step, 10, accuracy: 0.001)
    }

    // MARK: The transport allowance

    /// Paid while the transport is up, and only then. Reserving it permanently is what put every
    /// line too high in the first place.
    func testTheLineLiftsWhileTheTransportIsUp() {
        XCTAssertEqual(
            SubtitlePlacement.inset(offset: 0, obstructions: .init(controls: true))
                - SubtitlePlacement.inset(offset: 0, obstructions: .init()),
            SubtitlePlacement.controlsLift,
            accuracy: 0.001
        )
    }

    func testTheLiftAppliesToMpvToo() {
        XCTAssertGreaterThan(
            SubtitlePlacement.mpvMarginY(offset: 0, obstructions: .init(controls: true)),
            SubtitlePlacement.mpvMarginY(offset: 0, obstructions: .init())
        )
    }

    /// The old permanent inset, now paid only on the timer. Checking the number keeps the
    /// with-transport position exactly where viewers were used to seeing it.
    func testWithTheTransportUpTheLineIsWhereItUsedToAlwaysBe() {
        XCTAssertEqual(
            SubtitlePlacement.inset(offset: 0, obstructions: .init(controls: true)), 77, accuracy: 0.001
        )
    }

    // MARK: Bounds

    /// A stored value from a future build, or a viewer holding the control down, must not park
    /// the line off the picture.
    func testAnAbsurdOffsetIsClamped() {
        XCTAssertEqual(
            SubtitlePlacement.inset(offset: 9_000, obstructions: .init()),
            SubtitlePlacement.inset(
                offset: SubtitlePlacement.offsetRange.upperBound, obstructions: .init()
            )
        )
        XCTAssertEqual(
            SubtitlePlacement.inset(offset: -9_000, obstructions: .init()),
            SubtitlePlacement.inset(
                offset: SubtitlePlacement.offsetRange.lowerBound, obstructions: .init()
            )
        )
    }

    /// And the bottom of the range still leaves the line on screen rather than below the edge.
    func testTheLowestOffsetStaysInsideThePicture() {
        XCTAssertGreaterThanOrEqual(
            SubtitlePlacement.inset(
                offset: SubtitlePlacement.offsetRange.lowerBound, obstructions: .init()
            ),
            0
        )
    }

    // MARK: The seek readout

    /// The hidden-controls seek readout is drawn bottom-centre, in the band a subtitle occupies,
    /// so the line has to clear it too. It is the only other overlay of ours that does: the skip
    /// card clears 116dp and the post-play card 110dp, both already above a resting subtitle.
    func testTheLineLiftsForTheSeekReadout() {
        XCTAssertEqual(
            SubtitlePlacement.inset(offset: 0, obstructions: .init(seekReadout: true))
                - SubtitlePlacement.inset(offset: 0, obstructions: .init()),
            SubtitlePlacement.seekReadoutLift,
            accuracy: 0.001
        )
    }

    /// The readout sits higher than the transport, and it replaces it rather than joining it —
    /// so its clearance has to be the larger of the two or the line lands across it.
    func testTheReadoutNeedsMoreClearanceThanTheTransport() {
        XCTAssertGreaterThan(SubtitlePlacement.seekReadoutLift, SubtitlePlacement.controlsLift)
    }

    // MARK: Two at once

    /// **The largest clearance, never the sum.** Two overlays in one band need the line clear of
    /// the taller one; adding them would throw it into the middle of the picture.
    func testTwoObstructionsTakeTheLargerClearanceRatherThanBoth() {
        let both = SubtitlePlacement.inset(
            offset: 0, obstructions: .init(controls: true, seekReadout: true)
        )

        XCTAssertEqual(
            both,
            SubtitlePlacement.inset(offset: 0, obstructions: .init(seekReadout: true)),
            accuracy: 0.001
        )
        XCTAssertLessThan(
            both,
            SubtitlePlacement.inset(offset: 0, obstructions: .init())
                + SubtitlePlacement.controlsLift + SubtitlePlacement.seekReadoutLift
        )
    }

    // MARK: Previewing the offset

    /// With the appearance panel open the viewer is moving the line, so nothing is lifted: the
    /// position they are looking at has to be the position the film will have. Measuring from a
    /// lifted baseline is a large part of why the control felt vague.
    func testThePanelSuspendsEveryLift() {
        for obstructions in [
            SubtitlePlacement.Obstructions(controls: true, previewingOffset: true),
            SubtitlePlacement.Obstructions(seekReadout: true, previewingOffset: true),
            SubtitlePlacement.Obstructions(
                controls: true, seekReadout: true, previewingOffset: true
            )
        ] {
            XCTAssertEqual(
                SubtitlePlacement.inset(offset: 40, obstructions: obstructions),
                SubtitlePlacement.inset(offset: 40, obstructions: .init()),
                accuracy: 0.001,
                "the preview must show the resting position, not a lifted one"
            )
        }
    }

    /// Suppressing the lift must not suppress the offset — that is the number being adjusted.
    func testThePreviewStillHonoursTheOffsetItself() {
        let preview = SubtitlePlacement.Obstructions(controls: true, previewingOffset: true)

        XCTAssertGreaterThan(
            SubtitlePlacement.inset(offset: 60, obstructions: preview),
            SubtitlePlacement.inset(offset: 0, obstructions: preview)
        )
    }

    /// And both renderers suspend it, or the preview is honest on one engine and not the other —
    /// which is the exact shape of the defect this whole type exists to prevent.
    func testTheSuspensionReachesMpvAsWell() {
        XCTAssertEqual(
            SubtitlePlacement.mpvMarginY(
                offset: 0, obstructions: .init(controls: true, previewingOffset: true)
            ),
            SubtitlePlacement.mpvMarginY(offset: 0, obstructions: .init()),
            accuracy: 0.001
        )
    }
}
