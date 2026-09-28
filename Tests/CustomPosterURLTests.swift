import XCTest
@testable import Nuvio

/// Building a poster URL from a pattern the viewer wrote.
///
/// The whole feature is string substitution, and every test that matters here is about the same
/// thing: **a pattern this title cannot satisfy has to produce nothing**, so the addon's own
/// poster is kept. The alternative is a request for `…/movie-.jpg`, a 404, and a placeholder card
/// where a poster used to be — which looks like the app losing artwork rather than a service not
/// covering that title.
final class CustomPosterURLTests: XCTestCase {
    private let imdbOnly = CustomPosterURL.ContentIds(id: "tt0903747", imdb: "tt0903747")
    private let both = CustomPosterURL.ContentIds(
        id: "tt0903747", imdb: "tt0903747", tmdb: "1396"
    )
    private let kitsuOnly = CustomPosterURL.ContentIds(id: "kitsu:7442", kitsu: "7442")

    // MARK: Reading the id

    func testAnImdbIdIsReadFromABareStremioId() {
        let ids = CustomPosterURL.ids(metaId: "tt0903747")

        XCTAssertEqual(ids.imdb, "tt0903747")
        XCTAssertNil(ids.tmdb)
    }

    func testANamespacedIdIsSplitOnItsPrefix() {
        XCTAssertEqual(CustomPosterURL.ids(metaId: "tmdb:1396").tmdb, "1396")
        XCTAssertEqual(CustomPosterURL.ids(metaId: "kitsu:7442").kitsu, "7442")
        XCTAssertEqual(CustomPosterURL.ids(metaId: "anilist:101922").anilist, "101922")
    }

    /// A title listed under another namespace may still carry its IMDb id, and that is the one
    /// namespace nearly every one of these services answers.
    func testAnExplicitImdbIdIsKeptAlongsideTheNamespacedOne() {
        let ids = CustomPosterURL.ids(metaId: "kitsu:7442", imdbId: "tt0903747")

        XCTAssertEqual(ids.kitsu, "7442")
        XCTAssertEqual(ids.imdb, "tt0903747")
    }

    func testAnUnknownNamespaceIsNotGuessedAt() {
        let ids = CustomPosterURL.ids(metaId: "somethingelse:99")

        XCTAssertNil(ids.imdb)
        XCTAssertNil(ids.tmdb)
        XCTAssertEqual(ids.id, "somethingelse:99")
    }

    // MARK: Substitution

    func testARequiredPlaceholderIsFilled() {
        let url = CustomPosterURL.resolve(
            pattern: "https://api.example.test/poster/{imdb_id}.jpg",
            ids: imdbOnly,
            contentType: "series"
        )

        XCTAssertEqual(url, "https://api.example.test/poster/tt0903747.jpg")
    }

    /// The defect this type exists to prevent.
    func testARequiredPlaceholderWithNoValueYieldsNothing() {
        let url = CustomPosterURL.resolve(
            pattern: "https://api.example.test/poster/{tmdb_id}.jpg",
            ids: imdbOnly,
            contentType: "series"
        )

        XCTAssertNil(url)
    }

    func testAnOptionalPlaceholderWithNoValueResolvesToNothingInPlace() {
        let url = CustomPosterURL.resolve(
            pattern: "https://api.example.test/p/{imdb_id}.jpg?lang={mal_id?}",
            ids: imdbOnly,
            contentType: "series"
        )

        XCTAssertEqual(url, "https://api.example.test/p/tt0903747.jpg?lang=")
    }

    func testSeveralPlaceholdersInOnePattern() {
        let url = CustomPosterURL.resolve(
            pattern: "https://api.example.test/{type}/{shape}/{imdb_id}.jpg",
            ids: imdbOnly,
            contentType: "movie",
            shape: .landscape
        )

        XCTAssertEqual(url, "https://api.example.test/movie/landscape/tt0903747.jpg")
    }

    func testAnEmptyPatternYieldsNothing() {
        XCTAssertNil(CustomPosterURL.resolve(pattern: "   ", ids: both, contentType: "movie"))
    }

    // MARK: The alternatives form

    func testTheFirstDeclaredNamespaceThisTitleHasIsUsed() {
        let url = CustomPosterURL.resolve(
            pattern: "https://api.example.test/p/{imdb_id|kitsu_id}.jpg",
            ids: kitsuOnly,
            contentType: "series"
        )

        XCTAssertEqual(url, "https://api.example.test/p/7442.jpg")
    }

