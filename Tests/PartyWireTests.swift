import XCTest
@testable import Nuvio

/// What goes on the wire, pinned against the official app's own field names.
///
/// 1.0.49 proved the cost of getting this wrong: the arithmetic was exact, the Phoenix framing
/// was exact, and three payload envelopes were not — so a host's shared link decoded to nothing
/// on the client and the feature looked unimplemented. A shape is a contract with somebody
/// else's software, and the only honest way to hold it is a literal.
final class PartyWireTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPresenceUsesTheBackendsFieldNames() throws {
        let encoded = try object(PartyPresence(
            memberId: "m1", status: .buffering, mediaKey: "series|tt1|1|2", behindMs: 5000
        ))
        XCTAssertEqual(encoded["member_id"] as? String, "m1")
        XCTAssertEqual(encoded["status"] as? String, "buffering")
        XCTAssertEqual(encoded["media_key"] as? String, "series|tt1|1|2")
        XCTAssertEqual(encoded["behind_ms"] as? Int, 5000)
    }

    /// The status values are an enum on both sides; a renamed case would be dropped silently.
    func testEveryStatusSurvivesARoundTrip() throws {
        for status in [PartyMemberStatus.browsing, .loading, .buffering, .ready, .behind] {
            let data = try encoder.encode(PartyPresence(memberId: "m", status: status))
            let back = try decoder.decode(PartyPresence.self, from: data)
            XCTAssertEqual(back.status, status)
        }
    }

    func testPlaybackUsesTheBackendsFieldNames() throws {
        let encoded = try object(PartyPlayback(
            seq: 4, memberId: "m1", paused: true, positionMs: 1234,
            rate: 1.25, at: 99, mediaKey: "movie|tt2||", waiting: true
        ))
        XCTAssertEqual(encoded["position_ms"] as? Int, 1234)
        XCTAssertEqual(encoded["member_id"] as? String, "m1")
        XCTAssertEqual(encoded["media_key"] as? String, "movie|tt2||")
        XCTAssertEqual(encoded["waiting"] as? Bool, true)
        XCTAssertEqual(encoded["seq"] as? Int, 4)
    }

    func testStreamUsesTheBackendsFieldNames() throws {
        let encoded = try object(PartyStream(
            mediaKey: "movie|tt2||", url: "https://host/file.mkv",
            addonName: "Torrentio", filename: "File.mkv"
        ))
        XCTAssertEqual(encoded["media_key"] as? String, "movie|tt2||")
        XCTAssertEqual(encoded["addon_name"] as? String, "Torrentio")
        XCTAssertEqual(encoded["filename"] as? String, "File.mkv")
    }

    /// The media key is how every device decides whether a command is about what it is playing.
    /// Its exact spelling is shared with the other app.
    func testTheMediaKeyIsTypeIdSeasonEpisode() {
        XCTAssertEqual(
            PartyMedia.key(type: "Series", id: "tt1", season: 1, episode: 2), "series|tt1|1|2"
        )
        XCTAssertEqual(PartyMedia.key(type: "movie", id: "tt2", season: nil, episode: nil),
                       "movie|tt2||")
    }

    /// A loopback URL is the host's own machine and reaches nobody.
    func testOnlyAReachableURLIsShared() {
        XCTAssertTrue(PartyStream.isShareable("https://cdn.example/file.mkv"))
        XCTAssertFalse(PartyStream.isShareable("http://127.0.0.1:8080/file.mkv"))
        XCTAssertFalse(PartyStream.isShareable("http://localhost/file.mkv"))
    }
}

/// The shared clock, which decides what "now" means for every position in a party.
final class PartyClockTests: XCTestCase {

    func testAnUnsyncedClockFallsBackToTheLocalOne() {
        let clock = PartyClock()
        XCTAssertFalse(clock.isSynced)
        XCTAssertEqual(clock.nowMs(localNowMs: 42), 42)
    }

