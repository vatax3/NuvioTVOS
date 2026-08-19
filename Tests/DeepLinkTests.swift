import XCTest
@testable import Nuvio

final class DeepLinkTests: XCTestCase {
    func testTabDeepLinkSelectsRequestedTab() {
        XCTAssertEqual(DeepLink.parse(URL(string: "nuvio://library")!), .tab(.library))
        XCTAssertNil(DeepLink.parse(URL(string: "https://nuvio://library")!))
    }

    func testDetailDeepLinkPreservesIdentityAndMetadata() {
        let link = URL(string: "nuvio://detail/series/tt123?addon=https%3A%2F%2Fcatalog.example&backdrop=https%3A%2F%2Fimage.example")!
        guard case .detail(let request) = DeepLink.parse(link) else {
            return XCTFail("Expected a detail request")
        }
        XCTAssertEqual(request.itemId, "tt123")
        XCTAssertEqual(request.itemType, "series")
        XCTAssertEqual(request.addonBaseUrl, "https://catalog.example")
    }

    func testPlayDeepLinkReturnsToNormalStreamResolution() {
        let link = URL(string: "nuvio://play/movie/tt456?title=The%20Movie&video=tt456&imdb=tt456")!
        guard case .streams(let request) = DeepLink.parse(link) else {
            return XCTFail("Expected a stream request")
        }
        XCTAssertEqual(request.contentType, "movie")
        XCTAssertEqual(request.contentId, "tt456")
        XCTAssertEqual(request.videoId, "tt456")
        XCTAssertEqual(request.title, "The Movie")
        XCTAssertEqual(request.imdbId, "tt456")
    }
}
