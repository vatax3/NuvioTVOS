import XCTest
@testable import Nuvio

/// Which id a library row is keyed on, and how an episode is addressed.
///
/// Anime is the one place where "the same show" is genuinely ambiguous: a franchise carries one
/// IMDb id across every season, while MAL and Kitsu give each season its own entry.
final class SimklAnimeIdentityTests: XCTestCase {
    private let franchise = [
        "imdb": "tt2560140",
        "mal": "40028",
        "kitsu": "41982",
        "tmdb": "1429"
    ]

    func testGroupingKeysOnImdb() {
        XCTAssertEqual(
            SimklClient.canonicalContentId(franchise, preference: .imdb),
            "tt2560140"
        )
    }

    /// The point of the setting: each MAL entry becomes its own row, so season four does not
    /// land on top of season one.
    func testSeparatingKeysOnTheAnimeId() {
        XCTAssertEqual(SimklClient.canonicalContentId(franchise, preference: .mal), "mal:40028")
        XCTAssertEqual(SimklClient.canonicalContentId(franchise, preference: .kitsu), "kitsu:41982")
    }

    /// Preferring MAL must not lose a title that has no MAL id — most series have none.
    func testTheAnimePreferenceFallsBackToImdb() {
        let ids = ["imdb": "tt0903747", "tmdb": "1396"]

        XCTAssertEqual(SimklClient.canonicalContentId(ids, preference: .mal), "tt0903747")
        XCTAssertEqual(SimklClient.canonicalContentId(ids, preference: .kitsu), "tt0903747")
    }

    /// And a title with neither still has to be keyed on something, or it silently vanishes
    /// from the library.
    func testATitleWithNoImdbIsStillKeyed() {
        XCTAssertEqual(SimklClient.canonicalContentId(["tmdb": "1396"]), "tmdb:1396")
        XCTAssertEqual(SimklClient.canonicalContentId(["simkl": "1234"]), "simkl:1234")
        XCTAssertEqual(SimklClient.canonicalContentId(["simkl_id": "1234"]), "simkl:1234")
    }

    func testNoUsableIdAtAll() {
        XCTAssertNil(SimklClient.canonicalContentId([:]))
        XCTAssertNil(SimklClient.canonicalContentId(["imdb": "  "]))
    }

    func testTheStoredKeysMatchAndroid() {
        XCTAssertEqual(SimklAnimeIdPreference.imdb.rawValue, "IMDB")
        XCTAssertEqual(SimklAnimeIdPreference.mal.rawValue, "MAL")
        XCTAssertEqual(SimklAnimeIdPreference.kitsu.rawValue, "KITSU")
    }
}

/// How an anime episode is addressed on the wire.
final class SimklAnimeAddressingTests: XCTestCase {
    private let ids = ["imdb": "tt2560140", "mal": "40028", "tmdb": "1429", "anilist": "16498"]

    // MARK: Video ids

    func testAnAnimeVideoIdIsRead() {
        let parsed = SimklAnimeAddressing.parseVideoId("mal:42203:7")

        XCTAssertEqual(parsed?.key, "mal")
        XCTAssertEqual(parsed?.id, "42203")
        XCTAssertEqual(parsed?.episode, 7)
    }

    func testEveryAnimeNamespaceIsRecognised() {
        for key in ["mal", "kitsu", "anidb", "anilist"] {
            XCTAssertNotNil(SimklAnimeAddressing.parseVideoId("\(key):1:1"), key)
        }
    }

    /// A bare `mal:42203` addresses the series, not an episode of it, and reading it as
    /// "episode 42203" would be worse than not reading it at all.
    func testASeriesLevelAnimeIdIsNotAnEpisode() {
        XCTAssertNil(SimklAnimeAddressing.parseVideoId("mal:42203"))
    }

    func testOrdinaryVideoIdsAreNotAnimeIds() {
        XCTAssertNil(SimklAnimeAddressing.parseVideoId("tt0903747:1:3"))
        XCTAssertNil(SimklAnimeAddressing.parseVideoId("mal:42203:x"))
        XCTAssertNil(SimklAnimeAddressing.parseVideoId(""))
    }

    // MARK: Path B — a per-entry absolute number

    /// `mal:42203:7` is episode 7 *of that entry*, whatever the interface calls it. Every other
    /// id is dropped: a franchise IMDb id alongside a per-season MAL id is a contradiction, and
    /// Simkl resolves it by matching whichever it sees first.
    func testAnAnimeVideoIdWinsOutrightAndClearsTheOthers() {
        let resolved = SimklAnimeAddressing.resolve(
            videoId: "mal:42203:7", ids: ids, season: 2, episode: 20
        )

        XCTAssertEqual(resolved.ids, ["mal": "42203"])
        XCTAssertEqual(resolved.form, .flat(episode: 7))
        XCTAssertNil(resolved.season)
        XCTAssertFalse(resolved.usesTvdbSeasons)
    }

    // MARK: Path A — season coordinates

    /// The mirror image: with season coordinates the franchise ids are correct and the
    /// per-season anime ids have to go, or Simkl prefers one and lands on the wrong entry.
    func testSeasonCoordinatesKeepTheFranchiseAndDropTheAnimeIds() {
        let resolved = SimklAnimeAddressing.resolve(
            videoId: "tt2560140:2:20", ids: ids, season: 2, episode: 20
        )

        XCTAssertEqual(resolved.ids, ["imdb": "tt2560140", "tmdb": "1429"])
        XCTAssertEqual(resolved.form, .seasoned(season: 2, episode: 20))
        XCTAssertEqual(resolved.season, 2)
        XCTAssertTrue(resolved.usesTvdbSeasons, "Simkl has to be told the numbers are per-season")
    }

    /// Specials sit in season zero, which is not a TVDB season coordinate anybody can act on.
    func testSeasonZeroIsNotTreatedAsSeasonCoordinates() {
        let resolved = SimklAnimeAddressing.resolve(
            videoId: "tt1:0:1", ids: ids, season: 0, episode: 1
        )

        XCTAssertEqual(resolved.form, .flat(episode: 1))
        XCTAssertEqual(resolved.ids, ids, "nothing was dropped, because nothing was ambiguous")
    }

    // MARK: Neither

    /// An anime film has exactly one episode as far as Simkl is concerned, and it is episode
    /// one — not "no episode", which would mark the whole entry.
    func testNoCoordinatesAtAllFallsBackToEpisodeOne() {
        let resolved = SimklAnimeAddressing.resolve(videoId: nil, ids: ids, season: nil, episode: nil)

        XCTAssertEqual(resolved.form, .flat(episode: 1))
        XCTAssertEqual(resolved.ids, ids)
    }

    func testAFlatlyNumberedSeriesKeepsItsNumber() {
        let resolved = SimklAnimeAddressing.resolve(
            videoId: "tt1:0:12", ids: ids, season: nil, episode: 12
        )

        XCTAssertEqual(resolved.form, .flat(episode: 12))
    }

    /// The two shapes are exclusive by construction. If both were ever produced at once the
    /// request would be self-contradictory, so the type has to make that unrepresentable.
    func testTheTwoShapesAreNeverBothPresent() {
        for (videoId, season, episode) in [
            ("mal:42203:7", 2, 20), ("tt1:2:20", 2, 20), ("tt1:0:1", nil, 1)
        ] as [(String, Int?, Int)] {
            let resolved = SimklAnimeAddressing.resolve(
                videoId: videoId, ids: ids, season: season, episode: episode
            )
            XCTAssertEqual(resolved.usesTvdbSeasons, resolved.season != nil)
        }
    }
}
