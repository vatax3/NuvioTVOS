import XCTest
@testable import Nuvio

/// Streams that carry only a YouTube id (upstream 8e2bef36, in 1.1.0's notes, missed by our
/// beta.2 pass). Cases follow their `StreamYouTubeTest`: only a stream with nothing else counts.
final class YouTubeOnlyStreamTests: XCTestCase {
    func testAStreamWithOnlyAYouTubeIdIsOne() {
        XCTAssertEqual(Nuvio.Stream(ytId: "dQw4w9WgXcQ", addonName: "Newsio").youTubeOnlyId, "dQw4w9WgXcQ")
    }

    func testAWatchURLInTheIdIsReducedToTheId() {
        XCTAssertEqual(
            Nuvio.Stream(ytId: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", addonName: "A").youTubeOnlyId,
            "dQw4w9WgXcQ"
        )
    }

    func testAStreamWithAURLIsPlayedAsItsURL() {
        XCTAssertNil(Nuvio.Stream(url: "https://cdn/x.m3u8", ytId: "dQw4w9WgXcQ", addonName: "A").youTubeOnlyId)
    }

    func testATorrentIsNotOne() {
        XCTAssertNil(Nuvio.Stream(ytId: "dQw4w9WgXcQ", infoHash: "abc", addonName: "A").youTubeOnlyId)
    }

    func testABlankIdIsNotOne() {
        XCTAssertNil(Nuvio.Stream(ytId: "  ", addonName: "A").youTubeOnlyId)
    }
}