    func testThePreferredNamespaceWinsWhenTheTitleHasBoth() {
        let url = CustomPosterURL.resolve(
            pattern: "https://api.example.test/p/{imdb_id|tmdb_id}.jpg",
            ids: both,
            contentType: "series"
        )

        XCTAssertEqual(url, "https://api.example.test/p/tt0903747.jpg")
    }

    /// The point of declaring them: no request is made for an id the service could not have
    /// answered anyway.
    func testNoneOfTheDeclaredNamespacesMeansNoRequest() {
        let url = CustomPosterURL.resolve(
            pattern: "https://api.example.test/p/{imdb_id|tmdb_id}.jpg",
            ids: kitsuOnly,
            contentType: "series"
        )

        XCTAssertNil(url)
    }

    // MARK: typed_id

    func testAnImdbIdNeedsNoTypePrefix() {
        XCTAssertEqual(
            CustomPosterURL.resolve(
                pattern: "https://api.example.test/p/{typed_id}.jpg",
                ids: imdbOnly,
                contentType: "series"
            ),
            "https://api.example.test/p/tt0903747.jpg"
        )
    }

    /// A bare TMDB number is ambiguous — 1396 is both a film and a series — so it carries the type.
    func testATmdbIdCarriesItsType() {
        let tmdb = CustomPosterURL.ContentIds(id: "tmdb:1396", tmdb: "1396")

        XCTAssertEqual(
            CustomPosterURL.resolve(
                pattern: "https://api.example.test/p/{typed_id}.jpg",
                ids: tmdb,
                contentType: "series"
            ),
            "https://api.example.test/p/series-1396.jpg"
        )
        XCTAssertEqual(
            CustomPosterURL.resolve(
                pattern: "https://api.example.test/p/{typed_id}.jpg",
                ids: tmdb,
                contentType: "movie"
            ),
            "https://api.example.test/p/movie-1396.jpg"
        )
    }

    // MARK: The multi-namespace services

    /// RPDB and its relatives name the namespace in the path as well as in the placeholder, so a
    /// second attempt has to move both or it requests a TMDB id from the IMDb route.
    func testAnRpdbPatternRetriesUnderTheOtherNamespace() {
        let tmdbOnly = CustomPosterURL.ContentIds(id: "tmdb:1396", tmdb: "1396")
        let url = CustomPosterURL.resolve(
            pattern: "https://api.ratingposterdb.com/KEY/imdb/poster-default/{imdb_id}.jpg",
            ids: tmdbOnly,
            contentType: "series"
        )

        XCTAssertEqual(
            url, "https://api.ratingposterdb.com/KEY/tmdb/poster-default/series-1396.jpg"
        )
    }

    func testTheDirectFormIsPreferredOverAnyRetry() {
        let url = CustomPosterURL.resolve(
            pattern: "https://api.ratingposterdb.com/KEY/imdb/poster-default/{imdb_id}.jpg",
            ids: both,
            contentType: "series"
        )

        XCTAssertEqual(
            url, "https://api.ratingposterdb.com/KEY/imdb/poster-default/tt0903747.jpg"
        )
    }

    /// `movie-{tmdb_id}` written out longhand is the same request as `{typed_id}`. Replacing the
    /// placeholder alone would leave a stray `series-` in front of the substituted id.
    func testALonghandTypePrefixIsNotDoubledOnRetry() {
        let imdb = CustomPosterURL.ContentIds(id: "tt0903747", imdb: "tt0903747")
        let url = CustomPosterURL.resolve(
            pattern: "https://api.aioratings.com/KEY/tmdb/poster/series-{tmdb_id}.jpg",
            ids: imdb,
            contentType: "series"
        )

        XCTAssertEqual(url, "https://api.aioratings.com/KEY/imdb/poster/tt0903747.jpg")
    }

    func testAnAnimeWithNoWesternIdStillYieldsNothingOnTheseServices() {
        let url = CustomPosterURL.resolve(
            pattern: "https://api.ratingposterdb.com/KEY/imdb/poster-default/{imdb_id}.jpg",
            ids: kitsuOnly,
            contentType: "series"
        )

        XCTAssertNil(url)
    }

    /// `btttr.cc` joined the list three days before this was written. Pinned so a future edit to
    /// the domain list does not silently drop it.
    func testEveryKnownMultiNamespaceDomainIsRecognised() {
        for domain in ["ratingposterdb.com", "aioratings.com", "top-posters.com", "btttr.cc"] {
            let tmdbOnly = CustomPosterURL.ContentIds(id: "tmdb:1396", tmdb: "1396")
            XCTAssertNotNil(
                CustomPosterURL.resolve(
                    pattern: "https://api.\(domain)/KEY/imdb/poster/{imdb_id}.jpg",
                    ids: tmdbOnly,
                    contentType: "movie"
                ),
                "\(domain) should retry under another namespace"
            )
        }
    }

