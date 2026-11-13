import XCTest

/// Vertical travel between Home rails, and Back on Home (#6).
///
/// Reported: moving up or down landed "randomly" in the next rail — tvOS picks whichever card is
/// geometrically nearest — and Back left the app from anywhere on the screen. A rail now returns
/// to the card it was left on (its first, if never visited), as Android's `focusRestorer` does,
/// and Back from below the first rail goes back to the top before a second press leaves.
final class RailFocusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-nuvioUITesting", "-startTab", "home", "-nuvioLibraryHarness"]
        app.launch()
    }

    private var focusedCard: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'card.' AND hasFocus == true")
        ).firstMatch
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times {
            XCUIRemote.shared.press(button)
            usleep(700_000)
        }
    }

    /// From Continue Watching down onto the first catalog rail that has a poster.
    private func reachFirstCatalogRail() {
        XCTAssertTrue(
            app.buttons["card.continue.harness-resume"].waitForExistence(timeout: 30),
            "the fixture rail should be up"
        )
        for _ in 0..<6 {
            if focusedCard.exists, focusedCard.identifier.hasPrefix("card.poster.") { return }
            press(.down)
        }
        XCTFail("a catalog poster should be reachable below Continue Watching")
    }

    func testARailIsReturnedToOnTheCardItWasLeftOn() {
        reachFirstCatalogRail()
        press(.right, times: 4)
        let leftOn = focusedCard.identifier
        let leftOnX = focusedCard.frame.minX

        press(.down)
        XCTAssertNotEqual(focusedCard.identifier, leftOn, "down should leave the rail")
        // Never visited, so it opens on its first card — not on whatever sat under the fifth.
        XCTAssertLessThan(
            focusedCard.frame.minX, leftOnX,
            "a rail not visited yet should open on its first card"
        )

        press(.right)
        press(.up)
        XCTAssertEqual(
            focusedCard.identifier, leftOn, "up should return to the card the rail was left on"
        )
    }

    func testBackGoesToTheTopThenLeaves() {
        reachFirstCatalogRail()
        press(.down)

        press(.menu)
        XCTAssertEqual(app.state, .runningForeground, "Back below the top should stay in the app")
        XCTAssertTrue(
            app.buttons["card.continue.harness-resume"].hasFocus,
            "Back below the top should return to the first card of the first rail"
        )

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 10),
            "Back from the top should leave the app"
        )
    }
}

/// Reported: Continue Watching showed only what was started on this Apple TV, while the account
/// held more (#4). Rows from account sync carry no artwork, and the rail skips a row it cannot
/// draw; Home now fetches the missing previews from the installed addons.
final class SyncedContinueWatchingUITests: XCTestCase {
    func testASyncedTitleWithNoArtworkAppearsInContinueWatching() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-nuvioUITesting", "-startTab", "home",
            "-nuvioLibraryHarness", "-nuvioSyncedProgressHarness"
        ]
        app.launch()
        XCTAssertTrue(
            app.buttons["card.continue.tt0111161"].waitForExistence(timeout: 45),
            "a synced title with no cached artwork should reach Continue Watching"
        )
    }
}
