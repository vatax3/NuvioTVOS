import XCTest
@testable import Nuvio

final class PlaybackSourceIdentityTests: XCTestCase {
    func testStableKeyDistinguishesSameNamedStreamsFromOneAddon() {
        let first = stream(url: "https://example.test/first", name: "[TB] Release 1080p")
        let second = stream(url: "https://example.test/second", name: "[TB] Release 1080p")
        let playback = request(sourceStableKey: second.stableKey)

        XCTAssertFalse(PlaybackSourceIdentity.matches(first, playback: playback))
        XCTAssertTrue(PlaybackSourceIdentity.matches(second, playback: playback))
    }

    func testLegacyPlaybackFallsBackToVisibleNameAndAddon() {
        let matching = stream(url: "https://example.test/matching", name: "Release")
        let otherAddon = Nuvio.Stream(
            name: "Release", title: nil, description: nil, url: "https://example.test/other",
            ytId: nil, infoHash: nil, fileIdx: nil, externalUrl: nil, behaviorHints: nil,
            addonName: "Other addon", addonLogo: nil, sources: nil, quality: nil
        )
        let legacy = request(sourceStableKey: nil)

        XCTAssertTrue(PlaybackSourceIdentity.matches(matching, playback: legacy))
        XCTAssertFalse(PlaybackSourceIdentity.matches(otherAddon, playback: legacy))
    }

    private func stream(url: String, name: String) -> Nuvio.Stream {
        Nuvio.Stream(
            name: name, title: nil, description: nil, url: url, ytId: nil, infoHash: nil,
            fileIdx: nil, externalUrl: nil, behaviorHints: nil, addonName: "Torrentio",
            addonLogo: nil, sources: nil, quality: nil
        )
    }

    private func request(sourceStableKey: String?) -> PlaybackRequest {
        PlaybackRequest(
            streamURL: "https://example.test/current", title: "Title", subtitleLine: nil,
            streamName: "Release", filename: nil, headers: [:], contentId: "tt123",
            contentType: "movie", videoId: "tt123", season: nil, episode: nil, poster: nil,
            backdrop: nil, logo: nil, startFromBeginning: false, preview: nil, nextUp: nil,
            imdbId: "tt123", sourceAddonName: "Torrentio", sourceStableKey: sourceStableKey
        )
    }
}
