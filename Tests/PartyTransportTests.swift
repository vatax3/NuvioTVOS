import XCTest
@testable import Nuvio

/// The two facts about a watch party that are decided before any syncing happens: where the
/// socket points, and which of this device's sources is the one the party is on.
///
/// Both were wrong in 1.0.48 and neither needed a television to catch.
final class PartyTransportTests: XCTestCase {

    // MARK: The socket URL

    /// **The bug that cost a release.** The backend's edge answers `410 Gone` to realtime traffic
    /// that does not carry `nuvio_realtime=1` — before the socket, with no error a client can
    /// read. Without it the handshake never completes, the join times out, and the party shows
    /// "Reconnecting…" over a correct roster forever.
    func testSocketURLCarriesTheRealtimeFlag() throws {
        let url = NuvioRealtime.socketURL(
            backendUrl: "https://api.nuvio.tv", key: "sb_publishable_test"
        )
        let query = URLComponents(
            url: try XCTUnwrap(url), resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(query?.first { $0.name == "nuvio_realtime" }?.value, "1")
        XCTAssertEqual(query?.first { $0.name == "apikey" }?.value, "sb_publishable_test")
        XCTAssertEqual(query?.first { $0.name == "vsn" }?.value, "1.0.0")
        XCTAssertEqual(url?.scheme, "wss")
        XCTAssertEqual(url?.path, "/realtime/v1/websocket")
    }

    func testSocketURLStaysUnencryptedForAnUnencryptedBackend() {
        let url = NuvioRealtime.socketURL(backendUrl: "http://192.168.1.4:8000/", key: "k")
        XCTAssertEqual(url?.scheme, "ws")
        XCTAssertEqual(url?.path, "/realtime/v1/websocket")
    }

    // MARK: Which source the party is on

    func testInfoHashIdentifiesTheRelease() {
        let source = PartySource(infoHash: "ABCDEF", filename: "something.else.mkv")
        XCTAssertTrue(source.matches(infoHash: "abcdef", fileIdx: nil, filename: nil))
        XCTAssertFalse(source.matches(infoHash: "123456", fileIdx: nil, filename: nil))
    }

    /// One torrent carries a season, so an index narrows a hash match — but only when both sides
    /// state one. Treating an absent index as a mismatch rejects the very file it describes.
    func testFileIndexNarrowsAMatchOnlyWhenBothSidesHaveOne() {
        let source = PartySource(infoHash: "abc", fileIdx: 2)
        XCTAssertTrue(source.matches(infoHash: "abc", fileIdx: 2, filename: nil))
        XCTAssertFalse(source.matches(infoHash: "abc", fileIdx: 3, filename: nil))
        XCTAssertTrue(source.matches(infoHash: "abc", fileIdx: nil, filename: nil))
    }

    func testFilenameIsTheFallbackAndIgnoresCase() {
        let source = PartySource(filename: "Show.S01E02.1080p.WEB.mkv")
        XCTAssertTrue(source.matches(
            infoHash: nil, fileIdx: nil, filename: "show.s01e02.1080p.web.mkv"
        ))
        XCTAssertFalse(source.matches(
            infoHash: nil, fileIdx: nil, filename: "Show.S01E03.1080p.WEB.mkv"
        ))
    }

    /// Describing nothing must match nothing. A source with neither hash nor filename would
    /// otherwise mark every row in the list as the party's.
    func testAnEmptyDescriptionMatchesNothing() {
        XCTAssertFalse(PartySource().matches(
            infoHash: nil, fileIdx: nil, filename: "anything.mkv"
        ))
        XCTAssertFalse(PartySource(filename: "  ").matches(
            infoHash: nil, fileIdx: nil, filename: "anything.mkv"
        ))
    }
}
