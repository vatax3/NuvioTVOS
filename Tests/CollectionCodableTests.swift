import XCTest
@testable import Nuvio

/// The wire format, which is the whole reason the model was replaced.
///
/// Collections travel between the Android, mobile and tvOS apps through one `collections_json`
/// blob on the account. Before this, the payloads had nothing in common: theirs would not decode
/// here at all, and ours parsed there into titleless empty collections, so whichever app synced
/// last destroyed the other's work. These tests are what keeps that from coming back.
///
/// The fixture is built to the shape in upstream's `CollectionsDataStore.kt` — a live capture
/// would need the Android app and an account, which is noted in the parity document as the one
/// check that has not been run.
final class CollectionCodableTests: XCTestCase {
    private let androidPayload = """
    [
      {
        "id": "c1",
        "title": "Saturday night",
        "backdropImageUrl": "https://example.test/backdrop.jpg",
        "pinToTop": true,
        "focusGlowEnabled": false,
        "viewMode": "ROWS",
        "showAllTab": false,
        "folders": [
          {
            "id": "f1",
            "title": "Comedies",
            "coverImageUrl": "https://example.test/cover.jpg",
            "focusGifUrl": "https://example.test/cover.gif",
            "focusGifEnabled": true,
            "coverEmoji": "🍿",
            "tileShape": "LANDSCAPE",
            "hideTitle": true,
            "heroBackdropUrl": "https://example.test/hero.jpg",
            "heroVideoUrl": "https://example.test/hero.mp4",
            "titleLogoUrl": "https://example.test/logo.png",
            "sources": [
              {"provider":"addon","addonId":"com.linvo.cinemeta","type":"movie","catalogId":"top","genre":"Comedy"},
              {"provider":"tmdb","tmdbSourceType":"DISCOVER","title":"Highly rated","mediaType":"movie","sortBy":"vote_average.desc","filters":{"withGenres":"35","voteCountGte":500}},
              {"provider":"trakt","title":"Best of 2024","traktListId":1234567,"mediaType":"tv","sortBy":"rank","sortHow":"desc"}
            ],
            "catalogSources": [
              {"addonId":"com.linvo.cinemeta","type":"movie","catalogId":"top","genre":"Comedy"}
            ]
          }
        ]
      }
    ]
    """

    private func decoded() throws -> [MediaCollection] {
        try CollectionStore.decode(androidPayload)
    }

    // MARK: Reading

    func testCollectionFieldsSurvive() throws {
        let collection = try XCTUnwrap(decoded().first)
        XCTAssertEqual(collection.id, "c1")
        XCTAssertEqual(collection.title, "Saturday night")
        XCTAssertEqual(collection.backdropImageUrl, "https://example.test/backdrop.jpg")
        XCTAssertTrue(collection.pinToTop)
        XCTAssertEqual(collection.focusGlowEnabled, false)
        XCTAssertEqual(collection.viewMode, .rows)
        XCTAssertFalse(collection.showAllTab)
    }

    func testFolderFieldsSurvive() throws {
        let folder = try XCTUnwrap(decoded().first?.folders.first)
        XCTAssertEqual(folder.title, "Comedies")
        XCTAssertEqual(folder.tileShape, .landscape)
        XCTAssertTrue(folder.hideTitle)
        XCTAssertEqual(folder.coverEmoji, "🍿")
        // Carried but never drawn on tvOS. They still have to come back out unchanged, or a
        // round trip through this app would strip them from the Android one.
        XCTAssertEqual(folder.focusGifUrl, "https://example.test/cover.gif")
        XCTAssertEqual(folder.heroVideoUrl, "https://example.test/hero.mp4")
    }

    func testEachProviderDecodesToItsOwnCase() throws {
        let sources = try XCTUnwrap(decoded().first?.folders.first?.sources)
        XCTAssertEqual(sources.count, 3)

        guard case .addon(let addon) = sources[0] else { return XCTFail("first source should be an addon") }
        XCTAssertEqual(addon.addonId, "com.linvo.cinemeta")
        XCTAssertEqual(addon.genre, "Comedy")

        guard case .tmdb(let tmdb) = sources[1] else { return XCTFail("second source should be TMDB") }
        XCTAssertEqual(tmdb.sourceType, .discover)
        XCTAssertEqual(tmdb.sortBy, "vote_average.desc")
        XCTAssertEqual(tmdb.filters.withGenres, "35")
        XCTAssertEqual(tmdb.filters.voteCountGte, 500)

        guard case .trakt(let trakt) = sources[2] else { return XCTFail("third source should be Trakt") }
        XCTAssertEqual(trakt.traktListId, 1_234_567)
        XCTAssertEqual(trakt.mediaType, .tv)
        XCTAssertEqual(trakt.sortHow, "desc")
    }

