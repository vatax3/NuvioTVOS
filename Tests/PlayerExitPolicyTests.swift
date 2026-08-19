import XCTest
@testable import Nuvio

final class PlayerExitPolicyTests: XCTestCase {
    private let fresh = PlayerExitPolicy.echoWindow + 0.1

    /// The reported failure: Menu from an open track panel closed the panel and then left
    /// playback, dropping the viewer on the stream list.
    func testMenuFromAnOpenPanelOnlyClosesThePanel() {
        let state = PlayerExitPolicy.State(hasOpenPanel: true, showsControls: true)
        XCTAssertEqual(
            PlayerExitPolicy.action(for: state, sinceLastHandledPress: fresh),
            .closePanel
        )
    }

    /// The second half of that failure: the duplicate delivery of the same press must not be
    /// read as a fresh decision, or it dismisses the player the panel just returned to.
    func testEchoOfTheSamePressIsIgnored() {
        let afterClose = PlayerExitPolicy.State(showsControls: true)
        XCTAssertEqual(
            PlayerExitPolicy.action(for: afterClose, sinceLastHandledPress: 0.05),
            .ignore
        )
    }

    func testDeliberateSecondPressStillLands() {
        let afterClose = PlayerExitPolicy.State(showsControls: true)
        XCTAssertEqual(
            PlayerExitPolicy.action(for: afterClose, sinceLastHandledPress: fresh),
            .hideControls
        )
    }

    /// Android's order: the transport is dismissed before playback is.
    func testMenuLeavesPlaybackOnlyOnceNothingIsShowing() {
        XCTAssertEqual(
            PlayerExitPolicy.action(for: PlayerExitPolicy.State(), sinceLastHandledPress: fresh),
            .dismissPlayback
        )
    }

    /// Android offers Back to the next-episode card and the still-watching check before the
    /// transport, so a countdown is cancelled rather than the film being left.
    func testPromptsAbsorbThePressBeforeTheTransportDoes() {
        let state = PlayerExitPolicy.State(hasOpenPrompt: true, showsControls: true)
        XCTAssertEqual(
            PlayerExitPolicy.action(for: state, sinceLastHandledPress: fresh),
            .closePrompt
        )
    }

    func testMoreActionsCollapseBeforeTheTransportHides() {
        let state = PlayerExitPolicy.State(showsMoreActions: true, showsControls: true)
        XCTAssertEqual(
            PlayerExitPolicy.action(for: state, sinceLastHandledPress: fresh),
            .closeMoreActions
        )
    }

    /// An error overlay has nothing to go back to, so Menu leaves straight away.
    func testErrorOverlayLeavesPlaybackEvenWithAPanelOpen() {
        let state = PlayerExitPolicy.State(hasError: true, hasOpenPanel: true, showsControls: true)
        XCTAssertEqual(
            PlayerExitPolicy.action(for: state, sinceLastHandledPress: fresh),
            .dismissPlayback
        )
    }
}

final class PlayerScrubRatesTests: XCTestCase {
    func testASingleTapIsAlwaysTheShortStep() {
        XCTAssertEqual(PlayerScrubRates.step(forRepeatCount: 0), PlayerScrubRates.shortStep)
        XCTAssertEqual(PlayerScrubRates.step(forRepeatCount: 2), PlayerScrubRates.shortStep)
    }

    func testHoldingAcceleratesThroughAndroidsThresholds() {
        XCTAssertEqual(PlayerScrubRates.step(forRepeatCount: 3), PlayerScrubRates.mediumStep)
        XCTAssertEqual(PlayerScrubRates.step(forRepeatCount: 8), PlayerScrubRates.longStep)
        XCTAssertEqual(PlayerScrubRates.step(forRepeatCount: 15), PlayerScrubRates.veryLongStep)
        XCTAssertEqual(PlayerScrubRates.step(forRepeatCount: 400), PlayerScrubRates.veryLongStep)
    }

    func testDirectionOnlyChangesTheSign() {
        XCTAssertEqual(PlayerScrubRates.delta(forRepeatCount: 9, forward: true), 30)
        XCTAssertEqual(PlayerScrubRates.delta(forRepeatCount: 9, forward: false), -30)
    }
}
