import XCTest
@testable import Nuvio

/// Correcting subtitle timing by pointing at a line.
///
/// The arithmetic is one subtraction. What needs care is *which* lines to offer: they have to be
/// found at the point in the file currently being read — playback minus the delay already applied
/// — or the list walks away from the viewer by exactly the amount they are trying to correct.
/// That is the bug upstream fixed on 27 September, and it is the reason this is a type.
final class SubtitleSyncByLineTests: XCTestCase {
    private let limit = MPVEngine.subtitleDelayLimit

    private func cue(_ start: Double, _ end: Double, _ text: String = "A line") -> SubtitleCue {
        SubtitleCue(start: start, end: end, text: text)
    }

    private var track: [SubtitleCue] {
        (0..<40).map { cue(Double($0) * 5, Double($0) * 5 + 3, "Line \($0)") }
    }

    // MARK: The delay a choice produces

    func testChoosingALineMakesItLandOnTheCurrentPosition() {
        let delay = SubtitleSyncByLine.delay(toPlay: cue(100, 103), at: 104.5, limit: limit)

        XCTAssertEqual(delay, 4.5, accuracy: 0.0001)
    }

    /// A file running *late* needs a negative delay — subtitles pulled earlier.
    func testALineThatHasNotArrivedYetGivesANegativeDelay() {
        let delay = SubtitleSyncByLine.delay(toPlay: cue(110, 113), at: 104.5, limit: limit)

        XCTAssertEqual(delay, -5.5, accuracy: 0.0001)
    }

    /// Clamped to the same bound the stepper uses, so the two controls cannot disagree about what
    /// is reachable — a synced line outside it would show a delay the stepper could not restore.
    func testTheDelayIsClampedToTheSameLimitAsTheStepper() {
        XCTAssertEqual(
            SubtitleSyncByLine.delay(toPlay: cue(0, 3), at: 9_000, limit: limit), limit
        )
        XCTAssertEqual(
            SubtitleSyncByLine.delay(toPlay: cue(9_000, 9_003), at: 0, limit: limit), -limit
        )
    }

    // MARK: Which lines are offered

    /// The whole point of `cueClock`. With a 110-second delay already applied, playback at 130s
    /// is reading the file at 20s — so the lines to offer are the ones around 20s, and not the
    /// ones around 130s that the playback clock would have found.
    func testTheLinesComeFromTheDelayedPositionNotThePlaybackClock() {
        let atCueClock = SubtitleSyncByLine.candidates(in: track, cueClock: 20)
        let atPlaybackClock = SubtitleSyncByLine.candidates(in: track, cueClock: 130)

        XCTAssertTrue(atCueClock.lines.contains { $0.text == "Line 4" })
        XCTAssertFalse(atCueClock.lines.contains { $0.text == "Line 26" })
        // And the two windows really are different, so the assertion above is not vacuous.
        XCTAssertTrue(atPlaybackClock.lines.contains { $0.text == "Line 26" })
    }

    /// The line being spoken, or the next one due — never the last one that finished. On a file
    /// running early the finished line is already the wrong answer.
    func testTheAnchorIsTheLineOnScreenOrTheNextOneDue() {
        // 101s falls in the gap after Line 20 (100–103 is Line 20; 101 is inside it).
        let inside = SubtitleSyncByLine.candidates(in: track, cueClock: 101)
        XCTAssertEqual(inside.lines[inside.currentIndex].text, "Line 20")

        // 104s is between Line 20 and Line 21, so the next one due wins.
        let between = SubtitleSyncByLine.candidates(in: track, cueClock: 104)
        XCTAssertEqual(between.lines[between.currentIndex].text, "Line 21")
    }

    func testTheOfferIsBoundedEitherSide() {
        let found = SubtitleSyncByLine.candidates(in: track, cueClock: 100, radius: 3)

        XCTAssertEqual(found.lines.count, 7)
        XCTAssertEqual(found.currentIndex, 3)
    }

