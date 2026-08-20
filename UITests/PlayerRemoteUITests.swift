import XCTest

/// The regression test for the reported failure: with the transport hidden, pressing anything
/// on the remote left the picture untouched — the controls only came back after a Menu press.
///
/// It cannot be checked any other way. Whether a press reaches the player depends on where the
/// tvOS focus engine has put focus at that instant, which exists only at runtime; everything
/// that can be decided on paper lives in `PlayerRemotePolicy` and is unit-tested there.
///
/// The harness plays a stream that never answers on purpose. The subject is the transport's
/// focus behaviour, and a source that neither fails nor arrives holds the player in its
/// ordinary playing state for the length of a test without depending on a network.
final class PlayerRemoteUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Longer than the transport's own five-second countdown.
    private let autoHide: TimeInterval = 7

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-nuvioPlayerHarness"]
        app.launch()
    }

    private var playPause: XCUIElement { app.buttons["player.transport.playPause"] }
    /// The invisible full-screen target that owns the remote while the transport is down.
    private var sink: XCUIElement { app.otherElements["player.remoteSink"] }

    /// Focus is the only honest signal here: the transport is faded rather than unmounted, so
    /// "is it on screen" cannot tell a live control row from the ghost of one. Which control
    /// holds it is left open — tvOS picks between the scrubber and Play/Pause on its own.
    private var transportHoldsRemote: Bool { playPause.isEnabled && !sink.hasFocus }

    @discardableResult
    private func wait(for condition: () -> Bool, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return false
    }

    /// Leaves the player with its transport down, which is the state every test below starts in.
    private func hideTransport(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            wait(for: { self.transportHoldsRemote }, timeout: 20),
            "the transport should come up with playback", file: file, line: line
        )
        Thread.sleep(forTimeInterval: autoHide)
        XCTAssertTrue(
            sink.hasFocus,
            "a hidden transport must hand the remote to the sink", file: file, line: line
        )
        XCTAssertFalse(
            playPause.isEnabled,
            "a hidden transport must leave the focus graph, or Select works buttons nobody can see",
            file: file, line: line
        )
    }

    func testTransportTakesTheRemoteWhenPlaybackOpens() {
        XCTAssertTrue(wait(for: { self.transportHoldsRemote }, timeout: 20))
    }

    func testTransportHandsTheRemoteOverWhenItHides() {
        hideTransport()
    }

    /// The reported bug, direction by direction.
    func testEveryDirectionBringsTheTransportBack() {
        for button in [XCUIRemote.Button.down, .up, .left, .right] {
            hideTransport()
            XCUIRemote.shared.press(button)
            XCTAssertTrue(
                wait(for: { self.transportHoldsRemote }),
                "pressing \(button) with the transport down must bring it back"
            )
        }
    }

    func testSelectBringsTheTransportBack() {
        hideTransport()
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            wait(for: { self.transportHoldsRemote }),
            "Select over bare video must bring the transport back"
        )
    }

    /// Menu's ordered chain, checked where it actually runs. The unit tests cover the ordering;
    /// this covers the part that only exists at runtime — that the press reaches the player at
    /// all rather than the presentation behind it, which is what used to drop a viewer back on
    /// the stream list from inside a track panel.
    func testMenuHidesTheTransportBeforeLeavingPlayback() {
        XCTAssertTrue(wait(for: { self.transportHoldsRemote }, timeout: 20))

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            wait(for: { self.sink.hasFocus }),
            "the first Menu press should put the transport away, not end playback"
        )
        XCTAssertTrue(playPause.exists, "playback should still be up")

        // Deliberately spaced. One physical press can be delivered twice while focus is
        // rebuilt, so `PlayerExitPolicy` treats anything inside 350ms as that echo — and two
        // automated presses land far closer together than two human ones ever do.
        Thread.sleep(forTimeInterval: 1)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            wait(for: { !self.playPause.exists }),
            "a second Menu press, with nothing left showing, should leave playback"
        )
    }

    func testPlayPauseBringsTheTransportBack() {
        hideTransport()
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(
            wait(for: { self.transportHoldsRemote }),
            "Play/Pause must both act and show what it did"
        )
    }
}
