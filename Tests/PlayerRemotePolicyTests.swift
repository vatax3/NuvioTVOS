import XCTest
@testable import Nuvio

final class PlayerRemotePolicyTests: XCTestCase {
    private let watching = PlayerRemotePolicy.State()
    private let transportUp = PlayerRemotePolicy.State(showsControls: true)

    // MARK: The reported failure

    /// With the transport hidden, pressing anything left the remote apparently dead: the
    /// buttons still held focus while invisible, so the focus engine consumed the press and
    /// nothing came back.
    func testAnyDirectionBringsTheTransportBackWhenItIsDown() {
        XCTAssertEqual(PlayerRemotePolicy.move(.up, in: watching), .reveal)
        XCTAssertEqual(PlayerRemotePolicy.move(.down, in: watching), .reveal)
    }

    func testHorizontalPressesSeekRatherThanOnlyRevealing() {
        XCTAssertEqual(PlayerRemotePolicy.move(.left, in: watching), .seek(forward: false))
        XCTAssertEqual(PlayerRemotePolicy.move(.right, in: watching), .seek(forward: true))
    }

    func testSelectOverBareVideoRevealsTheTransport() {
        XCTAssertEqual(PlayerRemotePolicy.select(in: watching), .reveal)
    }

    func testPlayPauseAlwaysToggles() {
        XCTAssertEqual(PlayerRemotePolicy.playPause(in: watching), .togglePause)
        XCTAssertEqual(PlayerRemotePolicy.playPause(in: transportUp), .togglePause)
    }

    /// A dedicated Play/Pause key is not a request to navigate, so a panel does not swallow it.
    func testPlayPauseReachesThroughAnOpenPanel() {
        let panel = PlayerRemotePolicy.State(hasOpenPanel: true, showsControls: true)
        XCTAssertEqual(PlayerRemotePolicy.playPause(in: panel), .togglePause)
    }

    // MARK: Staying out of the way

    /// Once the transport is up its own controls own the remote — reading the press here too
    /// is what would seek and move focus on one press of Right.
    func testTheTransportKeepsItsOwnPressesWhenItIsUp() {
        XCTAssertEqual(PlayerRemotePolicy.move(.right, in: transportUp), .none)
        XCTAssertEqual(PlayerRemotePolicy.select(in: transportUp), .none)
        XCTAssertEqual(PlayerRemotePolicy.focusOwner(transportUp), .transport)
    }

    /// The skip-intro card, the next-episode countdown and the still-watching check are
    /// focusable layers of their own: claiming focus back is what put them out of reach.
    func testAFocusableOverlayKeepsBothFocusAndItsPresses() {
        let overlay = PlayerRemotePolicy.State(hasFocusableOverlay: true)
        XCTAssertEqual(PlayerRemotePolicy.focusOwner(overlay), .unmanaged)
        XCTAssertEqual(PlayerRemotePolicy.move(.down, in: overlay), .none)
        XCTAssertEqual(PlayerRemotePolicy.select(in: overlay), .none)
    }

    func testAnOpenPanelOwnsTheRemote() {
        let panel = PlayerRemotePolicy.State(hasOpenPanel: true, showsControls: true)
        XCTAssertEqual(PlayerRemotePolicy.focusOwner(panel), .unmanaged)
        XCTAssertFalse(PlayerRemotePolicy.controlsInteractable(panel))
    }

    // MARK: The pause card

    /// It covers the picture with its own metadata, so the transport underneath has to leave
    /// the focus graph with it — and the first press takes the card away rather than seeking
    /// somewhere nobody can see.
    func testThePauseCardOwnsTheRemoteAndTheFirstPressDismissesIt() {
        let paused = PlayerRemotePolicy.State(showsPauseCard: true, showsControls: true)
        XCTAssertEqual(PlayerRemotePolicy.focusOwner(paused), .sink)
        XCTAssertFalse(PlayerRemotePolicy.controlsInteractable(paused))
        XCTAssertEqual(PlayerRemotePolicy.move(.left, in: paused), .dismissPauseCard)
        XCTAssertEqual(PlayerRemotePolicy.move(.up, in: paused), .dismissPauseCard)
        XCTAssertEqual(PlayerRemotePolicy.select(in: paused), .resume)
    }

    // MARK: Errors

    func testAnErrorLeavesEverythingToTheErrorOverlay() {
        let failed = PlayerRemotePolicy.State(hasError: true, showsControls: true)
        XCTAssertEqual(PlayerRemotePolicy.focusOwner(failed), .unmanaged)
        XCTAssertFalse(PlayerRemotePolicy.controlsInteractable(failed))
        XCTAssertEqual(PlayerRemotePolicy.move(.down, in: failed), .none)
        XCTAssertEqual(PlayerRemotePolicy.playPause(in: failed), .none)
    }

    // MARK: Focus is never left unowned

    /// The invariant behind the whole file: in every state where the player is what the remote
    /// is pointed at, some element of it holds focus.
    func testSomethingAlwaysOwnsTheRemote() {
        for controls in [true, false] {
            for pauseCard in [true, false] {
                let state = PlayerRemotePolicy.State(
                    showsPauseCard: pauseCard, showsControls: controls
                )
                XCTAssertNotEqual(PlayerRemotePolicy.focusOwner(state), .unmanaged)
            }
        }
    }
}
