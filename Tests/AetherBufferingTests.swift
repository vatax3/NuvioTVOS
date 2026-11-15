import XCTest
@testable import Nuvio

final class AetherBufferingTests: XCTestCase {
    func testReconnectingSourceOverAPlayingTransportIsNotBuffering() {
        XCTAssertFalse(AetherBufferingPolicy.showsBuffering(.sourceStalled, transportStarved: false))
    }

    func testReconnectingSourceWithAStarvedTransportIsBuffering() {
        XCTAssertTrue(AetherBufferingPolicy.showsBuffering(.sourceStalled, transportStarved: true))
    }

    func testLoadingAndRebufferingAlwaysShow() {
        for starved in [false, true] {
            XCTAssertTrue(AetherBufferingPolicy.showsBuffering(.loading, transportStarved: starved))
            XCTAssertTrue(AetherBufferingPolicy.showsBuffering(.rebuffering, transportStarved: starved))
        }
    }

    func testEveryOtherPhaseNeverShows() {
        XCTAssertFalse(AetherBufferingPolicy.showsBuffering(.other, transportStarved: true))
    }
}