    /// **The defect this type exists for.** The server's answer describes a moment that has
    /// already passed, so half the round trip is added back. Without it every device in the
    /// party sits outside the 250 ms nudge threshold and rate-nudges against nothing.
    func testHalfTheRoundTripIsAddedBack() {
        var clock = PartyClock()
        let sentAt = clock.mark()
        let landed = sentAt.advanced(by: .milliseconds(200))
        clock.addSample(serverMs: 1_000, sentAt: sentAt, receivedAt: landed)
        XCTAssertEqual(clock.roundTripMs, 200)
        // 1000 + 200/2, read at the instant the sample landed.
        XCTAssertEqual(clock.nowMs(at: landed), 1_100)
        // And it keeps running from there.
        XCTAssertEqual(clock.nowMs(at: landed.advanced(by: .seconds(5))), 6_100)
    }

    /// A slow sample carries all the asymmetry, so the best one is kept rather than the latest.
    func testOnlyABetterSampleReplacesTheAnchor() {
        var clock = PartyClock()
        let first = clock.mark()
        let landed = first.advanced(by: .milliseconds(40))
        clock.addSample(serverMs: 1_000, sentAt: first, receivedAt: landed)
        clock.addSample(serverMs: 9_999, sentAt: first, receivedAt: first.advanced(by: .milliseconds(400)))
        XCTAssertEqual(clock.roundTripMs, 40)
        XCTAssertEqual(clock.nowMs(at: landed), 1_020)
    }

    func testResetForgetsEverything() {
        var clock = PartyClock()
        let mark = clock.mark()
        clock.addSample(serverMs: 1_000, sentAt: mark, receivedAt: mark)
        clock.reset()
        XCTAssertFalse(clock.isSynced)
        XCTAssertNil(clock.roundTripMs)
    }
}

/// Who the party waits for while they buffer.
final class PartyWaitingTests: XCTestCase {

    private func party(presence: [PartyPresence], mediaKey: String = "movie|tt1||") -> ActiveParty {
        ActiveParty(
            id: "p", code: "ABC123", memberId: "me", hostMemberId: "me",
            members: presence.map { PartyMember(id: $0.memberId, displayName: $0.memberId) },
            presence: Dictionary(uniqueKeysWithValues: presence.map { ($0.memberId, $0) }),
            media: PartyMedia(type: "movie", metaId: "tt1", metaType: "movie")
        )
    }

    func testOnlyLoadingAndBufferingMembersAreWaitedFor() {
        let waiting = PartySync.waitingMemberIds(
            in: party(presence: [
                PartyPresence(memberId: "a", status: .ready, mediaKey: "movie|tt1||"),
                PartyPresence(memberId: "b", status: .buffering, mediaKey: "movie|tt1||"),
                PartyPresence(memberId: "c", status: .loading, mediaKey: "movie|tt1||"),
                PartyPresence(memberId: "d", status: .behind, mediaKey: "movie|tt1||")
            ]),
            ignoring: []
        )
        XCTAssertEqual(Set(waiting), ["b", "c"])
    }

    /// Somebody watching the next episode is not holding this one up.
    func testAMemberOnAnotherTitleIsNotWaitedFor() {
        let waiting = PartySync.waitingMemberIds(
            in: party(presence: [
                PartyPresence(memberId: "a", status: .buffering, mediaKey: "series|tt9|1|2")
            ]),
            ignoring: []
        )
        XCTAssertTrue(waiting.isEmpty)
    }

    /// One slow connection must not hold four people still indefinitely.
    func testAMemberWaitedOutOnceIsNotWaitedForAgain() {
        let waiting = PartySync.waitingMemberIds(
            in: party(presence: [
                PartyPresence(memberId: "a", status: .buffering, mediaKey: "movie|tt1||")
            ]),
            ignoring: ["a"]
        )
        XCTAssertTrue(waiting.isEmpty)
    }
}