    // MARK: Applying it to a title

    func testThePosterIsReplacedAndTheOriginalKept() {
        var preview = MetaPreview(
            id: "tt0903747", type: .series, rawType: "series", name: "Breaking Bad"
        )
        preview.poster = "https://addon.test/original.jpg"

        let result = preview.withCustomPoster(
            pattern: "https://api.example.test/p/{imdb_id}.jpg"
        )

        XCTAssertEqual(result.poster, "https://api.example.test/p/tt0903747.jpg")
        XCTAssertEqual(result.rawPosterUrl, "https://addon.test/original.jpg")
    }

    func testAnEmptyPatternLeavesTheTitleUntouched() {
        var preview = MetaPreview(
            id: "tt0903747", type: .series, rawType: "series", name: "Breaking Bad"
        )
        preview.poster = "https://addon.test/original.jpg"

        XCTAssertEqual(preview.withCustomPoster(pattern: ""), preview)
    }

    func testATitleThatCannotSatisfyThePatternIsLeftUntouched() {
        var preview = MetaPreview(
            id: "kitsu:7442", type: .series, rawType: "series", name: "An anime"
        )
        preview.poster = "https://addon.test/original.jpg"

        let result = preview.withCustomPoster(
            pattern: "https://api.example.test/p/{imdb_id}.jpg"
        )

        XCTAssertEqual(result.poster, "https://addon.test/original.jpg")
        XCTAssertNil(result.rawPosterUrl)
    }

    /// A pattern with no `{shape}` describes portrait art only. Stretching it across a landscape
    /// rail is worse than leaving the addon's own wide artwork there.
    func testAPatternWithoutShapeLeavesWideArtworkAlone() {
        var preview = MetaPreview(
            id: "tt0903747", type: .series, rawType: "series", name: "Breaking Bad"
        )
        preview.poster = "https://addon.test/original.jpg"
        preview.posterShape = .landscape

        XCTAssertEqual(
            preview.withCustomPoster(pattern: "https://api.example.test/p/{imdb_id}.jpg"),
            preview
        )
    }

    func testAPatternWithShapeAlsoResolvesTheLandscapeArtwork() {
        var preview = MetaPreview(
            id: "tt0903747", type: .series, rawType: "series", name: "Breaking Bad"
        )
        preview.poster = "https://addon.test/original.jpg"

        let result = preview.withCustomPoster(
            pattern: "https://api.example.test/{shape}/{imdb_id}.jpg"
        )

        XCTAssertEqual(result.poster, "https://api.example.test/poster/tt0903747.jpg")
        XCTAssertEqual(
            result.landscapePoster, "https://api.example.test/landscape/tt0903747.jpg"
        )
    }

    /// Applied twice — a redraw, or a list passed through two screens — the addon's own poster
    /// must survive as the fallback rather than being overwritten by the first replacement.
    func testApplyingItTwiceDoesNotLoseTheOriginal() {
        var preview = MetaPreview(
            id: "tt0903747", type: .series, rawType: "series", name: "Breaking Bad"
        )
        preview.poster = "https://addon.test/original.jpg"
        let pattern = "https://api.example.test/p/{imdb_id}.jpg"

        let twice = preview.withCustomPoster(pattern: pattern).withCustomPoster(pattern: pattern)

        XCTAssertEqual(twice.rawPosterUrl, "https://addon.test/original.jpg")
    }

    // MARK: The per-screen gate

    /// An empty stored set has to mean *every* screen: it is what an upgrade from a version
    /// without the setting reads as, and the alternative silently disables a configured pattern.
    func testNoStoredScreensMeansEveryScreen() {
        XCTAssertEqual(CustomPosterScreen.from(keys: []), Set(CustomPosterScreen.allCases))
    }

    func testOnlyTheStoredScreensAreEnabled() {
        XCTAssertEqual(
            CustomPosterScreen.from(keys: ["home", "search"]), [.home, .search]
        )
    }

    /// The sentinel the settings screen writes when the viewer switches every screen off. It has
    /// to be distinguishable from "nothing stored yet", or turning them all off turns them all on.
    func testAnUnrecognisedKeyEnablesNothing() {
        XCTAssertEqual(CustomPosterScreen.from(keys: ["none"]), [])
    }

    func testTheStoredKeysAreTheOnesTheServedPageSends() {
        XCTAssertEqual(
            Set(CustomPosterScreen.allCases.map(\.rawValue)),
            ["home", "continue_watching", "collections", "library", "search", "details"]
        )
    }
}
