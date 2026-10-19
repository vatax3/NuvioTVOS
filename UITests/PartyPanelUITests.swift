import XCTest

/// Can the player's watch-party panel be used with a remote?
///
/// Reported twice: the rows could not be reached and the panel could not be left. The first
/// version of it declared `handlesExit: false` — which is right for the panels `MPVPlayerView`
/// owns centrally and wrong for one rendered beside it — and was missing from the player's
/// `hasFocusableOverlay`, so the transport never yielded the remote.
///
/// Neither fact is visible to a policy test. Both are properties of the focus and responder
/// graph, which exist only at runtime — the fourth time this feature has had to be told that.
final class PartyPanelUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-nuvioPlayerHarness", "-nuvioPartyHarness"]
        app.launchEnvironment["NUVIO_HARNESS_PARTY_PANEL"] = "1"
        app.launch()
    }

    @discardableResult
    private func wait(for condition: () -> Bool, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return false
    }

    private var sharing: XCUIElement { app.buttons["party.panel.sharing"] }
    private var hostOnly: XCUIElement { app.buttons["party.panel.hostOnly"] }
    private var end: XCUIElement { app.buttons["party.panel.end"] }

    /// Waits for the panel *and* for a row to hold the remote.
    ///
    /// Generous, and for the reason `PlayerRemoteUITests` documents: on a simulator that has just
    /// run the whole unit suite, a cold launch to first frame has been measured past twenty
    /// seconds, and the panel is staged after playback settles.
    private func awaitPanel(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            wait(for: { self.sharing.exists }, timeout: 60),
            "the party panel should open with playback", file: file, line: line
        )
        XCTAssertTrue(
            wait(for: { self.sharing.hasFocus }, timeout: 20),
            "a row should claim focus — the transport must not keep it", file: file, line: line
        )
    }

    /// The panel must take the remote from the transport, and land it somewhere definite.
    func testThePanelTakesTheRemote() {
        awaitPanel()
    }

    /// And the rows below it must be reachable, which is the part a missing focus target breaks.
    func testTheRowsBelowCanBeReached() {
        awaitPanel()
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(wait(for: { self.hostOnly.hasFocus }), "Down should reach the next control")

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(wait(for: { self.end.hasFocus }), "and the one after it")
    }

    /// Menu closes the panel and leaves playback alone. The panel used to declare that the
    /// player handled Menu for it, and the player knew nothing about it — so the press went
    /// nowhere and there was no way out.
    func testMenuClosesThePanelAndNotPlayback() {
        awaitPanel()
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(wait(for: { !self.sharing.exists }), "Menu should close the panel")
        XCTAssertTrue(
            app.buttons["player.transport.playPause"].exists, "…and leave playback running"
        )
    }

    /// The host's restriction is a switch with one title, not a button whose label says the
    /// opposite of what is true. It used to flip its title to the action while the highlight
    /// showed the state, which read as inverted — because it was.
    func testTheHostOnlyControlKeepsOneTitle() {
        awaitPanel()
        let before = hostOnly.label
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(wait(for: { self.hostOnly.hasFocus }))
        XCUIRemote.shared.press(.select)

        // The state changes; the title does not.
        usleep(800_000)
        XCTAssertEqual(hostOnly.label, before, "the title must not flip with the state")
    }
}
