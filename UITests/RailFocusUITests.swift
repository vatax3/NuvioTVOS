import XCTest

/// Vertical travel between Home rails, and Back on Home (#6).
///
/// Reported: moving up or down landed "randomly" in the next rail — tvOS picks whichever card is
/// geometrically nearest — and Back left the app from anywhere on the screen. A rail now returns
/// to the card it was left on (its first, if never visited), as Android's `focusRestorer` does.
/// Back goes to the start of the rail, then to the top, and only then leaves.
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

    func testBackGoesToTheRailStartThenTheTopThenLeaves() {
        reachFirstCatalogRail()
        press(.down)
        let railStartX = focusedCard.frame.minX
        press(.right, times: 3)
        let deepX = focusedCard.frame.minX
        let deepY = focusedCard.frame.midY

        press(.menu)
        XCTAssertEqual(app.state, .runningForeground, "Back inside a rail should stay in the app")
        XCTAssertTrue(focusedCard.identifier.hasPrefix("card.poster."), "Back should stay in the rail")
        XCTAssertEqual(focusedCard.frame.midY, deepY, accuracy: 40, "Back should stay in the rail")
        XCTAssertLessThan(focusedCard.frame.minX, deepX, "Back should go to the start of the rail")
        XCTAssertEqual(focusedCard.frame.minX, railStartX, accuracy: 40)

        press(.menu)
        XCTAssertEqual(app.state, .runningForeground, "Back below the top should stay in the app")
        XCTAssertTrue(
            app.buttons["card.continue.harness-resume"].hasFocus,
            "Back from the start of a rail should return to the first card of the first rail"
        )

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 10),
            "Back from the top should leave the app"
        )
    }
}

/// Reported after 1.0.64: focus "gets stuck" between Continue Watching and the rail under it
/// (#6). Both rails list the same title here, which is the ordinary case — a popular film
/// started and still in the catalogue.
final class SharedTitleRailFocusUITests: XCTestCase {
    private func focusedCard(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'card.' AND hasFocus == true")
        ).firstMatch
    }

    /// Focus over `duration`, sampled; a settled move shows one identifier.
    private func samples(_ app: XCUIApplication, over duration: TimeInterval = 2) -> [String] {
        var seen: [String] = []
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            let id = focusedCard(app).exists ? focusedCard(app).identifier : "-"
            if seen.last != id { seen.append(id) }
            usleep(150_000)
        }
        return seen
    }

    func testFocusSettlesBetweenRailsSharingATitle() {
        let probe = XCUIApplication()
        probe.launchArguments = ["-nuvioUITesting", "-startTab", "home", "-nuvioLibraryHarness"]
        probe.launch()
        XCTAssertTrue(probe.buttons["card.continue.harness-resume"].waitForExistence(timeout: 30))
        XCTAssertTrue(probe.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'card.poster.'")
        ).firstMatch.waitForExistence(timeout: 45), "the catalogs should load")
        sleep(2)
        var firstPoster: String?
        for _ in 0..<6 {
            XCUIRemote.shared.press(.down)
            usleep(900_000)
            let id = focusedCard(probe).identifier
            if id.hasPrefix("card.poster.") { firstPoster = id; break }
        }
        guard let firstPoster else { return XCTFail("no catalog poster below Continue Watching") }
        let shared = String(firstPoster.dropFirst("card.poster.".count))
        probe.terminate()

        let app = XCUIApplication()
        app.launchArguments = [
            "-nuvioUITesting", "-startTab", "home", "-nuvioLibraryHarness",
            "-nuvioHarnessResumeId", shared
        ]
        app.launch()
        let sharedCard = app.buttons["card.continue.\(shared)"].waitForExistence(timeout: 45)
        XCTAssertTrue(
            sharedCard,
            "the shared title should reach Continue Watching"
        )
        sleep(2)

        var log: [(press: String, seen: [String])] = []
        for step in 0..<4 {
            let press: XCUIRemote.Button = step.isMultiple(of: 2) ? .down : .up
            XCUIRemote.shared.press(press)
            log.append((step.isMultiple(of: 2) ? "down" : "up", samples(app)))
        }
        print("SHARED-TITLE FOCUS LOG\n" + log.map { "\($0.press): \($0.seen)" }.joined(separator: "\n"))
        for entry in log {
            // The card left, then the card reached: anything more is focus bouncing.
            XCTAssertLessThanOrEqual(
                entry.seen.count, 2, "\(entry.press) should settle on one card: \(entry.seen)"
            )
            if entry.press == "down" {
                XCTAssertTrue(
                    entry.seen.last?.hasPrefix("card.poster.") == true,
                    "down should end on the catalog: \(entry.seen)"
                )
            } else {
                XCTAssertTrue(
                    entry.seen.last?.hasPrefix("card.continue.") == true,
                    "up should end on Continue Watching: \(entry.seen)"
                )
            }
        }
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
