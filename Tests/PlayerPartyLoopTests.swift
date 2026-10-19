import XCTest
@testable import Nuvio

/// The one rule in the player's party loop that can be decided on paper: what a pause made *on
/// this device* means.
///
/// It is here because getting it wrong is what made a party asymmetric — the Mac could pause the
/// Apple TV and the Apple TV could not pause the Mac — and because the rest of the loop is a
/// timer and a focus graph, which no unit test can see.
@MainActor
final class PlayerPartyLoopTests: XCTestCase {

    private func store(hostOnly: Bool, isHost: Bool) -> PartyStore {
        let store = PartyStore()
        store.stageForTesting(
            ActiveParty(
                id: "p", code: "ABC123",
                memberId: "me",
                hostMemberId: isHost ? "me" : "them",
                members: [PartyMember(id: "me", displayName: "Val")],
                presence: [:],
                media: PartyMedia(type: "movie", metaId: "tt1", metaType: "movie"),
                maxMembers: 8,
                isConnected: true,
                hostOnly: hostOnly
            )
        )
        return store
    }

    private func input(paused: Bool) -> PlayerPartyLoop.Input {
        PlayerPartyLoop.Input(
            positionMs: 61_000, durationMs: 7_200_000, isPaused: paused, isLoading: false,
            hasRendered: true, mediaKey: "movie|tt1||", viewerRate: 1
        )
    }

    /// **The asymmetry.** A pause here has to be announced at once rather than discovered by the
    /// loop's mismatch delay, which only exists to absorb a disagreement arriving from elsewhere.
    func testAViewersOwnPauseIsPublishedAtOnce() {
        let loop = PlayerPartyLoop()
        let instructions = loop.localPlaybackToggled(
            input(paused: true), store: store(hostOnly: false, isHost: true)
        )
        XCTAssertEqual(
            instructions, [.publish(positionMs: 61_000, paused: true, rate: 1)]
        )
    }

    func testResumingIsPublishedTheSameWay() {
        let loop = PlayerPartyLoop()
        let instructions = loop.localPlaybackToggled(
            input(paused: false), store: store(hostOnly: false, isHost: true)
        )
        XCTAssertEqual(
            instructions, [.publish(positionMs: 61_000, paused: false, rate: 1)]
        )
    }

    /// A guest under *host only* says nothing — what their pause means is the loop's business a
    /// moment later, and it is never "move everybody".
    func testAGuestUnderHostOnlySaysNothing() {
        let loop = PlayerPartyLoop()
        XCTAssertTrue(loop.localPlaybackToggled(
            input(paused: true), store: store(hostOnly: true, isHost: false)
        ).isEmpty)
    }

    /// The host is never restricted by their own setting.
    func testTheHostStillPublishesUnderHostOnly() {
        let loop = PlayerPartyLoop()
        XCTAssertFalse(loop.localPlaybackToggled(
            input(paused: true), store: store(hostOnly: true, isHost: true)
        ).isEmpty)
    }

    /// Watching something else entirely is not a command about what the party is watching.
    func testAPauseOnAnotherTitleIsNotPublished() {
        let loop = PlayerPartyLoop()
        var other = input(paused: true)
        other.mediaKey = "series|tt9|1|2"
        XCTAssertTrue(
            loop.localPlaybackToggled(other, store: store(hostOnly: false, isHost: true)).isEmpty
        )
    }

    func testNoPartyMeansNothingToSay() {
        let loop = PlayerPartyLoop()
        XCTAssertTrue(loop.localPlaybackToggled(input(paused: true), store: PartyStore()).isEmpty)
    }
}
