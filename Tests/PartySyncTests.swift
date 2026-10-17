import XCTest
@testable import Nuvio

/// The arithmetic that keeps two televisions on the same frame.
///
/// Pinned rather than read, because every one of these rules is a judgement about what a viewer
/// will notice: a seek is the only way to close a large gap and the worst way to close a small
/// one, and the boundary between those is the whole design. Ported from upstream's own tuning.
final class PartySyncTests: XCTestCase {
    private func playback(
        positionMs: Int64 = 0,
        at: Int64 = 1_000,
        paused: Bool = false,
        rate: Double = 1,
        seq: Int64 = 1,
        memberId: String = "a",
        mediaKey: String? = "series|tt1|1|1",
        waiting: Bool = false
    ) -> PartyPlayback {
        PartyPlayback(
            seq: seq, memberId: memberId, paused: paused, positionMs: positionMs,
            rate: rate, at: at, mediaKey: mediaKey, waiting: waiting
        )
    }

    // MARK: Where the party is now

    /// Position advances with the server clock, which is the point: a member who joins mid-film
    /// computes the same answer as one who has been there throughout.
    func testPositionAdvancesWithElapsedServerTime() {
        let state = playback(positionMs: 10_000, at: 1_000)

        XCTAssertEqual(
            PartySync.expectedPositionMs(state, nowMs: 6_000), 15_000,
            "five seconds of server time is five seconds of film"
        )
    }

    func testRateIsAppliedToElapsedTime() {
        let state = playback(positionMs: 0, at: 0, rate: 1.5)

        XCTAssertEqual(PartySync.expectedPositionMs(state, nowMs: 10_000), 15_000)
    }

    /// A paused party does not drift, however long ago it said so.
    func testAPausedPartyStaysWhereItWasPaused() {
        let state = playback(positionMs: 30_000, at: 1_000, paused: true)

        XCTAssertEqual(PartySync.expectedPositionMs(state, nowMs: 600_000), 30_000)
    }

    /// A clock that disagrees backwards must not produce a negative position, and a long-dormant
    /// party must not point past the end of the film.
    func testThePositionIsBounded() {
        let state = playback(positionMs: 5_000, at: 10_000)

        XCTAssertEqual(PartySync.expectedPositionMs(state, nowMs: 0), 5_000)
        XCTAssertEqual(
            PartySync.expectedPositionMs(state, nowMs: 10_000_000, durationMs: 60_000), 60_000
        )
    }

    // MARK: Correcting

    /// Small drift is absorbed by the rate, which nobody can see. This is the tier that makes
    /// the feature usable — correcting 300ms with a seek would stutter every few seconds.
    func testSmallDriftIsNudgedRatherThanSought() {
        let state = playback(rate: 1)

        guard case .nudge(let rate) = PartySync.correction(
            localPositionMs: 10_300, expectedPositionMs: 10_000,
            playback: state, isNudging: false
        ) else { return XCTFail("300ms should nudge") }

        XCTAssertLessThan(rate, 1, "ahead of the party means slowing down")
    }

    func testBeingBehindSpeedsUpRatherThanSlowingDown() {
        guard case .nudge(let rate) = PartySync.correction(
            localPositionMs: 9_700, expectedPositionMs: 10_000,
            playback: playback(), isNudging: false
        ) else { return XCTFail("300ms should nudge") }

        XCTAssertGreaterThan(rate, 1)
    }

    /// Past a second and a half, a nudge would take longer to converge than the gap is tolerable.
    func testLargeDriftIsSought() {
        XCTAssertEqual(
            PartySync.correction(
                localPositionMs: 0, expectedPositionMs: 5_000,
                playback: playback(), isNudging: false
            ),
            .seek(positionMs: 5_000)
        )
    }

    /// Hysteresis, and it is what stops the rate being switched on and off every tick: nudging
    /// starts at 250ms and continues until 80ms, rather than both happening at one threshold.
    func testNudgingContinuesBelowTheThresholdThatStartedIt() {
        let drift: Int64 = 120

        XCTAssertEqual(
            PartySync.correction(
                localPositionMs: 10_000 + drift, expectedPositionMs: 10_000,
                playback: playback(), isNudging: false
            ),
            .inSync,
            "120ms is not enough to start correcting"
        )

        guard case .nudge = PartySync.correction(
            localPositionMs: 10_000 + drift, expectedPositionMs: 10_000,
            playback: playback(), isNudging: true
        ) else { return XCTFail("but a correction already running should continue") }
    }

    /// Paused, there is no rate to nudge — so the only tiers are "close enough" and "jump".
    func testAPausedPartyOnlySeeks() {
        let paused = playback(paused: true)

        XCTAssertEqual(
            PartySync.correction(
                localPositionMs: 10_300, expectedPositionMs: 10_000,
                playback: paused, isNudging: false
            ),
            .inSync,
            "300ms while paused is nobody's problem"
        )
        XCTAssertEqual(
            PartySync.correction(
                localPositionMs: 11_000, expectedPositionMs: 10_000,
                playback: paused, isNudging: false
            ),
            .seek(positionMs: 10_000)
        )
    }

    // MARK: Two people pressing at once

    func testAHigherSequenceWins() {
        XCTAssertTrue(
            PartySync.isNewer(playback(seq: 5), than: playback(seq: 4))
        )
        XCTAssertFalse(
            PartySync.isNewer(playback(seq: 3), than: playback(seq: 4))
        )
    }