    /// A provider-less source is an addon: Android's default, and what its older payloads carry.
    func testSourceWithoutAProviderIsAnAddon() throws {
        let json = """
        [{"id":"c","title":"t","folders":[{"id":"f","title":"f","sources":[
          {"addonId":"a","type":"movie","catalogId":"c"}
        ]}]}]
        """
        let sources = try XCTUnwrap(CollectionStore.decode(json).first?.folders.first?.sources)
        guard case .addon(let addon) = sources.first else { return XCTFail("should be an addon") }
        XCTAssertEqual(addon.addonId, "a")
    }

    /// `catalogSources` predates `sources` and is still written alongside it. A payload from an
    /// older build has only the former.
    func testLegacyCatalogSourcesAreReadWhenSourcesIsAbsent() throws {
        let json = """
        [{"id":"c","title":"t","folders":[{"id":"f","title":"f","catalogSources":[
          {"addonId":"a","type":"series","catalogId":"top"}
        ]}]}]
        """
        let sources = try XCTUnwrap(CollectionStore.decode(json).first?.folders.first?.sources)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.addonSource?.type, "series")
    }

    func testUnknownEnumValuesFallBackRatherThanThrowing() throws {
        let json = """
        [{"id":"c","title":"t","viewMode":"SOMETHING_NEW","folders":[
          {"id":"f","title":"f","tileShape":"HEXAGON","sources":[
            {"provider":"tmdb","tmdbSourceType":"NEWTHING","title":"x","mediaType":"HOLOGRAM"}
          ]}
        ]}]
        """
        let collection = try XCTUnwrap(CollectionStore.decode(json).first)
        XCTAssertEqual(collection.viewMode, .tabbedGrid)
        XCTAssertEqual(collection.folders.first?.tileShape, .square)
        guard case .tmdb(let tmdb) = try XCTUnwrap(collection.folders.first?.sources.first) else {
            return XCTFail("should still be a TMDB source")
        }
        XCTAssertEqual(tmdb.sourceType, .discover)
        XCTAssertEqual(tmdb.mediaType, .movie)
    }

    // MARK: Writing

    /// Re-encoding must produce something the other apps read back identically. Comparing the
    /// decoded forms rather than the bytes is deliberate: key order and whitespace are not part
    /// of the contract, and the fields are.
    func testRoundTripPreservesEverything() throws {
        let original = try decoded()
        let encoded = try JSONEncoder().encode(original)
        let again = try JSONDecoder().decode([MediaCollection].self, from: encoded)
        XCTAssertEqual(original, again)
    }

    /// Android's importer validates required fields per provider and rejects the whole payload
    /// when one is missing, so they have to be present even when they equal a default.
    func testEncodedSourcesCarryTheFieldsTheImporterRequires() throws {
        let encoded = try JSONEncoder().encode(try decoded())
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let folder = try XCTUnwrap((array.first?["folders"] as? [[String: Any]])?.first)
        let sources = try XCTUnwrap(folder["sources"] as? [[String: Any]])

        let addon = try XCTUnwrap(sources.first { $0["provider"] as? String == "addon" })
        XCTAssertNotNil(addon["addonId"] as? String)
        XCTAssertNotNil(addon["type"] as? String)
        XCTAssertNotNil(addon["catalogId"] as? String)

        let tmdb = try XCTUnwrap(sources.first { $0["provider"] as? String == "tmdb" })
        XCTAssertNotNil(tmdb["tmdbSourceType"] as? String)

        let trakt = try XCTUnwrap(sources.first { $0["provider"] as? String == "trakt" })
        XCTAssertNotNil(trakt["traktListId"] as? NSNumber)
    }

    /// Written in addition to `sources`, mirroring the addon entries only. Dropping it leaves
    /// older Android builds looking at empty folders.
    func testEncodingKeepsTheLegacyCatalogSourcesMirror() throws {
        let encoded = try JSONEncoder().encode(try decoded())
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let folder = try XCTUnwrap((array.first?["folders"] as? [[String: Any]])?.first)
        let legacy = try XCTUnwrap(folder["catalogSources"] as? [[String: Any]])

        XCTAssertEqual(legacy.count, 1, "only the addon sources are mirrored")
        XCTAssertEqual(legacy.first?["addonId"] as? String, "com.linvo.cinemeta")
    }

    /// Upper case for the enums Android upper-cases, lower case for the one it does not.
    func testEnumsAreWrittenInTheCaseTheOtherAppsExpect() throws {
        let encoded = try JSONEncoder().encode(try decoded())
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let collection = try XCTUnwrap(array.first)
        let folder = try XCTUnwrap((collection["folders"] as? [[String: Any]])?.first)

        XCTAssertEqual(collection["viewMode"] as? String, "ROWS")
        XCTAssertEqual(folder["tileShape"] as? String, "LANDSCAPE")

        let sources = try XCTUnwrap(folder["sources"] as? [[String: Any]])
        let tmdb = try XCTUnwrap(sources.first { $0["provider"] as? String == "tmdb" })
        XCTAssertEqual(tmdb["tmdbSourceType"] as? String, "DISCOVER")
        XCTAssertEqual(tmdb["mediaType"] as? String, "movie")
    }
}
