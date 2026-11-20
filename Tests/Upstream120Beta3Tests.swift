import XCTest
@testable import Nuvio

/// `continue_watching_sort_mode` with upstream's values and orderings (1.0.68). Their
/// `ContinueWatchingUpcomingSortTest` and `sortContinueWatchingItems`, at the level of ours.
final class ContinueWatchingSortModeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func entry(
        _ id: String, lastWatchedDaysAgo: Double, releasedDaysFromNow: Double? = nil
    ) -> ContinueWatchingEntry {
        ContinueWatchingEntry(
            progress: WatchProgress(
                contentId: id, contentType: "series", videoId: "\(id):1:1", season: 1, episode: 1,
                positionSeconds: 0, durationSeconds: 0,
                updatedAt: now.addingTimeInterval(-lastWatchedDaysAgo * 86_400)
            ),
            preview: MetaPreview(id: id, type: .series, rawType: "series", name: id),
            isNextUp: releasedDaysFromNow != nil,
            episodeReleased: releasedDaysFromNow.map { now.addingTimeInterval($0 * 86_400) }
        )
    }

    private func ids(_ entries: [ContinueWatchingEntry]) -> [String] { entries.map(\.progress.contentId) }

    /// The bytes both apps write under the key. Anything else is read as the other's default.
    func testRawValuesAreUpstreams() {
        XCTAssertEqual(ContinueWatchingSortMode.allCases.map(\.rawValue), ["DEFAULT", "STREAMING_STYLE", "SPLIT_UPCOMING"])
        XCTAssertNil(ContinueWatchingSortMode(rawValue: "RECENT"))
    }

    /// A next-up episode that aired after the show was last watched sorts by its release.
    func testDefaultBringsForwardANewlyAiredEpisode() {
        let recent = entry("recent", lastWatchedDaysAgo: 1)
        let returning = entry("returning", lastWatchedDaysAgo: 30, releasedDaysFromNow: -0.5)
        let stale = entry("stale", lastWatchedDaysAgo: 200, releasedDaysFromNow: -90)
        let sorted = LibraryStore.sortContinueWatching([recent, stale, returning], by: .default, now: now)
        XCTAssertEqual(ids(sorted), ["returning", "recent", "stale"])
    }

    func testStreamingStylePutsUpcomingLastSoonestFirst() {
        let later = entry("later", lastWatchedDaysAgo: 1, releasedDaysFromNow: 10)
        let sooner = entry("sooner", lastWatchedDaysAgo: 5, releasedDaysFromNow: 2)
        let watching = entry("watching", lastWatchedDaysAgo: 3)
        let sorted = LibraryStore.sortContinueWatching([later, sooner, watching], by: .streamingStyle, now: now)
        XCTAssertEqual(ids(sorted), ["watching", "sooner", "later"])
    }

    func testSplitUpcomingMovesUnairedEpisodesToTheirOwnRow() {
        let upcoming = entry("upcoming", lastWatchedDaysAgo: 1, releasedDaysFromNow: 3)
        let watching = entry("watching", lastWatchedDaysAgo: 2)
        let rows = LibraryStore.splitUpcoming([upcoming, watching], mode: .splitUpcoming, now: now)
        XCTAssertEqual(ids(rows.main), ["watching"])
        XCTAssertEqual(ids(rows.upcoming), ["upcoming"])
        XCTAssertTrue(LibraryStore.splitUpcoming([upcoming, watching], mode: .default, now: now).upcoming.isEmpty)
    }

    /// b37084be7: two episodes airing the same day are ordered by their time.
    func testSameDayUpcomingEpisodesAirInTimeOrder() {
        let evening = entry("evening", lastWatchedDaysAgo: 1, releasedDaysFromNow: 3.8)
        let morning = entry("morning", lastWatchedDaysAgo: 1, releasedDaysFromNow: 3.3)
        let rows = LibraryStore.splitUpcoming([evening, morning], mode: .splitUpcoming, now: now, calendar: utc)
        XCTAssertEqual(ids(rows.upcoming), ["morning", "evening"])
    }
}

/// `follow_addons_order` and the Catalog Order screen (upstream b6ce5a389, 1.0.68).
final class FollowAddonsOrderTests: XCTestCase {
    private let owners = ["https://a#movie/top": "https://a", "https://a#series/top": "https://a", "https://b#movie/new": "https://b"]
    private let a1 = HomeRowKey.catalog("https://a#movie/top")
    private let a2 = HomeRowKey.catalog("https://a#series/top")
    private let b1 = HomeRowKey.catalog("https://b#movie/new")
    private let c1 = HomeRowKey.collection("c1")
    private let c2 = HomeRowKey.collection("c2")

