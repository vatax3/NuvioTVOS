import XCTest
@testable import Nuvio

/// Upstream's `PlaybackUrlCredentialsTest` and `CachedSourceRefreshCandidateTest` cases.
final class ExpiredLinkRefreshTests: XCTestCase {
    func testSignedAndExpiringQueriesAreRecognised() {
        XCTAssertTrue(ExpiredLinkRefresh.hasLikelyExpiringCredentials("https://cdn/x.mkv?token=abc"))
        XCTAssertTrue(ExpiredLinkRefresh.hasLikelyExpiringCredentials("https://cdn/x.mkv?a=1&Expires=99"))
        XCTAssertTrue(ExpiredLinkRefresh.hasLikelyExpiringCredentials("https://cdn/x.mkv?X-Amz-Signature=f"))
        XCTAssertTrue(ExpiredLinkRefresh.hasLikelyExpiringCredentials("https://cdn/x.mkv?Key-Pair-Id=k"))
    }

    func testPlainLinksAreNot() {
        XCTAssertFalse(ExpiredLinkRefresh.hasLikelyExpiringCredentials("https://cdn/x.mkv"))
        XCTAssertFalse(ExpiredLinkRefresh.hasLikelyExpiringCredentials("https://cdn/x.mkv?quality=1080"))
        XCTAssertFalse(ExpiredLinkRefresh.hasLikelyExpiringCredentials("https://cdn/x.mkv#token=abc"))
    }

    private func stream(_ addon: String, url: String? = nil, hash: String? = nil, name: String? = nil) -> Nuvio.Stream {
        var stream = Nuvio.Stream(title: "x", addonName: addon)
        stream.url = url
        stream.infoHash = hash
        stream.name = name
        return stream
    }

    func testOnlyTheSameAddonIsAskedAgain() {
        let candidate = ExpiredLinkRefresh.candidate(
            in: [stream("Other", url: "https://new")],
            failedURL: "https://old",
            expected: .init(addonName: "Mine")
        )
        XCTAssertNil(candidate)
    }

    func testTheFailedLinkItselfIsNotACandidate() {
        let candidate = ExpiredLinkRefresh.candidate(
            in: [stream("Mine", url: "https://old")],
            failedURL: "https://old",
            expected: .init(addonName: "Mine")
        )
        XCTAssertNil(candidate)
    }

    func testTheSameTorrentWinsOverAnotherFromTheAddon() {
        let other = stream("Mine", url: "https://a", name: "Other")
        let same = stream("Mine", hash: "ABC", name: "Same")
        let candidate = ExpiredLinkRefresh.candidate(
            in: [other, same],
            failedURL: "https://old",
            expected: .init(addonName: "Mine", infoHash: "abc")
        )
        XCTAssertEqual(candidate?.name, "Same")
    }
}
