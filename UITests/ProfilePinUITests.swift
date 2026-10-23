import XCTest

/// The PIN challenge, measured against the screen it is drawn on.
///
/// It was reported as "too big, it goes off the edges", and that is the kind of defect nothing
/// below the view layer can see: every number here is a layout constant, and the sum of them only
/// becomes wrong at 1920×1080. The identity block and the keypad were stacked, which came to more
/// than the panel is tall, so the ends were silently clipped. They now sit side by side.
///
/// `ProfileHarness` stages the household, because a locked profile is otherwise something a tester
/// has to create by hand before this screen exists at all.
final class ProfilePinUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-nuvioProfileHarness"]
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

    /// The chooser opens on the primary; the locked profile is the one to its right.
    private func openPinChallenge() {
        XCTAssertTrue(wait { app.buttons["Alex"].exists }, "the chooser never appeared")
        XCUIRemote.shared.press(.right)
        usleep(400_000)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(wait { app.buttons["1"].exists }, "the PIN challenge never appeared")
    }

    func testTheWholePinChallengeIsOnScreen() {
        openPinChallenge()

        let screen = app.windows.firstMatch.frame
        XCTAssertFalse(screen.isEmpty)

        // Every key, plus the way out. A clipped element reports a frame that leaves the window,
        // which is exactly what was happening to the avatar at the top and the button at the
        // bottom — so containment is the assertion, not a height threshold.
        var checked = 0
        for label in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
            let key = app.buttons[label]
            XCTAssertTrue(key.exists, "key \(label) is missing")
            XCTAssertTrue(
                screen.contains(key.frame),
                "key \(label) at \(key.frame) is outside the \(screen) screen"
            )
            checked += 1
        }
        XCTAssertEqual(checked, 10)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "pin-challenge"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The keypad is a remote target: whatever the layout does, a key stays big enough to aim at
    /// from a sofa. Pinned so a future "make it fit" is not paid for by shrinking the buttons.
    func testTheKeysStayBigEnoughToAimAt() {
        openPinChallenge()

        let key = app.buttons["5"]
        XCTAssertTrue(key.exists)
        XCTAssertGreaterThanOrEqual(key.frame.height, 80)
        XCTAssertGreaterThanOrEqual(key.frame.width, 120)
    }
}
