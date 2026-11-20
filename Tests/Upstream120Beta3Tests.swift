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
