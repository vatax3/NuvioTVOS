import XCTest
@testable import Nuvio

final class SimklIdResolutionTests: XCTestCase {
    func testTheRedirectCarriesTypeAndId() {
        XCTAssertEqual(
            SimklIdResolution.parseRedirect(location: "https://simkl.com/anime/40881/some-title"),
            SimklIdResolution.Redirect(type: "anime", simklId: 40881)
        )
    }

    func testAQueryStringIsIgnored() {
        XCTAssertEqual(
            SimklIdResolution.parseRedirect(location: "https://simkl.com/tv/1234?utm=x"),
            SimklIdResolution.Redirect(type: "tv", simklId: 1234)
        )
    }

    /// Found by name, not by position: the path has carried a locale prefix before now.
    func testAPrefixedPathStillResolves() {
        XCTAssertEqual(
            SimklIdResolution.parseRedirect(location: "https://simkl.com/fr/anime/99/x"),
            SimklIdResolution.Redirect(type: "anime", simklId: 99)
        )
    }

    func testSomethingThatIsNotATitleResolvesToNothing() {
        XCTAssertNil(SimklIdResolution.parseRedirect(location: "https://simkl.com/settings"))
        XCTAssertNil(SimklIdResolution.parseRedirect(location: "https://simkl.com/anime/notanumber"))
        XCTAssertNil(SimklIdResolution.parseRedirect(location: ""))
    }

    // MARK: Mapping

    private let sample: [(episode: Int?, tvdbSeason: Int?, tvdbEpisode: Int?)] = [
        (1, 1, 1), (2, 1, 2), (13, 2, 1), (14, 2, 2),
        (nil, 1, 5),      // Simkl knows the TVDB slot but not the anime number
        (7, 0, 3),        // season 0 is specials
        (8, 1, nil),
    ]

    func testOnlyFullyKnownEpisodesSurvive() {
        let mappings = SimklIdResolution.mappings(from: sample)
        XCTAssertEqual(mappings.map(\.animeEpisode), [1, 2, 13, 14])
    }

    /// The case ARM got wrong: a second cour that continues the anime numbering but restarts the
    /// TVDB season. A flat per-season index would answer 1 here.
    func testASecondCourMapsToItsOwnAnimeNumber() {
        let mappings = SimklIdResolution.mappings(from: sample)
        XCTAssertEqual(
            SimklIdResolution.animeEpisode(forTvdbSeason: 2, episode: 1, in: mappings), 13
        )
    }

    func testTheForwardDirectionAlsoWorks() {
        let mappings = SimklIdResolution.mappings(from: sample)
        let pair = SimklIdResolution.tvdb(for: 14, in: mappings)
        XCTAssertEqual(pair?.season, 2)
        XCTAssertEqual(pair?.episode, 2)
    }

    func testAnEpisodeSimklDoesNotKnowResolvesToNothing() {
        let mappings = SimklIdResolution.mappings(from: sample)
        XCTAssertNil(SimklIdResolution.animeEpisode(forTvdbSeason: 9, episode: 9, in: mappings))
        XCTAssertNil(SimklIdResolution.tvdb(for: 99, in: mappings))
    }

    func testSpecialsAreNotTreatedAsASeason() {
        let mappings = SimklIdResolution.mappings(from: sample)
        XCTAssertFalse(mappings.contains { $0.tvdbSeason == 0 })
    }
}