    /// At the start of a file there is nothing before the anchor, and the index has to follow —
    /// otherwise focus opens on the wrong row, or off the end of the list.
    func testTheIndexIsCorrectAtTheStartOfTheFile() {
        let found = SubtitleSyncByLine.candidates(in: track, cueClock: 0, radius: 6)

        XCTAssertEqual(found.currentIndex, 0)
        XCTAssertEqual(found.lines.first?.text, "Line 0")
    }

    func testTheIndexIsCorrectAtTheEndOfTheFile() {
        let found = SubtitleSyncByLine.candidates(in: track, cueClock: 10_000, radius: 6)

        XCTAssertEqual(found.lines.last?.text, "Line 39")
        XCTAssertEqual(found.lines[found.currentIndex].text, "Line 39")
    }

    func testAnUnsortedTrackIsStillOfferedInOrder() {
        let found = SubtitleSyncByLine.candidates(in: track.reversed(), cueClock: 100, radius: 2)

        XCTAssertEqual(found.lines.map(\.text), (18...22).map { "Line \($0)" })
    }

    func testAnEmptyTrackOffersNothingRatherThanCrashing() {
        let found = SubtitleSyncByLine.candidates(in: [], cueClock: 100)

        XCTAssertTrue(found.lines.isEmpty)
        XCTAssertEqual(found.currentIndex, 0)
    }

    // MARK: What the row says

    func testTheOffsetLabelSaysWhichWayTheLineWouldMove() {
        XCTAssertEqual(SubtitleSyncByLine.offsetLabel(for: cue(100, 103), at: 104.5), "+4.5s")
        XCTAssertEqual(SubtitleSyncByLine.offsetLabel(for: cue(110, 113), at: 104.5), "-5.5s")
    }

    /// A line already in sync should not read as a change, or every row looks like an adjustment.
    func testALineAlreadyInSyncReadsAsZero() {
        XCTAssertEqual(SubtitleSyncByLine.offsetLabel(for: cue(100, 103), at: 100.02), "0.0s")
    }
}

/// The delay reaching the cues this process draws.
///
/// mpv's `sub-delay` moves the tracks *mpv* renders. Addon subtitles are parsed and drawn here,
/// on both engines — so until now the delay control did nothing at all for the subtitles most
/// viewers actually use.
@MainActor
final class AddonSubtitleDelayTests: XCTestCase {
    private func controller(_ cues: [SubtitleCue]) -> SubtitleTrackController {
        let controller = SubtitleTrackController()
        controller.adoptForTesting(cues)
        return controller
    }

    func testWithNoDelayTheCueOnScreenIsTheOneAtThePlayhead() {
        let controller = controller([SubtitleCue(start: 100, end: 103, text: "A line")])
        controller.currentTime = 101

        XCTAssertEqual(controller.activeCues.map(\.text), ["A line"])
    }

    /// Positive means later: at a +5s delay the line written for 100s belongs on screen at 105s.
    func testAPositiveDelayHoldsTheLineBack() {
        let controller = controller([SubtitleCue(start: 100, end: 103, text: "A line")])
        controller.delay = 5

        controller.currentTime = 101
        XCTAssertTrue(controller.activeCues.isEmpty)

        controller.currentTime = 106
        XCTAssertEqual(controller.activeCues.map(\.text), ["A line"])
    }

    func testANegativeDelayBringsTheLineForward() {
        let controller = controller([SubtitleCue(start: 100, end: 103, text: "A line")])
        controller.delay = -5

        controller.currentTime = 96
        XCTAssertEqual(controller.activeCues.map(\.text), ["A line"])
    }

    /// The number every sync decision is made against, named once so the dialog and the overlay
    /// cannot disagree about where in the file they are.
    func testTheCueClockIsPlaybackMinusTheDelay() {
        let controller = controller([])
        controller.currentTime = 130
        controller.delay = 30

        XCTAssertEqual(controller.cueClock, 100, accuracy: 0.0001)
    }
}
