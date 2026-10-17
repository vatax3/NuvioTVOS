import XCTest

/// Does a held Select on an episode row in the player actually open anything?
///
/// It is the third time this codebase has had to ask that question with a real remote, and the
/// reason is always the same: whether tvOS routes a held Select to a gesture recogniser or lets
/// the focused `Button` swallow it exists only at runtime. `EpisodeOptionsPolicyTests` covers what
/// the dialog offers and presses nothing; the poster dialog was unreachable for thirteen releases
/// and every stepper in the app was inert for five, both with green policy tests the whole time.
///
/// The season chips are here for the same reason — selecting on focus is a focus-engine behaviour
/// — and because upstream's own bug in this panel was that loading a season dragged focus out of
/// the chip row and into the list.
final class InPlayerEpisodesUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Comfortably past the system's long-press threshold without a missed press looking slow.
    private let holdDuration: TimeInterval = 1.5

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-nuvioPlayerHarness"]
        app.launchEnvironment["NUVIO_HARNESS_EPISODES"] = "1"
        app.launch()
    }

    private func episode(_ season: Int, _ number: Int) -> XCUIElement {
        app.buttons["player.episode.harness:\(season):\(number)"]
    }

    @discardableResult
    private func wait(for condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return false
    }

    /// Waits for the Episodes panel, which the harness opens with playback.
    ///
    /// It is staged rather than navigated to on purpose. The subject here is the held Select on a
    /// row; walking the transport to the Episodes control is incidental, and it is also the
    /// fragile part — `hasFocus` on those buttons is an unreliable witness (see
    /// `PlayerRemoteUITests`) and a counted walk races the transport's own five-second auto-hide.
    /// `PlayerRemoteUITests` is where the walk itself is covered.
    private func awaitEpisodesPanel(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            wait(for: { self.episode(1, 1).exists }, timeout: 45),
            "the Episodes panel should list the staged season", file: file, line: line
        )
    }

    // MARK: The hold

    func testHoldingSelectOnAnEpisodeOpensItsOptions() {
        awaitEpisodesPanel()

        let row = episode(1, 1)
        XCTAssertTrue(wait(for: { row.hasFocus }), "the playing episode should claim focus")

        XCUIRemote.shared.press(.select, forDuration: holdDuration)

        XCTAssertTrue(
            wait(for: { self.app.buttons["episodeOptions.markWatched"].exists
                || self.app.buttons["episodeOptions.markUnwatched"].exists }),
            "holding Select on an episode row should open the episode options"
        )
    }

    /// **The regression.** The hold must not also arrive as an ordinary press — if it does, the
    /// dialog opens on top of a source list the viewer never asked for, or over new playback.
    /// This is the assertion the poster-dialog fix turned out to need most.
    func testTheHoldIsNotAlsoDeliveredAsAnOrdinaryPress() {
        awaitEpisodesPanel()

        let row = episode(1, 1)
        XCTAssertTrue(wait(for: { row.hasFocus }))

        XCUIRemote.shared.press(.select, forDuration: holdDuration)
        XCTAssertTrue(wait(for: { self.app.buttons["episodeOptions.play"].exists }))

        XCTAssertTrue(
            row.exists,
            "the episode list should still be underneath, not replaced by a source list"
        )
    }

    // MARK: The season chips

    /// Focusing a chip loads its season, which is upstream's behaviour and costs nothing here —
    /// every season is already in the metadata the panel loaded.
    func testMovingOntoASeasonChipSwitchesSeason() {
        awaitEpisodesPanel()
        XCTAssertTrue(wait(for: { self.episode(1, 1).hasFocus }))

        // Up out of the list reaches the chip row; Right crosses to the second season.
        XCUIRemote.shared.press(.up)
        usleep(600_000)
        XCUIRemote.shared.press(.right)

        XCTAssertTrue(
            wait(for: { self.episode(2, 1).exists }),
            "focusing the second season's chip should list that season"
        )
        XCTAssertFalse(
            episode(1, 1).exists,
            "and should stop listing the first"
        )
    }

    /// Upstream's own defect in this panel: loading a season re-runs the effect that claims focus
    /// for the list, which pulls the remote out of the chip row while the viewer is still browsing
    /// it. Ours claims focus the same way, so it has to be checked the same way.
    func testBrowsingTheChipsDoesNotDragFocusIntoTheList() {
        awaitEpisodesPanel()
        XCTAssertTrue(wait(for: { self.episode(1, 1).hasFocus }))

        XCUIRemote.shared.press(.up)
        usleep(600_000)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(wait(for: { self.episode(2, 1).exists }))

        // Give the newly-listed season's rows the moment they would need to steal focus.
        usleep(800_000)
        XCTAssertFalse(
            episode(2, 1).hasFocus,
            "focus should still be on the chip row, not yanked down into the episodes"
        )
    }
}
