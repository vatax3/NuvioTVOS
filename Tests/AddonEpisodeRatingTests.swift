import XCTest
@testable import Nuvio

/// `videos[].rating`, the per-episode score an addon publishes itself.
///
/// A comment in `Models.swift` used to assert that no Stremio addon publishes one. Upstream's
/// issue #3129 and commit `855593a` say otherwise, and this is the one episode rating that can
/// be had from public source at all — theirs comes from a service whose base URL is a build
/// secret that ships blank.
final class AddonEpisodeRatingTests: XCTestCase {
    private func video(fromRatingJSON rating: String) throws -> Video {
        let json = """
        {"id":"tt0903747:1:1","season":1,"episode":1,"name":"Pilot","rating":\(rating)}
        """
        let dto = try JSONDecoder().decode(VideoDTO.self, from: Data(json.utf8))
        return try XCTUnwrap(StremioMapper.video(from: dto))
    }

    /// Upstream parses the field with `toDoubleOrNull`, so a string is the shape actually seen
    /// in the wild.
    func testAStringRatingIsRead() throws {
        XCTAssertEqual(try video(fromRatingJSON: "\"8.7\"").addonRating, 8.7)
    }

    /// Nothing in the protocol says it must be a string, and some addons send a number.
    func testANumericRatingIsRead() throws {
        XCTAssertEqual(try video(fromRatingJSON: "9.1").addonRating, 9.1)
        XCTAssertEqual(try video(fromRatingJSON: "7").addonRating, 7)
    }

    /// Zero is how an addon says "no score", not a score of zero — a nought-out-of-ten star
    /// beside every episode is worse than no star.
    func testZeroAndNonsenseAreNoScore() throws {
        XCTAssertNil(try video(fromRatingJSON: "0").addonRating)
        XCTAssertNil(try video(fromRatingJSON: "\"0.0\"").addonRating)
        XCTAssertNil(try video(fromRatingJSON: "\"N/A\"").addonRating)
        XCTAssertNil(try video(fromRatingJSON: "null").addonRating)
    }

    func testAVideoWithoutTheFieldStillDecodes() throws {
        let json = #"{"id":"tt0903747:1:2","season":1,"episode":2}"#
        let dto = try JSONDecoder().decode(VideoDTO.self, from: Data(json.utf8))

        XCTAssertNil(try XCTUnwrap(StremioMapper.video(from: dto)).addonRating)
    }

    /// The addon wins over TMDB: it is the source the viewer chose, and it is describing this
    /// exact episode rather than one TMDB matched by id.
    func testTheAddonScoreWinsOverTmdb() {
        var video = Video(id: "x", name: nil, title: nil, released: nil, thumbnail: nil,
                          season: 1, episode: 1, number: nil, overview: nil, description: nil,
                          runtime: nil, available: nil)
        video.tmdbRating = 6.4
        XCTAssertEqual(video.displayRating, 6.4, "TMDB should still show when it is all there is")

        video.addonRating = 8.8
        XCTAssertEqual(video.displayRating, 8.8)
    }

    func testNoSourceMeansNoStar() {
        let video = Video(id: "x", name: nil, title: nil, released: nil, thumbnail: nil,
                          season: 1, episode: 1, number: nil, overview: nil, description: nil,
                          runtime: nil, available: nil)

        XCTAssertNil(video.displayRating)
    }
}

/// The tolerant double the field is decoded through.
final class FlexibleDoubleTests: XCTestCase {
    private func decode(_ json: String) throws -> Double? {
        try JSONDecoder().decode(FlexibleDouble.self, from: Data(json.utf8)).value
    }

    func testItReadsBothShapes() throws {
        XCTAssertEqual(try decode("8.7"), 8.7)
        XCTAssertEqual(try decode("\"8.7\""), 8.7)
        XCTAssertEqual(try decode("\" 8.7 \""), 8.7, "addons pad their strings")
    }

    func testItDeclinesRatherThanThrowing() throws {
        XCTAssertNil(try decode("null"))
        XCTAssertNil(try decode("\"\""))
        XCTAssertNil(try decode("\"tbd\""))
        XCTAssertNil(try decode("[]"))
    }
}
