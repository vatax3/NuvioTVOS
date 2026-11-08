import XCTest
@testable import Nuvio

/// Upstream's three new `TraktEpisodeMappingServiceTest` cases (1.1.0-beta.13), at the level of
/// our matcher: writes keep the addon's number when Trakt has that episode.
final class TraktWriteNumberingTests: XCTestCase {
    private func show(_ seasons: [Int], title: (Int, Int) -> String? = { _, _ in nil }) -> [EpisodeRemap.Entry] {
        seasons.enumerated().flatMap { index, count in
            (1...count).map { EpisodeRemap.Entry(season: index + 1, episode: $0, title: title(index + 1, $0)) }
        }
    }

    private func write(_ season: Int, _ episode: Int, addon: [EpisodeRemap.Entry], trakt: [EpisodeRemap.Entry]) -> EpisodeRemap.Entry? {
        guard !EpisodeRemap.hasSameSeasonStructure(addon, trakt) else {
            return EpisodeRemap.Entry(season: season, episode: episode)
        }
        return EpisodeRemap.remap(
            season: season, episode: episode, preferSameNumber: true, from: addon, to: trakt
        )
    }

    /// The Block: Trakt has two more episodes before the current season and room-week titles
    /// repeat every season, so the index used to send S2E15 as S2E13.
    func testWrittenEpisodesKeepTheirNumbersWhenTraktHasThem() {
        let roomWeek: (Int, Int) -> String? = { _, episode in "Room Week (\(episode))" }
        let mapped = write(2, 15, addon: show([13, 50], title: roomWeek), trakt: show([15, 50], title: roomWeek))
        XCTAssertEqual(mapped.map { [$0.season, $0.episode] }, [2, 15])
    }

    func testWrittenEpisodesTraktLacksAreStillRemapped() {
        let mapped = write(2, 11, addon: show([24, 24]), trakt: show([48]))
        XCTAssertEqual(mapped.map { [$0.season, $0.episode] }, [1, 35])
    }

    func testAUniqueTitleMatchStillWinsOverTheSameNumber() {
        func chapters(_ counts: [Int]) -> (Int, Int) -> String? {
            { season, episode in "Chapter \(counts.prefix(season - 1).reduce(0, +) + episode)" }
        }
        let mapped = write(2, 3, addon: show([5, 5], title: chapters([5, 5])), trakt: show([7, 3], title: chapters([7, 3])))
        XCTAssertEqual(mapped.map { [$0.season, $0.episode] }, [2, 1])
    }

    /// Reads keep the old behaviour: without the flag, position decides.
    func testReadsAreUnchanged() {
        let mapped = EpisodeRemap.remap(season: 2, episode: 15, from: show([13, 50]), to: show([15, 50]))
        XCTAssertEqual(mapped.map { [$0.season, $0.episode] }, [2, 13])
    }
}

final class RepeatedEntryTests: XCTestCase {
    func testRepeatedCollectionSourcesGetUniqueKeys() {
        let a = CollectionSource.addon(AddonCollectionSource(addonId: "x", type: "movie", catalogId: "top"))
        let b = CollectionSource.addon(AddonCollectionSource(addonId: "y", type: "movie", catalogId: "top"))
        let keys = CollectionSource.occurrenceKeys([a, b, a, a])
        XCTAssertEqual(keys, [a.id, b.id, "\(a.id)#1", "\(a.id)#2"])
        XCTAssertEqual(Set(keys).count, 4)
    }

    func testCatalogOrderKeepsTheFirstOfARepeatedCatalog() {
        let first = CatalogOrderEntry(addonBaseUrl: "https://a", catalogKey: "movie/top", enabled: true)
        var again = first
        again.enabled = false
        let other = CatalogOrderEntry(addonBaseUrl: "https://a", catalogKey: "series/top", enabled: true)
        let uniqued = AddonStore.uniqued([first, other, again])
        XCTAssertEqual(uniqued, [first, other])
    }
}
