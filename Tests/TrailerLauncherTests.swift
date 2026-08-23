import XCTest
@testable import Nuvio

/// The YouTube hand-off. Reported: the trailer button opened the YouTube app and played nothing.
///
/// `canOpenURL` answers for the scheme alone and never looks at the rest of the URL, so a
/// malformed hand-off cannot be detected at runtime and there is nothing to fall back to. These
/// are the only check the form gets.
final class TrailerLauncherTests: XCTestCase {
    func testAnIdBecomesAWatchURL() {
        XCTAssertEqual(
            TrailerLauncher.handoffURL(youTubeId: "dQw4w9WgXcQ")?.absoluteString,
            "youtube://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
    }

    /// What it used to build. Kept as a test rather than a comment because the failure is silent:
    /// the app opens either way, and only the second one plays anything.
    func testTheIdIsNotLeftAsTheHost() {
        let url = try? XCTUnwrap(TrailerLauncher.handoffURL(youTubeId: "dQw4w9WgXcQ"))
        XCTAssertNotEqual(url?.host, "dQw4w9WgXcQ")
        XCTAssertEqual(url?.path, "/watch")
    }

    func testBlankIdsProduceNothingToOpen() {
        XCTAssertNil(TrailerLauncher.handoffURL(youTubeId: ""))
        XCTAssertNil(TrailerLauncher.handoffURL(youTubeId: "   "))
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(TrailerLauncher.videoId(from: "  abc123  "), "abc123")
    }

    // MARK: Ids that are not ids

    /// `trailers[].source` is documented as the bare id and plenty of addons put a link there.
    /// The same value is interpolated into the thumbnail path, so one malformed id used to break
    /// the artwork and the hand-off together.
    func testWatchLinksYieldTheirVideoId() {
        XCTAssertEqual(
            TrailerLauncher.videoId(from: "https://www.youtube.com/watch?v=abc123&t=30s"),
            "abc123"
        )
    }

    func testShortLinksYieldTheirVideoId() {
        XCTAssertEqual(TrailerLauncher.videoId(from: "https://youtu.be/abc123"), "abc123")
    }

    func testEmbedAndShortsPathsYieldTheirVideoId() {
        XCTAssertEqual(TrailerLauncher.videoId(from: "https://www.youtube.com/embed/abc123"), "abc123")
        XCTAssertEqual(TrailerLauncher.videoId(from: "https://www.youtube.com/shorts/abc123"), "abc123")
    }

    func testAPlainIdIsLeftAlone() {
        XCTAssertEqual(TrailerLauncher.videoId(from: "abc123"), "abc123")
        XCTAssertEqual(TrailerLauncher.videoId(from: "-a_B3-x"), "-a_B3-x")
    }
}
