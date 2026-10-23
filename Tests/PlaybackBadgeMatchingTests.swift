import XCTest
@testable import Nuvio

/// The text-shaped entry point taken out of `badges(for stream:…)` for the player.
///
/// What matters for a refactor is that the behaviour the old caller depended on is still there,
/// so these pin the two things the extraction could have lost: filter order and the
/// de-duplication by logo.
final class PlaybackBadgeMatchingTests: XCTestCase {
    private func filter(name: String, pattern: String, image: String = "") -> StreamBadgeFilter {
        StreamBadgeFilter(
            id: name, groupId: "g", name: name, pattern: pattern, imageURL: image, isEnabled: true
        )
    }

    private func compiled(_ filters: [StreamBadgeFilter]) -> [CompiledStreamBadgeFilter] {
        StreamBadgeMatcher.compile(
            StreamBadgeRules(imports: [
                StreamBadgeImport(sourceUrl: "https://example.test/pack.json", filters: filters, isActive: true)
            ])
        )
    }

    func testNoFiltersEarnsNoBadges() {
        XCTAssertTrue(StreamBadgeMatcher.badges(matching: ["2160p"], filters: []).isEmpty)
    }

    func testNoCandidatesEarnsNoBadges() {
        let filters = compiled([filter(name: "4K", pattern: "2160p")])
        XCTAssertTrue(StreamBadgeMatcher.badges(matching: [], filters: filters).isEmpty)
    }

    func testAMatchingTokenEarnsItsBadge() {
        let filters = compiled([filter(name: "4K", pattern: "2160p")])
        let out = StreamBadgeMatcher.badges(matching: ["2160p", "UHD"], filters: filters)
        XCTAssertEqual(out.map(\.name), ["4K"])
    }

    func testANonMatchingTokenEarnsNothing() {
        let filters = compiled([filter(name: "4K", pattern: "2160p")])
        XCTAssertTrue(StreamBadgeMatcher.badges(matching: ["1080p"], filters: filters).isEmpty)
    }

    func testBadgesComeBackInFilterOrderNotTokenOrder() {
        let filters = compiled([
            filter(name: "first", pattern: "Atmos"),
            filter(name: "second", pattern: "2160p")
        ])
        let out = StreamBadgeMatcher.badges(matching: ["2160p", "Atmos"], filters: filters)
        XCTAssertEqual(out.map(\.name), ["first", "second"])
    }

    /// Two rules pointing at one logo are the same badge wearing two names.
    func testTwoRulesSharingALogoDrawOnce() {
        let filters = compiled([
            filter(name: "Atmos", pattern: "Atmos", image: "https://example.test/atmos.png"),
            filter(name: "Dolby Atmos", pattern: "DD\\+", image: "https://example.test/atmos.png")
        ])
        let out = StreamBadgeMatcher.badges(matching: ["Atmos", "DD+"], filters: filters)
        XCTAssertEqual(out.count, 1, "one logo is one badge however many rules name it")
    }

    func testTwoLogolessRulesWithDistinctNamesBothDraw() {
        let filters = compiled([
            filter(name: "Atmos", pattern: "Atmos"),
            filter(name: "4K", pattern: "2160p")
        ])
        let out = StreamBadgeMatcher.badges(matching: ["Atmos", "2160p"], filters: filters)
        XCTAssertEqual(out.map(\.name), ["Atmos", "4K"])
    }

    /// The end the port actually exercises: a pack's patterns against what the engine reports.
    func testAPackMatchesWhatTheEngineReports() {
        let filters = compiled([
            filter(name: "4K", pattern: "2160p"),
            filter(name: "DV", pattern: "Dolby Vision"),
            filter(name: "Atmos", pattern: "Atmos"),
            filter(name: "DTS", pattern: "DTS-HD MA")
        ])
        let info = PlayerStreamInfo(
            videoCodec: "hevc",
            sourceRange: "BT.2020 · PQ (SMPTE ST 2084)",
            outputRange: "Dolby Vision",
            audioCodec: "E-AC-3 (JOC)",
            videoWidth: 3840,
            videoHeight: 2160,
            audioChannelCount: 6
        )
        let out = StreamBadgeMatcher.badges(
            matching: playbackBadgeTokens(info), filters: filters
        )
        XCTAssertEqual(out.map(\.name), ["4K", "DV", "Atmos"],
                       "the DTS rule must not match an E-AC-3 track")
    }
}
