import XCTest
@testable import Nuvio

final class ProfileAndStreamFilterTests: XCTestCase {
    func testProfileLockRepresentsLocalAndRemoteProtection() {
        let local = profile(pinHash: "hashed", remoteLock: false)
        let remote = profile(pinHash: nil, remoteLock: true)
        let open = profile(pinHash: nil, remoteLock: false)

        XCTAssertTrue(local.isLocked)
        XCTAssertTrue(remote.isLocked)
        XCTAssertFalse(open.isLocked)
    }

    func testFilterMinimumResolutionAndSortingAreDeterministic() {
        let hd = stream(name: "Release 720p AVC", url: "https://example.test/hd")
        let fullHD = stream(name: "Release 1080p HEVC", url: "https://example.test/fhd")
        let ultraHD = stream(name: "Release 2160p HEVC", url: "https://example.test/uhd")
        let streams = [hd, fullHD, ultraHD]
        let attributes = Dictionary(uniqueKeysWithValues: streams.map { ($0.stableKey, StreamAttributeParser.parse($0)) })
        let input = StreamFilterEngine.Input(
            minimumQuality: .p1080,
            dolbyVisionFilter: .any,
            hdrFilter: .any,
            codecFilter: .any,
            sortMode: .qualityDesc,
            maxResults: 0,
            preferences: DebridStreamPreferences()
        )

        XCTAssertEqual(
            StreamFilterEngine.apply(to: streams, attributes: attributes, input: input).map(\.stableKey),
            [ultraHD.stableKey, fullHD.stableKey]
        )
    }

    private func profile(pinHash: String?, remoteLock: Bool) -> Profile {
        Profile(
            id: UUID().uuidString, name: "Test", symbol: "person.fill", tintHex: "#1E88E5",
            pinHash: pinHash, isRestricted: false, createdAt: .now, hasRemoteLock: remoteLock
        )
    }

    private func stream(name: String, url: String) -> Nuvio.Stream {
        Nuvio.Stream(
            name: name, title: nil, description: nil, url: url, ytId: nil, infoHash: nil,
            fileIdx: nil, externalUrl: nil, behaviorHints: nil, addonName: "Test addon",
            addonLogo: nil, sources: nil, quality: nil
        )
    }
}