    /// Upstream's default. Ours was on, so catalogue moves on a fresh install did nothing on Home.
    @MainActor
    func testFollowingTheAddonOrderIsOffByDefault() throws {
        let suite = "FollowAddonsOrderTests"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        XCTAssertFalse(LayoutSettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).followAddonsOrder)
    }

    /// Our old Continue Watching sort values are cleared on launch, so none is pushed again.
    @MainActor
    func testOldSortValuesAreCleared() throws {
        let suite = "ContinueWatchingSortMigration"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        LayoutSettingsStore(defaults: defaults).continueWatchingSortMode = .streamingStyle
        XCTAssertEqual(LayoutSettingsStore(defaults: defaults).storedValue("continue_watching_sort_mode") as? String, "STREAMING_STYLE")
        let raw = LayoutSettingsStore(defaults: defaults)
        raw.migrating { raw.setString("continue_watching_sort_mode", "ALPHA") }
        let reopened = LayoutSettingsStore(defaults: defaults)
        XCTAssertNil(reopened.storedValue("continue_watching_sort_mode"))
        XCTAssertEqual(reopened.continueWatchingSortMode, .default)
    }

    /// A collection steps over the neighbouring addon's whole run of catalogues, never into it.
    func testACollectionMovesPastAWholeAddonBlock() {
        let order = [a1, a2, b1, c1]
        XCTAssertEqual(HomeRowOrder.movingCollection(c1, by: -1, in: order, owners: owners), [a1, a2, c1, b1])
        XCTAssertEqual(HomeRowOrder.movingCollection(c1, by: -1, in: [a1, a2, c1, b1], owners: owners), [c1, a1, a2, b1])
        XCTAssertNil(HomeRowOrder.movingCollection(c1, by: -1, in: [c1, a1, a2, b1], owners: owners))
    }

    /// Other collections beside it are stepped over too, as upstream's scan does.
    func testNeighbouringCollectionsAreSteppedOver() {
        XCTAssertEqual(HomeRowOrder.movingCollection(c2, by: -1, in: [a1, a2, c1, c2, b1], owners: owners), [c2, a1, a2, c1, b1])
    }

    func testCataloguesDoNotMoveWhileFollowing() {
        XCTAssertNil(HomeRowOrder.movingCollection(a2, by: -1, in: [a1, a2, b1], owners: owners))
    }
}

/// Upstream's `resolveWithSourceFallback` cases (d020e4af7): the source screen falls back past
/// a stream it cannot resolve, and hands what it tried to the player.
final class PrePlaybackFallbackTests: XCTestCase {
    private func torrent(_ addon: String, hash: String) -> Nuvio.Stream {
        var stream = Nuvio.Stream(title: hash, addonName: addon)
        stream.infoHash = hash
        return stream
    }

    func testTheNextCandidateIsResolvedWhenTheFirstCannotBe() async {
        let expired = torrent("Torrentio", hash: "aaa")
        let good = torrent("Torrentio", hash: "bbb")
        let run = await SourceFallback.resolve(
            first: expired, maxSources: 3,
            resolve: { $0.infoHash == "bbb" ? "https://cdn/b.mkv" : nil },
            next: { _, tried in [expired, good].first { !tried.contains(SourceFallback.key(for: $0)) } }
        )
        XCTAssertEqual(run.resolved?.link, "https://cdn/b.mkv")
        XCTAssertEqual(run.attempts, 1)
        XCTAssertEqual(run.triedKeys, [SourceFallback.key(for: expired), SourceFallback.key(for: good)])
    }

    func testNoFurtherSourceIsTriedPastTheLimit() async {
        let streams = (0..<5).map { torrent("A", hash: "h\($0)") }
        var asked = 0
        let run = await SourceFallback.resolve(
            first: streams[0], maxSources: 2,
            resolve: { _ -> String? in asked += 1; return nil },
            next: { _, tried in streams.first { !tried.contains(SourceFallback.key(for: $0)) } }
        )
        XCTAssertNil(run.resolved)
        XCTAssertEqual(asked, 3)
        XCTAssertEqual(run.attempts, 2)
    }

    /// The fallback off is a limit of zero: one stream, as before.
    func testALimitOfZeroTriesOnlyTheFirst() async {
        let run = await SourceFallback.resolve(
            first: torrent("A", hash: "x"), maxSources: 0,
            resolve: { _ -> String? in nil },
            next: { _, _ in XCTFail("no second stream"); return nil }
        )
        XCTAssertNil(run.resolved)
    }
}

