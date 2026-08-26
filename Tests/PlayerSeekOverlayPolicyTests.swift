import XCTest
@testable import Nuvio

/// The rules behind the hidden-controls seek, which is the half of the remote that must not
/// reveal the transport. The other half — that a press always answers — is asserted end to end
/// in `PlayerRemoteUITests`, because it depends on where the focus engine put focus.
final class PlayerSeekOverlayPolicyTests: XCTestCase {
    func testAScrubBehindABarePictureDoesNotRevealTheTransport() {
        XCTAssertFalse(
            PlayerSeekOverlayPolicy.revealsTransport(controlsInteractable: false),
            "revealing it would cover the picture the viewer is scrubbing through"
        )
    }

    /// When the bar is already up it carries the position itself, and the press should restart
    /// its auto-hide timer rather than draw a second readout beside it.
    func testAScrubFromTheBarKeepsTheBar() {
        XCTAssertTrue(PlayerSeekOverlayPolicy.revealsTransport(controlsInteractable: true))
    }

    func testTimecodeDropsTheHourUntilThereIsOne() {
        XCTAssertEqual(PlayerSeekOverlayPolicy.timecode(0), "0:00")
        XCTAssertEqual(PlayerSeekOverlayPolicy.timecode(67), "1:07")
        XCTAssertEqual(PlayerSeekOverlayPolicy.timecode(3599), "59:59")
        XCTAssertEqual(PlayerSeekOverlayPolicy.timecode(3600), "1:00:00")
        XCTAssertEqual(PlayerSeekOverlayPolicy.timecode(3725), "1:02:05")
    }

    /// mpv reports a position before it reports a duration, and an unseekable stream reports
    /// neither. A readout is not worth a crash.
    func testTimecodeSurvivesTheValuesMpvActuallyEmits() {
        XCTAssertEqual(PlayerSeekOverlayPolicy.timecode(.nan), "0:00")
        XCTAssertEqual(PlayerSeekOverlayPolicy.timecode(.infinity), "0:00")
        XCTAssertEqual(PlayerSeekOverlayPolicy.timecode(-12), "0:00")
    }

    func testTheOffsetIsSignedAndReadsFromWherePlaybackWas() {
        XCTAssertEqual(PlayerSeekOverlayPolicy.offsetLabel(from: 100, to: 130), "+0:30")
        XCTAssertEqual(PlayerSeekOverlayPolicy.offsetLabel(from: 100, to: 40), "\u{2212}1:00")
        XCTAssertEqual(PlayerSeekOverlayPolicy.offsetLabel(from: 0, to: 3661), "+1:01:01")
    }

    /// A press that lands where playback already is — the start of the film, the end of it —
    /// should show the position without an offset that reads "+0:00".
    func testAScrubThatWentNowhereShowsNoOffset() {
        XCTAssertNil(PlayerSeekOverlayPolicy.offsetLabel(from: 100, to: 100))
        XCTAssertNil(PlayerSeekOverlayPolicy.offsetLabel(from: 100, to: 100.4))
        XCTAssertNil(PlayerSeekOverlayPolicy.offsetLabel(from: .nan, to: 100))
    }

    /// The offset grows across a held direction because it is measured from the origin, not
    /// from the previous press — the behaviour that turns a hold into one legible jump.
    func testAHeldDirectionAccumulatesInsteadOfRepeating() {
        let origin = 600.0
        var target = origin
        for count in 0..<4 {
            target += PlayerScrubRates.delta(forRepeatCount: count, forward: true)
        }

        XCTAssertEqual(target, origin + 10 + 10 + 10 + 20)
        XCTAssertEqual(PlayerSeekOverlayPolicy.offsetLabel(from: origin, to: target), "+0:50")
    }

    func testTheTrackStaysInsideItsBoundsWhateverTheDurationIs() {
        XCTAssertEqual(PlayerSeekOverlayPolicy.fraction(target: 30, duration: 120), 0.25)
        XCTAssertEqual(PlayerSeekOverlayPolicy.fraction(target: 500, duration: 120), 1)
        XCTAssertEqual(PlayerSeekOverlayPolicy.fraction(target: -5, duration: 120), 0)
        // A live stream, or a file mpv has not measured yet.
        XCTAssertEqual(PlayerSeekOverlayPolicy.fraction(target: 30, duration: 0), 0)
    }

    /// The readout has to outlive the seek it describes: `scrub` waits 300 ms before committing
    /// and mpv takes about another 700 ms to land. Fading first leaves an unexplained jump.
    func testTheReadoutOutlastsTheSeekItDescribes() {
        XCTAssertGreaterThan(PlayerSeekOverlayPolicy.linger, 1.0)
    }
}
