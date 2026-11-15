import XCTest
@testable import Nuvio

/// IntroDB's film route, and what the player does with the two segments it returns.
///
/// The percentage threshold we shipped in 1.0.35 is a poor stand-in for "the film is over":
/// credits run from ninety seconds to eight minutes, so 90% lands deep inside them on a long
/// film and before the last scene on a short one. These are the rules that replace it.
final class MovieCreditsTests: XCTestCase {
    private func segment(_ kind: SkipSegment.Kind, _ start: Double, _ end: Double) -> SkipSegment {
        SkipSegment(kind: kind, start: start, end: end)
    }

    // MARK: Decoding the two segments

    func testCreditsAndSceneComeBackAsTwoSegments() {
        let segments = SkipIntroClient.movieSegments(credits: (6000, 6600), scene: (6700, 6800))
        XCTAssertEqual(segments.map(\.kind), [.movieCredits, .postCredits])
        XCTAssertEqual(segments[0].end, 6600)
    }

    /// Submitters routinely mark the credits as running to the end of the file and then someone
    /// else marks the scene inside them. Taken literally, *Skip credits* would jump past the very
    /// thing the separate mark exists to protect.
    func testCreditsAreClippedWhereTheSceneBegins() {
        let segments = SkipIntroClient.movieSegments(credits: (6000, 7200), scene: (6900, 7000))
        XCTAssertEqual(segments[0].kind, .movieCredits)
        XCTAssertEqual(segments[0].end, 6900)
    }

    func testCreditsSwallowedEntirelyByTheSceneAreDropped() {
        let segments = SkipIntroClient.movieSegments(credits: (6900, 7000), scene: (6800, 7100))
        XCTAssertEqual(segments.map(\.kind), [.postCredits])
    }

    func testAFilmWithNoMarksDecodesToNothing() {
        XCTAssertTrue(SkipIntroClient.movieSegments(credits: nil, scene: nil).isEmpty)
    }

    // MARK: When the film is over

    func testNoMarksFallsBackToThePercentage() {
        XCTAssertEqual(
            PostPlayRecommendation.triggerPositionSeconds(
                durationSeconds: 7200, thresholdPercent: 90, segments: [], tailWindowSeconds: 216
            ),
            6480
        )
    }

    /// The whole point of the change: credits that start at 92 minutes of a 120-minute film fire
    /// the card there, not at 108 minutes with a third of the credits already gone.
    func testCreditsFireTheCardWhereTheyBegin() {
        let segments = [segment(.movieCredits, 5520, 7190)]
        XCTAssertEqual(
            PostPlayRecommendation.triggerPositionSeconds(
                durationSeconds: 7200, thresholdPercent: 90, segments: segments, tailWindowSeconds: 216
            ),
            5520
        )
    }

    /// An "End Credits" chapter arrives as an outro; in the second half it is the end credits.
    func testAnEndCreditsChapterFiresTheCardWhereItBegins() {
        let segments = [segment(.outro, 5520, 7190)]
        XCTAssertEqual(
            PostPlayRecommendation.triggerPositionSeconds(
                durationSeconds: 7200, thresholdPercent: 90, segments: segments, tailWindowSeconds: 216
            ),
            5520
        )
    }

    /// An opening "Credits" chapter is not the end of the film.
    func testAnOutroInTheFirstHalfIsNotTheEndCredits() {
        let segments = [segment(.outro, 30, 120)]
        XCTAssertEqual(
            PostPlayRecommendation.triggerPositionSeconds(
                durationSeconds: 7200, thresholdPercent: 90, segments: segments, tailWindowSeconds: 216
            ),
            6480
        )
    }

    /// A scene is the one part of the credits nobody wants covered by a carousel, so the card
    /// waits for its end rather than its start.
    func testAMarkedSceneHoldsTheCardUntilItHasPlayed() {
        let segments = [segment(.movieCredits, 6000, 6900), segment(.postCredits, 6900, 7000)]
        XCTAssertEqual(
            PostPlayRecommendation.triggerPositionSeconds(
                durationSeconds: 7200, thresholdPercent: 90, segments: segments, tailWindowSeconds: 216
            ),
            7000
        )
    }

