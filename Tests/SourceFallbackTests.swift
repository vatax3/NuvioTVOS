import XCTest
@testable import Nuvio

/// Upstream's `SourceFallbackTest` cases, against `SourceFallback`.
final class SourceFallbackTests: XCTestCase {
    private func torrent(_ addon: String, hash: String, file: Int? = nil, title: String = "x") -> Nuvio.Stream {
        var stream = Nuvio.Stream(title: title, addonName: addon)
        stream.infoHash = hash
        stream.fileIdx = file
        return stream
    }

    private func direct(_ addon: String, url: String) -> Nuvio.Stream {
        var stream = Nuvio.Stream(title: url, addonName: addon)
        stream.url = url
        return stream
    }

    func testOnlyAnAutoSelectedChainWithTheEngineSwitchOffFallsBack() {
        XCTAssertTrue(SourceFallback.isActive(enabled: true, mode: .first, engineSwitchOnError: false))
        XCTAssertFalse(SourceFallback.isActive(enabled: false, mode: .first, engineSwitchOnError: false))
        XCTAssertFalse(SourceFallback.isActive(enabled: true, mode: .off, engineSwitchOnError: false))
        XCTAssertFalse(SourceFallback.isActive(enabled: true, mode: .first, engineSwitchOnError: true))
    }

    func testATorrentIsKnownByAddonHashAndFile() {
        XCTAssertEqual(SourceFallback.key(for: torrent("Torrentio", hash: "ABC", file: 2)), "torrent:Torrentio:abc:2")
        XCTAssertEqual(SourceFallback.key(for: torrent("Torrentio", hash: "abc")), "torrent:Torrentio:abc:-1")
    }

    func testADirectLinkIsKnownByItsURL() {
        XCTAssertEqual(SourceFallback.key(for: direct("Addon", url: "https://a/b.mkv")), "url:https://a/b.mkv")
    }

    func testSourcesAlreadyTriedAreLeftOut() {
        let tried = torrent("Torrentio", hash: "aaa")
        let other = torrent("Comet", hash: "bbb")
        let next = SourceFallback.nextCandidate(
            from: [tried, other],
            triedKeys: [SourceFallback.key(for: tried)],
            failedAddonName: nil,
            failedInfoHash: nil,
            select: { $0.first }
        )
        XCTAssertEqual(next.map(SourceFallback.key(for:)), SourceFallback.key(for: other))
    }

    func testOtherCopiesOfTheFailedTorrentFromTheSameAddonAreLeftOut() {
        let sameFile = torrent("Torrentio", hash: "AAA", file: 3)
        let otherAddon = torrent("Comet", hash: "aaa")
        let next = SourceFallback.nextCandidate(
            from: [sameFile, otherAddon],
            triedKeys: [],
            failedAddonName: "Torrentio",
            failedInfoHash: "aaa",
            select: { $0.first }
        )
        XCTAssertEqual(next?.addonName, "Comet")
    }

    func testNothingLeftToTryIsNil() {
        let only = torrent("Torrentio", hash: "aaa")
        XCTAssertNil(SourceFallback.nextCandidate(
            from: [only], triedKeys: [SourceFallback.key(for: only)],
            failedAddonName: nil, failedInfoHash: nil, select: { $0.first }
        ))
    }
}
