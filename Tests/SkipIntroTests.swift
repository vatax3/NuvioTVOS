import XCTest
@testable import Nuvio

/// These pin the wire formats against payloads captured from the live services, because the
/// failure they replace was silent: every field decoded to nil, every result was dropped, and a
/// title with skip marks was indistinguishable from one without. Nothing threw, nothing logged.
final class SkipIntroTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: AniSkip

    /// Captured from `api.aniskip.com/v2/skip-times/16498/1`. The keys are camelCase; decoding
    /// them as `start_time` / `skip_type` is what produced no segments at all.
    private let aniSkipPayload = """
    {"found":true,"results":[
      {"interval":{"startTime":128.406,"endTime":218.406},"skipType":"op",
       "skipId":"2e4331b9","episodeLength":1441.94},
      {"interval":{"startTime":1342.795,"endTime":1430.616},"skipType":"ed",
       "skipId":"d7b4737b","episodeLength":1446.99}
    ],"message":"Successfully found skip times","statusCode":200}
    """

    func testAniSkipPayloadYieldsSegments() throws {
        let response = try decode(aniSkipPayload, as: SkipIntroClient.AniSkipResponse.self)
        let segments = SkipIntroClient.segments(from: response)

        XCTAssertEqual(segments.count, 2, "a payload with two intervals must not decode to nothing")
        XCTAssertEqual(segments[0].kind, .intro)
        XCTAssertEqual(segments[0].start, 128.406, accuracy: 0.001)
        XCTAssertEqual(segments[0].end, 218.406, accuracy: 0.001)
        XCTAssertEqual(segments[1].kind, .outro)
    }

    func testAniSkipTypesMapToKinds() throws {
        let payload = """
        {"found":true,"results":[
          {"interval":{"startTime":1,"endTime":2},"skipType":"mixed-op"},
          {"interval":{"startTime":3,"endTime":4},"skipType":"recap"},
          {"interval":{"startTime":5,"endTime":6},"skipType":"mixed-ed"},
          {"interval":{"startTime":7,"endTime":8},"skipType":"something-new"}
        ]}
        """
        let segments = SkipIntroClient.segments(
            from: try decode(payload, as: SkipIntroClient.AniSkipResponse.self)
        )
        XCTAssertEqual(segments.map(\.kind), [.intro, .recap, .outro, .mixed])
    }

    func testAniSkipMissOrEmptyIntervalYieldsNothing() throws {
        let miss = """
        {"found":false,"results":null,"message":"No skip times found","statusCode":404}
        """
        XCTAssertTrue(SkipIntroClient.segments(
            from: try decode(miss, as: SkipIntroClient.AniSkipResponse.self)
        ).isEmpty)

        // A zero-length or inverted interval is not a segment worth offering to skip.
        let degenerate = """
        {"found":true,"results":[{"interval":{"startTime":90,"endTime":90},"skipType":"op"}]}
        """
        XCTAssertTrue(SkipIntroClient.segments(
            from: try decode(degenerate, as: SkipIntroClient.AniSkipResponse.self)
        ).isEmpty)
    }

    // MARK: ARM season mapping

    /// Captured from `arm.haglund.dev/api/v2/imdb?id=tt2560140` — one IMDb entry, one MAL title
    /// per season. Taking element zero would give season one's opening for every season.
    private let attackOnTitanSeasons: [Int?] = [16498, nil, 25777, 35760, 38524]

    func testSeasonPicksItsOwnTitle() {
        XCTAssertEqual(SkipIntroClient.malId(fromSeasonEntries: attackOnTitanSeasons, season: 1), 16498)
        XCTAssertEqual(SkipIntroClient.malId(fromSeasonEntries: attackOnTitanSeasons, season: 3), 25777)
        XCTAssertEqual(SkipIntroClient.malId(fromSeasonEntries: attackOnTitanSeasons, season: 4), 35760)
    }

    /// A null in the slot, or a season past the end of the list. The first known title is a
    /// better answer than none — AniSkip simply reports nothing if it does not fit.
    func testSeasonWithoutItsOwnTitleFallsBackToTheFirst() {
        XCTAssertEqual(SkipIntroClient.malId(fromSeasonEntries: attackOnTitanSeasons, season: 2), 16498)
        XCTAssertEqual(SkipIntroClient.malId(fromSeasonEntries: attackOnTitanSeasons, season: 9), 16498)
    }

    func testNoMappingAtAllReturnsNothing() {
        XCTAssertNil(SkipIntroClient.malId(fromSeasonEntries: [], season: 1))
        XCTAssertNil(SkipIntroClient.malId(fromSeasonEntries: [nil, nil], season: 1))
    }

    // MARK: IntroDB

    /// IntroDB's endpoint is public — `api.introdb.app`, documented by its own OpenAPI file —
    /// which is why it is a default rather than something the viewer has to be asked for.
    func testIntroDbDefaultEndpointIsSet() {
        XCTAssertFalse(SkipIntroClient.introDbDefaultBaseURL.isEmpty)
        XCTAssertTrue(SkipIntroClient.introDbDefaultBaseURL.hasPrefix("https://"))
    }

    // MARK: Merging providers

    private let aniSkipResult = [
        SkipSegment(kind: .intro, start: 128, end: 218),
        SkipSegment(kind: .outro, start: 1342, end: 1430)
    ]

    func testHigherPriorityProviderWinsACategory() {
        let introDb = [SkipSegment(kind: .intro, start: 100, end: 200)]
        let merged = SkipIntroClient.merge([aniSkipResult, [], introDb])

        XCTAssertEqual(merged.filter { $0.kind == .intro }.map(\.start), [128],
                       "AniSkip's intro should win over IntroDB's")
    }

    /// The defect this replaces, in one test. IntroDB knows the intro for *One Piece* and not the
    /// outro; taking the first non-empty provider and stopping meant AniSkip was never asked, and
    /// the outro it holds never reached the player.
    func testACategoryMissingFromTheFirstProviderIsFilledByTheNext() {
        let introDb = [SkipSegment(kind: .intro, start: 0, end: 111)]
        let aniSkip = [SkipSegment(kind: .outro, start: 1200, end: 1300)]

        let merged = SkipIntroClient.merge([aniSkip, [], introDb])

        XCTAssertEqual(merged.map(\.kind), [.intro, .outro])
        XCTAssertEqual(merged.map(\.start), [0, 1200])
    }

    func testMergeKeepsOneSegmentPerCategoryAndOrdersThemChronologically() {
        let first = [
            SkipSegment(kind: .outro, start: 1342, end: 1430),
            SkipSegment(kind: .recap, start: 30, end: 60),
            SkipSegment(kind: .intro, start: 128, end: 218)
        ]
        let merged = SkipIntroClient.merge([first, first])

        XCTAssertEqual(merged.map(\.kind), [.recap, .intro, .outro])
    }

    /// `.mixed` is the fallback for a skip type nobody recognises. Upstream drops it rather than
    /// filing it under a category, and so does this — an unknown type has nothing to promise.
    func testUnrecognisedSegmentsAreDropped() {
        let merged = SkipIntroClient.merge([[SkipSegment(kind: .mixed, start: 1, end: 2)]])
        XCTAssertTrue(merged.isEmpty)
    }

    func testMergingNothingYieldsNothing() {
        XCTAssertTrue(SkipIntroClient.merge([]).isEmpty)
        XCTAssertTrue(SkipIntroClient.merge([[], [], []]).isEmpty)
    }

    // MARK: Anime-Skip

    /// Built to the schema in upstream's `SkipIntroApi.kt` rather than captured live — the service
    /// refuses every request without a client id, which is the whole reason it is optional. The
    /// shape is what upstream decodes, so a drift here is still worth catching.
    private let animeSkipPayload = """
    {"data":{"findEpisodesByShowId":[
      {"season":"1","number":"2","timestamps":[
        {"at":90.5,"type":{"name":"Intro"}},
        {"at":180.25,"type":{"name":"Canon"}},
        {"at":1290,"type":{"name":"Credits"}}
      ]},
      {"season":"1","number":"3","timestamps":[{"at":5,"type":{"name":"Recap"}}]}
    ]}}
    """

    /// Anime-Skip publishes points in time, not ranges: a segment runs until the next timestamp.
    func testAnimeSkipTimestampsBecomeRanges() throws {
        let response = try decode(animeSkipPayload, as: SkipIntroClient.AnimeSkipResponse.self)
        let segments = SkipIntroClient.segments(
            from: response.data?.findEpisodesByShowId ?? [],
            episode: 2, season: 1, episodeLength: 1440
        )

        XCTAssertEqual(segments.count, 2, "Canon is not a skippable section and must be dropped")
        XCTAssertEqual(segments[0].kind, .intro)
        XCTAssertEqual(segments[0].start, 90.5, accuracy: 0.001)
        XCTAssertEqual(segments[0].end, 180.25, accuracy: 0.001,
                       "an intro ends where the next timestamp begins")
        XCTAssertEqual(segments[1].kind, .outro)
    }

    /// The last timestamp has no successor. Upstream closes it with `Double.MAX_VALUE`, which
    /// would offer to skip the entire rest of the file; the episode's duration is the real end.
    func testFinalTimestampIsClosedWithTheEpisodeDuration() throws {
        let response = try decode(animeSkipPayload, as: SkipIntroClient.AnimeSkipResponse.self)
        let segments = SkipIntroClient.segments(
            from: response.data?.findEpisodesByShowId ?? [],
            episode: 2, season: 1, episodeLength: 1440
        )
        XCTAssertEqual(segments.last?.end, 1440)
    }

    func testAnimeSkipPicksTheRequestedEpisode() throws {
        let response = try decode(animeSkipPayload, as: SkipIntroClient.AnimeSkipResponse.self)
        let episodes = response.data?.findEpisodesByShowId ?? []

        XCTAssertEqual(
            SkipIntroClient.segments(from: episodes, episode: 3, season: 1, episodeLength: 1440)
                .map(\.kind),
            [.recap]
        )
        XCTAssertTrue(
            SkipIntroClient.segments(from: episodes, episode: 9, season: 1, episodeLength: 1440).isEmpty
        )
        // A season filter that does not match must not fall through to another season's episode.
        XCTAssertTrue(
            SkipIntroClient.segments(from: episodes, episode: 2, season: 4, episodeLength: 1440).isEmpty
        )
        // `nil` means "do not filter", which is how a season-specific show id is queried.
        XCTAssertFalse(
            SkipIntroClient.segments(from: episodes, episode: 2, season: nil, episodeLength: 1440).isEmpty
        )
    }

    /// Anime-Skip names its sections in prose, with the qualifiers AniSkip puts in its skip type.
    func testAnimeSkipTypeNames() {
        XCTAssertEqual(SkipIntroClient.animeSkipKind("Intro"), .intro)
        XCTAssertEqual(SkipIntroClient.animeSkipKind("New Intro"), .intro)
        XCTAssertEqual(SkipIntroClient.animeSkipKind("Mixed Intro"), .intro)
        XCTAssertEqual(SkipIntroClient.animeSkipKind("Credits"), .outro)
        XCTAssertEqual(SkipIntroClient.animeSkipKind("New Credits"), .outro)
        XCTAssertEqual(SkipIntroClient.animeSkipKind("Mixed Credits"), .outro)
        XCTAssertEqual(SkipIntroClient.animeSkipKind("Recap"), .recap)
        XCTAssertNil(SkipIntroClient.animeSkipKind("Canon"))
        XCTAssertNil(SkipIntroClient.animeSkipKind("Preview"))
    }

    // MARK: AniList season mapping

    /// Anime-Skip is keyed by AniList, indexed the same way AniSkip's MAL ids are.
    func testAnilistSeasonMappingMatchesTheMalOne() {
        let entries: [Int?] = [16498, nil, 20958]
        XCTAssertEqual(SkipIntroClient.anilistId(fromSeasonEntries: entries, season: 3), 20958)
        XCTAssertEqual(SkipIntroClient.anilistId(fromSeasonEntries: entries, season: 2), 16498)
        XCTAssertNil(SkipIntroClient.anilistId(fromSeasonEntries: [], season: 1))
    }
}
