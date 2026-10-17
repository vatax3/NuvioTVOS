import XCTest
@testable import Nuvio

/// When the next episode's source list is warmed.
///
/// 1.0.45 fired at a flat two minutes from the end, and that reads as reasonable until you notice
/// the next-episode card has a threshold of its own that the viewer sets. *Minutes before end* can
/// be five or ten, so the card sat on screen for minutes with nothing warming behind it — which is
/// the one outcome the prefetch exists to prevent. Upstream reached the same fix in 1.1.0-beta.7.
@MainActor
final class NextEpisodePrefetchTests: XCTestCase {
    private func store(minutesBeforeEnd: Int) -> PlayerSettingsStore {
        let settings = AppSettings()
        settings.player.nextEpisodeThresholdMode = .minutesBeforeEnd
        settings.player.nextEpisodeThresholdMinutesBeforeEnd = minutesBeforeEnd
        return settings.player
    }

    private func store(percent: Int) -> PlayerSettingsStore {
        let settings = AppSettings()
        settings.player.nextEpisodeThresholdMode = .percent
        settings.player.nextEpisodeThresholdPercent = percent
        return settings.player
    }

    // MARK: The defect

    /// The case that was broken: a card set to appear ten minutes out, against a lead of two.
    func testTheWarmBeginsBeforeTheCardAppears() {
        let player = store(minutesBeforeEnd: 10)
        let duration: Double = 3_600
        let cardAppearsAt = duration - 10 * 60

        XCTAssertTrue(
            player.shouldPrefetchNextEpisode(
                position: cardAppearsAt - player.nextEpisodePrefetchLead, duration: duration
            ),
            "the warm must start one lead before the card, not two minutes before the end"
        )
        XCTAssertTrue(
            player.shouldAdvanceToNextEpisode(position: cardAppearsAt, duration: duration),
            "sanity: this is where the card actually appears"
        )
    }

    /// And it is early, not merely earlier — the lead has to be fully spent before the card shows.
    func testTheWarmIsALeadAheadOfTheCardAndNotAMomentBeforeIt() {
        let player = store(minutesBeforeEnd: 10)
        let duration: Double = 3_600
        let cardAppearsAt = duration - 10 * 60

        var earliest = duration
        for position in stride(from: 0, through: duration, by: 5) where
            player.shouldPrefetchNextEpisode(position: position, duration: duration) {
            earliest = min(earliest, position)
        }

        XCTAssertEqual(cardAppearsAt - earliest, player.nextEpisodePrefetchLead, accuracy: 5)
    }

    // MARK: The floor

    /// A percentage threshold can land *after* the flat lead — 99% of a short episode is seconds
    /// from the end — so the lead stays as a floor rather than being replaced by the card's rule.
    func testTheFlatLeadRemainsAFloorForALateThreshold() {
        let player = store(percent: 99)
        let duration: Double = 1_200

        XCTAssertTrue(
            player.shouldPrefetchNextEpisode(
                position: duration - player.nextEpisodePrefetchLead, duration: duration
            ),
            "two minutes out must warm even when the card will not appear for another ninety seconds"
        )
    }

    // MARK: What must not fire

    /// Nothing warms at the start of an episode. A prefetch there would spend a round of requests
    /// on an episode a viewer abandoning this one never reaches.
    func testNothingWarmsEarlyInPlayback() {
        for player in [store(minutesBeforeEnd: 10), store(percent: 90)] {
            XCTAssertFalse(player.shouldPrefetchNextEpisode(position: 60, duration: 3_600))
        }
    }

    /// A live stream or a file mpv has not sized yet reports no duration, and `duration - position`
    /// on a zero duration is how a prefetch fires on every tick from the first frame.
    func testAnUnknownDurationWarmsNothing() {
        let player = store(minutesBeforeEnd: 10)

        XCTAssertFalse(player.shouldPrefetchNextEpisode(position: 0, duration: 0))
        XCTAssertFalse(player.shouldPrefetchNextEpisode(position: 500, duration: 0))
    }

    /// An episode shorter than the lead must still warm rather than falling through every arm.
    func testAVeryShortEpisodeStillWarms() {
        let player = store(minutesBeforeEnd: 2)

        XCTAssertTrue(player.shouldPrefetchNextEpisode(position: 10, duration: 90))
    }
}
