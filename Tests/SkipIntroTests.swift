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
}
