import XCTest

/// Ending a watch party from Settings, which was reported as a crash.
///
/// There is no other way to look at it. A party needs an account, a live backend with the
/// feature switched on and a second device, so the only observations of this screen so far have
/// been made by hand on a television — and a crash seen that way comes back as the word "crash"
/// with no stack trace attached. `PartyHarness` stages the party; this drives the real remote at
/// the real button.
///
/// The suspicion it was written to test: the player's panel ends a party *and dismisses itself*,
/// while this screen ends it and stays mounted — so the whole content swaps underneath the
/// button holding focus, and what replaces it is a text field as the only focusable view on
/// screen.
final class PartyRosterUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // `-nuvioUITesting` is not decoration: a fresh test container is indistinguishable from
        // a first install, so without it the onboarding wizard comes up over Settings. The party
        // row still answers `exists` from underneath it — it is in the tree, just covered — and
        // the only visible symptom is that focus never reaches it. This suite therefore passed
        // only on a simulator that had been through onboarding by hand, and failed on every
        // clean one.
        app.launchArguments = [
            "-nuvioUITesting", "-nuvioPartyHarness",
            "-startTab", "settings", "-settingsSection", "watchParty"
        ]
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

    /// Settings opens on the Watch party section; its one row pushes the roster.
    private func openRoster(file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["settings.party.open"]
        XCTAssertTrue(
            wait(for: { row.exists }, timeout: 45),
            "the Watch party section should list the staged party", file: file, line: line
        )
        // Right out of the rail and into the section, then Select on its only row.
        for _ in 0..<3 {
            if row.hasFocus { break }
            XCUIRemote.shared.press(.right)
            usleep(600_000)
        }
        XCTAssertTrue(row.hasFocus, "the party row should take focus", file: file, line: line)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            wait(for: { self.app.buttons["party.roster.end"].exists }),
            "the roster should open — tree:\n\(app.debugDescription)", file: file, line: line
        )
    }

    func testEndingThePartyFromSettingsDoesNotTakeTheAppDown() {
        openRoster()

        let end = app.buttons["party.roster.end"]
        // Down from the primary action into the row of secondary ones, then across to End.
        // Bounded rather than counted: which control the focus engine lands on first is its own
        // decision, and a counted walk that assumes otherwise is the fragile kind.
        search: for _ in 0..<4 {
            for _ in 0..<4 {
                if end.hasFocus { break search }
                XCUIRemote.shared.press(.right)
                usleep(350_000)
            }
            XCUIRemote.shared.press(.down)
            usleep(350_000)
        }
        XCTAssertTrue(end.hasFocus, "End should be reachable from the roster")
        XCUIRemote.shared.press(.select)

        // The party is gone either way; the question is whether the app is.
        XCTAssertTrue(wait(for: { !end.exists }), "ending should clear the roster")
        XCTAssertEqual(
            app.state, .runningForeground,
            "ending a party must not take the app down with it"
        )

        // And it goes back rather than swapping its own content under the press — which is both
        // what a viewer expects and what keeps a destroyed focused button from being replaced by
        // a text field in the same frame.
        XCTAssertTrue(
            wait(for: { self.app.buttons["settings.party.open"].exists }),
            "ending should return to Settings"
        )
        XCUIRemote.shared.press(.menu)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
