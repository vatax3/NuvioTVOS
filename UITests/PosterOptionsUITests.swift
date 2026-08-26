import XCTest

/// Does a long press on a poster actually open anything?
///
/// `PosterOptionsPolicyTests` has covered what the dialog offers since 1.0.18 — twenty tests on
/// which rows appear for which title. None of them presses a button. The gesture sits on a
/// focused `Button`, and whether tvOS routes a held Select to a gesture recogniser or lets the
/// button swallow it is a runtime question about the focus engine, exactly like the player's
/// transport. So it is asked here, with a real remote, the same way.
///
/// Two screens because they are two different cards with two different gestures: the Continue
/// Watching rail on Home, and the poster grid in Library.
final class PosterOptionsUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Comfortably past the system's own long-press threshold without being so long that a
    /// missed press looks like a slow one.
    private let holdDuration: TimeInterval = 1.5

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(tab: String) {
        app = XCUIApplication()
        app.launchArguments = ["-nuvioUITesting", "-nuvioLibraryHarness", "-startTab", tab]
        app.launch()
    }

    /// The dialog's own container identifier is not what is asserted on: a SwiftUI `ZStack`
    /// does not reliably surface as an accessibility element. Every action list ends with
    /// "Go to details", so that row is the dialog's presence.
    private var dialog: XCUIElement { app.buttons["posterOptions.openDetails"] }

    @discardableResult
    private func wait(for element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    /// Moves focus onto the card, then holds Select on it.
    ///
    /// Focus is not assumed: Home claims its own initial focus and the sidebar may hold it at
    /// launch, so the test presses Right until the card answers rather than pressing blind.
    private func longPress(
        _ card: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(wait(for: card), "the harness card should be on screen", file: file, line: line)

        // Focus is not assumed and not pressed for blindly: the sidebar can hold it at launch,
        // and Home and Library reach their first card by different routes.
        for button in [XCUIRemote.Button.right, .down, .right, .down, .right, .right, .down, .right] {
            if card.hasFocus { break }
            XCUIRemote.shared.press(button)
            usleep(500_000)
        }
        XCTAssertTrue(card.hasFocus, "the card should be focusable", file: file, line: line)

        XCUIRemote.shared.press(.select, forDuration: holdDuration)
    }

    /// The rail the dialog was built for: a resume point can be created from anywhere and,
    /// without this gesture, removed from nowhere.
    func testALongPressInContinueWatchingOffersRemovingTheResumePoint() {
        launch(tab: "home")
        longPress(app.buttons["card.continue.harness-resume"])

        XCTAssertTrue(
            wait(for: dialog, timeout: 10),
            "holding Select on a Continue Watching card should open the poster options"
        )
        XCTAssertTrue(
            app.buttons["posterOptions.removeFromContinueWatching"].exists,
            "a started title should be removable from the rail"
        )
    }

    /// The library grid, where the same gesture has to offer removal from the library instead.
    func testALongPressInTheLibraryOffersRemovingTheTitle() {
        launch(tab: "library")
        longPress(app.buttons["card.poster.harness-saved"])

        XCTAssertTrue(
            wait(for: dialog, timeout: 10),
            "holding Select on a library poster should open the poster options"
        )
        XCTAssertTrue(
            app.buttons["posterOptions.removeFromLibrary"].exists,
            "a saved title should offer removal from the library"
        )
    }

    /// A long press must not also count as a normal press. If it does, the dialog opens over a
    /// detail screen the viewer never asked for — or worse, over playback.
    func testALongPressDoesNotAlsoOpenTheTitle() {
        launch(tab: "library")
        longPress(app.buttons["card.poster.harness-saved"])

        XCTAssertTrue(wait(for: dialog, timeout: 10))
        XCTAssertTrue(
            app.buttons["card.poster.harness-saved"].exists,
            "the grid should still be underneath, not replaced by a detail screen"
        )
    }
}