    /// Different releases of one film differ at the tail. A trigger past this runtime never fires.
    func testASceneEndingPastThisReleaseIsClampedToTheRuntime() {
        let segments = [segment(.movieCredits, 6000, 6900), segment(.postCredits, 6900, 7400)]
        XCTAssertEqual(
            PostPlayRecommendation.triggerPositionSeconds(
                durationSeconds: 7200, thresholdPercent: 90, segments: segments, tailWindowSeconds: 216
            ),
            7200
        )
    }

    /// Credits ending well before the file does usually mean an unsubmitted stinger. The tail is
    /// used instead of the credits, so the card does not cover it.
    func testAnUnexplainedTailAfterTheCreditsIsTreatedAsAScene() {
        let segments = [segment(.movieCredits, 5520, 6800)]
        XCTAssertEqual(
            PostPlayRecommendation.triggerPositionSeconds(
                durationSeconds: 7200, thresholdPercent: 90, segments: segments, tailWindowSeconds: 216
            ),
            6984
        )
    }

    /// A tail shorter than the window is just the file ending. Back to the credits.
    func testAShortTailStillFiresOnTheCredits() {
        let segments = [segment(.movieCredits, 5520, 7100)]
        XCTAssertEqual(
            PostPlayRecommendation.triggerPositionSeconds(
                durationSeconds: 7200, thresholdPercent: 90, segments: segments, tailWindowSeconds: 216
            ),
            5520
        )
    }

    // MARK: The tail window

    /// The film threshold is the wrong tool here — a tenth of the runtime by default, and every
    /// film's credits are longer than that, so every film would look like it hid a scene.
    func testThePercentageTailWindowIsClampedToThreePercent() {
        XCTAssertEqual(
            PostPlayRecommendation.tailWindowSeconds(
                mode: .percent, percent: 90, minutesBeforeEnd: 2, durationSeconds: 7200
            ),
            216,
            accuracy: 0.001
        )
    }

    func testTheMinutesTailWindowIsCappedAtThreeAndAHalf() {
        XCTAssertEqual(
            PostPlayRecommendation.tailWindowSeconds(
                mode: .minutesBeforeEnd, percent: 95, minutesBeforeEnd: 9, durationSeconds: 7200
            ),
            210
        )
    }

    // MARK: The card

    /// "Skip the post-credits scene" is not an offer anyone wants.
    func testTheSceneNeverEarnsACardOfItsOwn() {
        XCTAssertFalse(PostCreditsScene.offersCard(segment(.postCredits, 6900, 7000)))
        XCTAssertTrue(PostCreditsScene.offersCard(segment(.movieCredits, 6000, 6900)))
    }

    func testTheCardLandsOnTheSceneRatherThanPastIt() {
        let segments = [segment(.movieCredits, 6000, 6900), segment(.postCredits, 6900, 7000)]
        XCTAssertEqual(
            PostCreditsScene.skipTarget(for: segments[0], in: segments, durationSeconds: 7200),
            6900
        )
    }

    func testAFilmWithNothingAfterItsCreditsSkipsStraightToTheEnd() {
        let segments = [segment(.movieCredits, 6000, 7199)]
        XCTAssertNil(PostCreditsScene.following(segments[0], in: segments, durationSeconds: 7200))
        XCTAssertEqual(
            PostCreditsScene.skipTarget(for: segments[0], in: segments, durationSeconds: 7200),
            7199
        )
    }

    /// Upstream extended this to series outros three days before it was ported. Their series
    /// route cannot return an explicit scene, so on series the change is the five-second
    /// heuristic alone — and almost every episode has more than five seconds of black, a studio
    /// card or a next-episode preview after its ending.
    func testASeriesOutroIsNotRelabelledAsLeadingToAScene() {
        let outro = segment(.outro, 1300, 1400)
        XCTAssertNil(PostCreditsScene.following(outro, in: [outro], durationSeconds: 1440))
    }

    func testTheSceneItselfIsNotSkippable() {
        let scene = segment(.postCredits, 6900, 7000)
        XCTAssertNil(PostCreditsScene.skipTarget(for: scene, in: [scene], durationSeconds: 7200))
    }
}
