import XCTest
@testable import Nuvio

/// The skip card's state machine, ported from `SkipIntroVisibilityRules.kt`.
///
/// Reported: the card sometimes seemed not to appear, and seeking while it was up either did
/// nothing or made it vanish. The seeking half was the card holding focus with no handler for a
/// direction; this file covers the other half — when the card is on screen at all, and when it
/// is entitled to the remote.
final class SkipSegmentVisibilityTests: XCTestCase {
    private func state(
        active: Bool = true,
        autoHidden: Bool = false,
        controlsVisible: Bool = false,
        panelOpen: Bool = false,
        promptOpen: Bool = false
    ) -> SkipSegmentVisibility.State {
        SkipSegmentVisibility.State(
            hasActiveSegment: active,
            autoHidden: autoHidden,
            controlsVisible: controlsVisible,
            panelOpen: panelOpen,
            promptOpen: promptOpen
        )
    }

    // MARK: Showing

    func testCardShowsForAnActiveSegment() {
        XCTAssertTrue(SkipSegmentVisibility.showsCard(state()))
    }

    func testNoSegmentMeansNoCard() {
        XCTAssertFalse(SkipSegmentVisibility.showsCard(state(active: false)))
    }

    /// Ours draws above the engine's panels, so it has to leave rather than merely stop taking
    /// focus the way upstream's does. Choosing a subtitle mid-intro was a fight otherwise.
    func testAnOpenPanelHidesTheCardEntirely() {
        XCTAssertFalse(SkipSegmentVisibility.showsCard(state(panelOpen: true)))
        XCTAssertFalse(SkipSegmentVisibility.showsCard(state(controlsVisible: true, panelOpen: true)))
    }

    func testTheCardStepsAsideOnceItsCountdownHasRun() {
        XCTAssertFalse(SkipSegmentVisibility.showsCard(state(autoHidden: true)))
    }

    /// The deliberate divergence from `isSkipIntroButtonVisible`, and the reason for it is in a
    /// screenshot: drawn together, the card lands across the title in the transport. Everything
    /// it offers is on the control row underneath it, more precisely.
    func testTheCardStandsDownWhileTheTransportIsUp() {
        XCTAssertFalse(SkipSegmentVisibility.showsCard(state(controlsVisible: true)))
        XCTAssertFalse(SkipSegmentVisibility.showsCard(state(autoHidden: true, controlsVisible: true)))
    }

    // MARK: The countdown

    func testCountdownRunsOnlyOverBarePicture() {
        XCTAssertTrue(SkipSegmentVisibility.runsAutoHideCountdown(state()))
    }

    /// The term that keeps a pause from silently spending the card's life: on the MPV engine
    /// pausing raises the transport and nothing lowers it again, so a countdown that ignored
    /// this would expire during every pause and the card would be gone on resume.
    func testCountdownStopsWhileTheTransportIsUp() {
        XCTAssertFalse(SkipSegmentVisibility.runsAutoHideCountdown(state(controlsVisible: true)))
    }

    func testCountdownDoesNotRestartOnceSpent() {
        XCTAssertFalse(SkipSegmentVisibility.runsAutoHideCountdown(state(autoHidden: true)))
    }

    func testCountdownDoesNotRunBehindAPanel() {
        XCTAssertFalse(SkipSegmentVisibility.runsAutoHideCountdown(state(panelOpen: true)))
    }

    // MARK: Focus

    func testCardTakesTheRemoteOverBarePicture() {
        XCTAssertTrue(SkipSegmentVisibility.claimsFocus(state()))
    }

    /// The reported yank: focus was pulled out of a control row the viewer was using.
    func testCardDoesNotTakeFocusFromATransportInUse() {
        XCTAssertFalse(SkipSegmentVisibility.claimsFocus(state(controlsVisible: true)))
    }

    /// A countdown with a deadline outranks a card with no consequence for ignoring it.
    func testAPromptKeepsTheRemote() {
        XCTAssertFalse(SkipSegmentVisibility.claimsFocus(state(promptOpen: true)))
        XCTAssertTrue(
            SkipSegmentVisibility.showsCard(state(promptOpen: true)),
            "an outro and the up-next card are active at the same moment by definition"
        )
    }

    func testAHiddenCardNeverHoldsFocus() {
        XCTAssertFalse(SkipSegmentVisibility.claimsFocus(state(autoHidden: true)))
        XCTAssertFalse(SkipSegmentVisibility.claimsFocus(state(active: false)))
        XCTAssertFalse(SkipSegmentVisibility.claimsFocus(state(panelOpen: true)))
    }
}

/// When "You are watching" is allowed to rise.
///
/// Reported: pausing and then opening the subtitle chooser raised the card over the list of
/// languages a few seconds later. The rule had been only "is playback stopped".
final class PlayerPauseCardPolicyTests: XCTestCase {
    private func state(
        paused: Bool = true,
        enabled: Bool = true,
        started: Bool = true,
        panelOpen: Bool = false,
        promptOpen: Bool = false
    ) -> PlayerPauseCardPolicy.State {
        PlayerPauseCardPolicy.State(
            isPaused: paused,
            isEnabled: enabled,
            hasStartedPlayback: started,
            panelOpen: panelOpen,
            promptOpen: promptOpen
        )
    }

    func testADeliberatePauseRaisesTheCard() {
        XCTAssertTrue(PlayerPauseCardPolicy.shouldRaise(state()))
    }

    func testPlayingNeverRaisesIt() {
        XCTAssertFalse(PlayerPauseCardPolicy.shouldRaise(state(paused: false)))
    }

    func testTheSettingIsHonoured() {
        XCTAssertFalse(PlayerPauseCardPolicy.shouldRaise(state(enabled: false)))
    }

    /// A card describing a film that has not started is a cover, not a pause card.
    func testNothingRisesBeforeTheFirstFrame() {
        XCTAssertFalse(PlayerPauseCardPolicy.shouldRaise(state(started: false)))
    }

    /// The reported bug. Choosing a subtitle is not sitting idle, and the card would land on top
    /// of the list being read.
    func testAnOpenPanelKeepsTheCardDown() {
        XCTAssertFalse(PlayerPauseCardPolicy.shouldRaise(state(panelOpen: true)))
    }

    /// Both prompts hold playback stopped while they wait for an answer, so "paused" there is
    /// the app's doing rather than the viewer's.
    func testAPromptKeepsTheCardDown() {
        XCTAssertFalse(PlayerPauseCardPolicy.shouldRaise(state(promptOpen: true)))
    }
}
