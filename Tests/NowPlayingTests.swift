import MediaPlayer
import XCTest
@testable import Nuvio

/// The Now Playing card's contents and the commands behind it (upstream's player MediaSession).
final class NowPlayingTests: XCTestCase {
    func testSeriesIdentityCarriesTheShowAndTheEpisodeLine() {
        let info = NowPlayingPublisher.identity(title: "The Bear", subtitleLine: "S02E06 · Fishes", isLive: false)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "The Bear")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "S02E06 · Fishes")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyMediaType] as? UInt, MPNowPlayingInfoMediaType.video.rawValue)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, false)
    }

    func testFilmWithoutALineHasNoArtist() {
        let info = NowPlayingPublisher.identity(title: "Dune", subtitleLine: "  ", isLive: false)
        XCTAssertNil(info[MPMediaItemPropertyArtist])
    }

    /// Upstream keeps stream URLs out of the session; nothing here can carry one.
    func testNoURLOrIdentifierIsPublished() {
        let info = NowPlayingPublisher.identity(title: "Dune", subtitleLine: nil, isLive: true)
        XCTAssertEqual(Set(info.keys), [MPMediaItemPropertyTitle, MPNowPlayingInfoPropertyMediaType, MPNowPlayingInfoPropertyIsLiveStream])
        XCTAssertNil(info[MPNowPlayingInfoPropertyAssetURL])
        XCTAssertNil(info[MPNowPlayingInfoPropertyExternalContentIdentifier])
    }

    func testLiveStreamsOfferNoSeeking() {
        XCTAssertEqual(
            NowPlayingPublisher.Commands.policy(isLive: true, hasNextEpisode: true),
            .init(playPause: true, seek: false, nextEpisode: true)
        )
    }

    func testNextEpisodeOnlyWhenThereIsOne() {
        XCTAssertEqual(
            NowPlayingPublisher.Commands.policy(isLive: false, hasNextEpisode: false),
            .init(playPause: true, seek: true, nextEpisode: false)
        )
    }
}
