import XCTest
@testable import Nuvio

/// Whether *Play* should be offered at all.
///
/// The rule is cheap; the failure modes are not. Every test here is really about one of two
/// things: never disabling a button before the stores have answered, and never disabling one
/// because a manifest happened to be thin.
final class PlaybackAvailabilityTests: XCTestCase {
    private func addon(
        id: String = "org.test",
        resources: [AddonResource],
        idPrefixes: [String] = [],
        enabled: Bool = true
    ) -> Addon {
        Addon(
            id: id,
            name: id,
            displayName: id,
            version: "1.0.0",
            baseUrl: "https://example.test",
            catalogs: [],
            types: [.movie, .series],
            rawTypes: ["movie", "series"],
            resources: resources,
            idPrefixes: idPrefixes,
            enabled: enabled
        )
    }

    private func scraper(types: [String], enabled: Bool = true) -> InstalledScraper {
        InstalledScraper(
            id: "scraper",
            repositoryId: "repo",
            name: "Scraper",
            supportedTypes: types,
            contentLanguage: [],
            enabled: enabled,
            manifestEnabled: true,
            code: "// code"
        )
    }

    // MARK: Failing open

    func testNothingIsUnavailableBeforeTheStoresHaveReported() {
        let availability = PlaybackAvailability(isLoaded: false)

        XCTAssertTrue(availability.canStream(type: "movie", videoId: "tt1375666"))
    }

    /// The case that makes `isLoaded` worth having. `AddonStore` always produces a list — two
    /// defaults at worst — so "no addons" is not how an empty state arrives. It arrives as
    /// records whose manifest cache was purged, which is indistinguishable from an addon that
    /// serves nothing unless something says the read is not finished.
    func testAPurgedManifestCacheDoesNotDisablePlayback() {
        let availability = PlaybackAvailability(addons: [], scrapers: [], isLoaded: false)

        XCTAssertTrue(availability.canStream(type: "series", videoId: "tt0944947:1:1"))
    }

    // MARK: The rule

    func testAnAddonDeclaringTheStreamResourceServesIt() {
        let availability = PlaybackAvailability(
            addons: [addon(resources: [AddonResource(name: "stream", types: ["movie"])])],
            isLoaded: true
        )

        XCTAssertTrue(availability.canStream(type: "movie", videoId: "tt1375666"))
    }

    func testAnAddonWithOnlyCatalogAndMetaServesNothing() {
        let availability = PlaybackAvailability(
            addons: [addon(resources: [
                AddonResource(name: "catalog", types: ["movie"]),
                AddonResource(name: "meta", types: ["movie"])
            ])],
            isLoaded: true
        )

        XCTAssertFalse(availability.canStream(type: "movie", videoId: "tt1375666"))
    }

    func testTheTypeHasToMatch() {
        let availability = PlaybackAvailability(
            addons: [addon(resources: [AddonResource(name: "stream", types: ["series"])])],
            isLoaded: true
        )

        XCTAssertFalse(availability.canStream(type: "movie", videoId: "tt1375666"))
        XCTAssertTrue(availability.canStream(type: "series", videoId: "tt0944947:1:1"))
    }

    func testAnIdOutsideTheDeclaredPrefixesIsNotServed() {
        let availability = PlaybackAvailability(
            addons: [addon(
                resources: [AddonResource(name: "stream", types: ["movie"], idPrefixes: ["tt"])]
            )],
            isLoaded: true
        )

        XCTAssertTrue(availability.canStream(type: "movie", videoId: "tt1375666"))
        XCTAssertFalse(availability.canStream(type: "movie", videoId: "kitsu:41370"))
    }

    func testADisabledAddonDoesNotCount() {
        let availability = PlaybackAvailability(
            addons: [addon(
                resources: [AddonResource(name: "stream", types: ["movie"])], enabled: false
            )],
            isLoaded: true
        )

        XCTAssertFalse(availability.canStream(type: "movie", videoId: "tt1375666"))
    }

    // MARK: Scrapers

    /// A viewer running plugins and no stream addon is a supported setup, and it was the one the
    /// naive version of this rule would have locked out of the app entirely.
    func testAScraperAloneIsEnough() {
        let availability = PlaybackAvailability(
            addons: [addon(resources: [AddonResource(name: "meta", types: ["movie"])])],
            scrapers: [scraper(types: ["movie"])],
            isLoaded: true
        )

        XCTAssertTrue(availability.canStream(type: "movie", videoId: "tt1375666"))
    }

    /// `InstalledScraper.supports` reads Stremio's `series` against a manifest's `tv`.
    func testAScraperSayingTvAnswersForSeries() {
        let availability = PlaybackAvailability(
            scrapers: [scraper(types: ["tv"])], isLoaded: true
        )

        XCTAssertTrue(availability.canStream(type: "series", videoId: "tt0944947:1:1"))
        XCTAssertFalse(availability.canStream(type: "movie", videoId: "tt1375666"))
    }

    // MARK: Streams attached to the meta

    /// Some addons never implement `/stream` and hang the links off the video entry. Judged by
    /// the manifests alone those titles are unplayable, and they play.
    func testAVideoCarryingItsOwnStreamsIsPlayableWithNoStreamAddon() {
        let availability = PlaybackAvailability(
            addons: [addon(resources: [AddonResource(name: "meta", types: ["series"])])],
            isLoaded: true
        )
        var video = Video(id: "tt0944947:1:1")
        video.hasEmbeddedStreams = true

        XCTAssertTrue(
            availability.canStream(type: "series", videoId: video.id, video: video)
        )
    }

    /// The flag belongs to one episode, not to the series. Handing in the wrong entry must not
    /// let it vouch for a different id.
    func testTheEmbeddedFlagOnlyCountsForItsOwnVideo() {
        let availability = PlaybackAvailability(
            addons: [addon(resources: [AddonResource(name: "meta", types: ["series"])])],
            isLoaded: true
        )
        var video = Video(id: "tt0944947:1:1")
        video.hasEmbeddedStreams = true

        XCTAssertFalse(
            availability.canStream(type: "series", videoId: "tt0944947:1:2", video: video)
        )
    }
}