/// Upstream's `LocalDebridServiceTest` (89989cf2b).
final class TorboxAliasTests: XCTestCase {
    private let canonical = "7db44b3713094e622246b715de410bb9b6d91230"
    private let requested = "b72ca5570c56c2387526b6aab184f0cf0075cff0"

    func testExactMatchesStayWithoutExtraRequests() async {
        let resolved = await DebridClient.resolvingTorboxAliases(["abc123": "exact"], requested: ["abc123"]) { _ in
            XCTFail("no extra request expected"); return nil
        }
        XCTAssertEqual(resolved, ["abc123": "exact"])
    }

    func testASingleAliasedAnswerMapsBackToTheRequestedHash() async {
        let resolved = await DebridClient.resolvingTorboxAliases([canonical: "aliased"], requested: [requested]) { _ in
            XCTFail("no extra request expected"); return nil
        }
        XCTAssertEqual(resolved, [requested: "aliased"])
    }

    func testOnlyTheHashesMissingFromABatchAreAskedAgain() async {
        var asked: [String] = []
        let resolved = await DebridClient.resolvingTorboxAliases(
            ["abc123": "exact", canonical: "aliased"], requested: ["abc123", requested]
        ) { hash in
            asked.append(hash)
            return [self.canonical: "aliased"]
        }
        XCTAssertEqual(asked, [requested])
        XCTAssertEqual(resolved["abc123"], "exact")
        XCTAssertEqual(resolved[requested], "aliased")
    }
}

/// Upstream's talk-show filter (51ebccc1c).
final class TalkShowCreditTests: XCTestCase {
    func testAGuestSpotOnATalkShowIsHidden() {
        XCTAssertTrue(TalkShowCredit.isGuestAppearance(genreIds: [10767], character: "Self - Guest"))
        XCTAssertTrue(TalkShowCredit.isGuestAppearance(genreIds: [10767, 35], character: nil))
    }

    func testTheHostAndOtherShowsStay() {
        XCTAssertFalse(TalkShowCredit.isGuestAppearance(genreIds: [10767], character: "Self - Host"))
        XCTAssertFalse(TalkShowCredit.isGuestAppearance(genreIds: [10767], character: "Co-Host"))
        XCTAssertFalse(TalkShowCredit.isGuestAppearance(genreIds: [18], character: "Walter White"))
        XCTAssertFalse(TalkShowCredit.isGuestAppearance(genreIds: nil, character: "Guest"))
    }
}

/// Upstream's `EpisodeRatingsAlignmentTest` cases (e2ecb1c5f), against `EpisodeAlignment`.
final class EpisodeAlignmentTests: XCTestCase {
    private typealias N = EpisodeAlignment.Number
    private let today = Date(timeIntervalSince1970: 1_800_000_000)

    private func show(_ counts: [Int], start: String = "2020-01-01") -> [EpisodeAlignment.Episode] {
        var day = EpisodeAlignment.airDay(start)!
        var result: [EpisodeAlignment.Episode] = []
        for (index, count) in counts.enumerated() {
            for episode in 1...count {
                let date = Date(timeIntervalSince1970: Double(day) * 86_400)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                result.append(.init(number: N(season: index + 1, episode: episode), airDate: formatter.string(from: date)))
                day += 7
            }
        }
        return result
    }

    func testTheSameSeasonsKeepTheirNumbers() {
        XCTAssertNil(EpisodeAlignment.pairs(addon: show([10, 10]), external: show([12, 8]), today: today))
    }

    /// Black Clover: the addon's 2 seasons against the provider's 5, same episodes overall.
    func testSplitSeasonsPairInAiringOrder() {
        let pairs = EpisodeAlignment.pairs(addon: show([51, 119]), external: show([51, 51, 52, 16, 0].filter { $0 > 0 }), today: today)
        XCTAssertEqual(pairs?[N(season: 2, episode: 1)], N(season: 2, episode: 1))
        XCTAssertEqual(pairs?[N(season: 2, episode: 52)], N(season: 3, episode: 1))
        XCTAssertEqual(pairs?[N(season: 2, episode: 119)], N(season: 4, episode: 16))
    }

    /// Different totals: only episodes airing on the same day (a day either side) are paired.
    func testDifferentTotalsPairByAirDate() {
        var external = show([3, 3])
        external.removeLast()
        let pairs = EpisodeAlignment.pairs(addon: show([6]), external: external, today: today)
        XCTAssertEqual(pairs?[N(season: 1, episode: 4)], N(season: 2, episode: 1))
        XCTAssertNil(pairs?[N(season: 1, episode: 6)])
    }
}