    /// **The rule that stops a fight.** Two devices pressing pause in the same instant produce
    /// the same `seq`; without a deterministic tie-break each would pick a different winner and
    /// they would correct each other forever. The member id is arbitrary and that is fine — what
    /// matters is that every device computes the same arbitrary answer.
    func testATieIsBrokenTheSameWayOnEveryDevice() {
        let alex = playback(seq: 7, memberId: "alex")
        let sam = playback(seq: 7, memberId: "sam")

        XCTAssertTrue(PartySync.isNewer(sam, than: alex))
        XCTAssertFalse(PartySync.isNewer(alex, than: sam))
    }

    func testAnythingBeatsNothing() {
        XCTAssertTrue(PartySync.isNewer(playback(), than: nil))
    }

    // MARK: What the room is told

    func testPausingAndResumingAreAnnounced() {
        let playing = playback(paused: false)
        let paused = playback(paused: true, seq: 2)

        XCTAssertEqual(PartySync.action(from: playing, to: paused), .paused)
        XCTAssertEqual(PartySync.action(from: paused, to: playing), .resumed)
    }

    /// A jump is announced; the ordinary advance of time is not. The boundary is what makes the
    /// difference between an attributed seek and a line every two seconds.
    func testOnlyARealJumpCountsAsASeek() {
        let before = playback(positionMs: 10_000, at: 0)
        let drifted = playback(positionMs: 11_000, at: 1_000, seq: 2)
        let jumped = playback(positionMs: 60_000, at: 1_000, seq: 2)

        XCTAssertNil(
            PartySync.action(from: before, to: drifted),
            "a second of film in a second of time is not a seek"
        )
        XCTAssertEqual(PartySync.action(from: before, to: jumped), .seeked)
    }

    func testSpeedChangesAreAnnounced() {
        XCTAssertEqual(
            PartySync.action(from: playback(rate: 1), to: playback(rate: 1.5, seq: 2)), .speed
        )
    }

    /// Changing title announces itself, and buffering is machinery — neither earns a line.
    func testTitleChangesAndWaitingAreNotAnnounced() {
        let here = playback(mediaKey: "series|tt1|1|1")
        let next = playback(seq: 2, mediaKey: "series|tt1|1|2")

        XCTAssertNil(PartySync.action(from: here, to: next))
        XCTAssertNil(PartySync.action(from: here, to: playback(seq: 2, waiting: true)))
        XCTAssertNil(PartySync.action(from: nil, to: here))
    }

    // MARK: Who is in charge

    private func party(
        memberId: String, hostMemberId: String?, online: [String], hostOnly: Bool = false
    ) -> ActiveParty {
        ActiveParty(
            id: "p", code: "ABCD", memberId: memberId, hostMemberId: hostMemberId,
            members: ["alex", "sam", "jo"].map {
                PartyMember(id: $0, displayName: $0.capitalized)
            },
            presence: Dictionary(
                uniqueKeysWithValues: online.map { ($0, PartyPresence(memberId: $0)) }
            ),
            media: PartyMedia(type: "series", metaId: "tt1", metaType: "series"),
            hostOnly: hostOnly
        )
    }

    func testTheHostLeadsWhenPresent() {
        XCTAssertEqual(
            PartySync.coordinatorId(
                for: party(memberId: "sam", hostMemberId: "alex", online: ["alex", "sam"])
            ),
            "alex"
        )
    }

    /// A host who closed the app must not freeze the party on their last position.
    func testAnAbsentHostHandsOver() {
        XCTAssertEqual(
            PartySync.coordinatorId(
                for: party(memberId: "sam", hostMemberId: "alex", online: ["sam", "jo"])
            ),
            "sam"
        )
    }

    /// Unless the host asked to be the only one driving, in which case an absent host means
    /// nobody drives — which is what *host only* means.
    func testHostOnlyKeepsControlWithTheHostEvenWhenAway() {
        XCTAssertEqual(
            PartySync.coordinatorId(
                for: party(
                    memberId: "sam", hostMemberId: "alex", online: ["sam"], hostOnly: true
                )
            ),
            "alex"
        )
    }

    // MARK: Falling behind

    func testADeliberateJumpBackwardsLeavesTheParty() {
        XCTAssertEqual(
            PartySync.ownSeek(targetMs: 10_000, partyPositionMs: 60_000, isBehind: false),
            .behind(positionMs: 10_000)
        )
    }

    func testSeekingForwardWhileBehindRejoins() {
        XCTAssertEqual(
            PartySync.ownSeek(targetMs: 59_000, partyPositionMs: 60_000, isBehind: true),
            .catchUp
        )
    }

    func testASeekWithNothingToCorrectDoesNothing() {
        XCTAssertEqual(
            PartySync.ownSeek(targetMs: 59_500, partyPositionMs: 60_000, isBehind: false),
            .blocked
        )
    }

    /// The badge reports a rounded gap, and never zero: "behind by 0 seconds" is a state it
    /// should not be able to show.
    func testTheReportedGapIsRoundedAndNeverZero() {
        XCTAssertEqual(PartySync.reportedGapMs(0), 5_000)
        XCTAssertEqual(PartySync.reportedGapMs(1), 5_000)
        XCTAssertEqual(PartySync.reportedGapMs(7_600), 10_000)
        XCTAssertEqual(PartySync.reportedGapMs(12_000), 10_000)
    }

    func testOnlyASmallGapIsWaitedFor() {
        XCTAssertTrue(PartySync.shouldRejoin(gapMs: 1_000, isPlaying: true))
        XCTAssertFalse(PartySync.shouldRejoin(gapMs: 30_000, isPlaying: true))
        XCTAssertFalse(
            PartySync.shouldRejoin(gapMs: 1_000, isPlaying: false),
            "a paused party is not waiting for anybody"
        )
    }
}
