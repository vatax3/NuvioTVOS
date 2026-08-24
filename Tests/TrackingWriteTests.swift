import XCTest
@testable import Nuvio

/// Covers the write path that did not exist: reads were routed to Trakt and Simkl, writes were
/// not, so a viewer whose library source was Trakt pressed Add and watched the title vanish —
/// written locally, read from a list it had never been sent to.
final class TrackingWriteRoutingTests: XCTestCase {
    func testLocalSourceWritesNowhereRemote() {
        XCTAssertNil(TrackingWrites.remoteDestination(librarySource: .local, connected: [.trakt]))
    }

    func testTraktSourceWritesToTrakt() {
        XCTAssertEqual(
            TrackingWrites.remoteDestination(librarySource: .trakt, connected: [.trakt]),
            .trakt
        )
    }

    /// A source pointing at an account nobody signed into is a request, not a fact — the same
    /// rule reads already follow. Attempting the write would fail on an empty token.
    func testSourcePointingAtADisconnectedAccountFallsBackToLocal() {
        XCTAssertNil(TrackingWrites.remoteDestination(librarySource: .trakt, connected: []))
        XCTAssertNil(TrackingWrites.remoteDestination(librarySource: .simkl, connected: [.trakt]))
    }
}

final class TraktWriteContractTests: XCTestCase {
    private var teardown: (() -> Void)?

    override func tearDown() {
        teardown?()
        teardown = nil
        super.tearDown()
    }

    private func stub(status: Int = 201, body: String) {
        teardown = StubURLProtocol.install { _ in
            .init(status: status, body: Data(body.utf8))
        }
    }

    func testAddingAFilmPostsToTheWatchlistWithItsImdbId() async throws {
        stub(body: #"{"added":{"movies":1}}"#)

        let outcome = try await TraktClient.shared.write(
            .watchlist, removing: false, imdbId: "tt0816692", type: .movie,
            clientId: "client", token: "secret"
        )

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/sync/watchlist")
        XCTAssertEqual(request.headers["trakt-api-key"], "client")
        XCTAssertEqual(request.headers["Authorization"], "Bearer secret")

        let movies = try XCTUnwrap(request.json?["movies"] as? [[String: Any]])
        XCTAssertEqual((movies.first?["ids"] as? [String: Any])?["imdb"] as? String, "tt0816692")
        XCTAssertNil(request.json?["shows"], "A film must not be sent as a show")
        XCTAssertEqual(outcome, TraktClient.SyncOutcome(accepted: 1, notFound: 0))
    }

    func testRemovingUsesTheRemoveTwinOfTheSamePath() async throws {
        stub(body: #"{"deleted":{"movies":1}}"#)

        _ = try await TraktClient.shared.write(
            .watchlist, removing: true, imdbId: "tt0816692", type: .movie,
            clientId: "c", token: "t"
        )

        XCTAssertEqual(StubURLProtocol.requests.first?.url.path, "/sync/watchlist/remove")
    }

    /// A season and episode narrow a history write to that episode. Sending the bare show would
    /// mark the entire series watched, which is the kind of mistake an account remembers.
    func testMarkingAnEpisodeWatchedNarrowsToThatEpisode() async throws {
        stub(body: #"{"added":{"episodes":1}}"#)

        _ = try await TraktClient.shared.write(
            .history, removing: false, imdbId: "tt0903747", type: .series,
            season: 4, episode: 7, clientId: "c", token: "t"
        )

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url.path, "/sync/history")
        let shows = try XCTUnwrap(request.json?["shows"] as? [[String: Any]])
        let seasons = try XCTUnwrap(shows.first?["seasons"] as? [[String: Any]])
        XCTAssertEqual(seasons.first?["number"] as? Int, 4)
        let episodes = try XCTUnwrap(seasons.first?["episodes"] as? [[String: Any]])
        XCTAssertEqual(episodes.first?["number"] as? Int, 7)
    }

    func testAddingAWholeSeriesSendsNoSeasons() async throws {
        stub(body: #"{"added":{"shows":1}}"#)

        _ = try await TraktClient.shared.write(
            .watchlist, removing: false, imdbId: "tt0903747", type: .series,
            clientId: "c", token: "t"
        )

        let shows = try XCTUnwrap(StubURLProtocol.requests.first?.json?["shows"] as? [[String: Any]])
        XCTAssertNil(shows.first?["seasons"])
    }

    /// The reason this returns an outcome instead of `Void`. Trakt answers 201 for a title it did
    /// not recognise and reports the miss in `not_found`, so a status-code check alone would call
    /// a write that changed nothing a success — which is the bug the whole path exists to stop.
    func testATitleTraktDoesNotRecogniseIsNotASuccess() async throws {
        stub(body: #"{"added":{"movies":0},"not_found":{"movies":[{"ids":{"imdb":"tt0000000"}}]}}"#)

        let outcome = try await TraktClient.shared.write(
            .watchlist, removing: false, imdbId: "tt0000000", type: .movie,
            clientId: "c", token: "t"
        )

        XCTAssertFalse(outcome.didChangeAnything)
        XCTAssertEqual(outcome.notFound, 1)
    }

    /// Asking Trakt to add something already on the list is the outcome the viewer wanted, so it
    /// must not be reported to them as a failure.
    func testAlreadyOnTheListCountsAsAccepted() async throws {
        stub(body: #"{"existing":{"movies":1}}"#)

        let outcome = try await TraktClient.shared.write(
            .watchlist, removing: false, imdbId: "tt0816692", type: .movie,
            clientId: "c", token: "t"
        )

        XCTAssertTrue(outcome.didChangeAnything)
        XCTAssertTrue(outcome.isClean)
    }

    func testAnHTTPFailureIsThrownRatherThanSwallowed() async {
        stub(status: 401, body: #"{"error":"invalid_grant"}"#)

        do {
            _ = try await TraktClient.shared.write(
                .watchlist, removing: false, imdbId: "tt0816692", type: .movie,
                clientId: "c", token: "expired"
            )
            XCTFail("A 401 must reach the caller so the viewer can be told")
        } catch {}
    }
}

final class SimklWriteContractTests: XCTestCase {
    private var teardown: (() -> Void)?

    override func tearDown() {
        teardown?()
        teardown = nil
        super.tearDown()
    }

    func testAddingSendsTheDestinationListAndEveryKnownId() async throws {
        teardown = StubURLProtocol.install { _ in .init(status: 200, body: Data("{}".utf8)) }

        try await SimklClient.shared.write(
            list: .planToWatch, removing: false,
            ids: ["imdb": "tt0903747", "mal": "437"],
            title: "Breaking Bad", year: 2008, type: .series,
            clientId: "c", token: "t"
        )

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url.path, "/sync/add-to-list")
        XCTAssertEqual(request.headers["simkl-api-key"], "c")
        let shows = try XCTUnwrap(request.json?["shows"] as? [[String: Any]])
        XCTAssertEqual(shows.first?["to"] as? String, "plantowatch")
        XCTAssertEqual(shows.first?["year"] as? Int, 2008)
        let ids = try XCTUnwrap(shows.first?["ids"] as? [String: Any])
        XCTAssertEqual(ids["mal"] as? String, "437", "A MAL-only anime must not be dropped")
    }

    func testMarkingWatchedGoesToHistoryWithNoDestinationList() async throws {
        teardown = StubURLProtocol.install { _ in .init(status: 200, body: Data("{}".utf8)) }

        try await SimklClient.shared.write(
            list: nil, removing: false, ids: ["imdb": "tt0816692"],
            title: nil, year: nil, type: .movie, clientId: "c", token: "t"
        )

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url.path, "/sync/history")
        let movies = try XCTUnwrap(request.json?["movies"] as? [[String: Any]])
        XCTAssertNil(movies.first?["to"])
    }

    /// Upstream's own detail, worth pinning: Simkl has no list-removal call, so removing from a
    /// list is removing from history.
    func testRemovingGoesToHistoryRemove() async throws {
        teardown = StubURLProtocol.install { _ in .init(status: 200, body: Data("{}".utf8)) }

        try await SimklClient.shared.write(
            list: nil, removing: true, ids: ["imdb": "tt0816692"],
            title: nil, year: nil, type: .movie, clientId: "c", token: "t"
        )

        XCTAssertEqual(StubURLProtocol.requests.first?.url.path, "/sync/history/remove")
    }
}

final class TrackingIdExtractionTests: XCTestCase {
    func testImdbIdIsUsedWhenPresent() {
        var preview = MetaPreview(id: "tmdb:329865", type: .movie, rawType: "movie", name: "Arrival")
        preview.imdbId = "tt2543164"

        XCTAssertEqual(preview.trackingIds["imdb"], "tt2543164")
        XCTAssertEqual(preview.trackingIds["tmdb"], "329865")
    }

    /// The case IMDb-only keying drops on the floor.
    func testAPrefixedIdBecomesItsOwnKey() {
        let preview = MetaPreview(id: "mal:437", type: .movie, rawType: "movie", name: "Perfect Blue")

        XCTAssertEqual(preview.trackingIds, ["mal": "437"])
    }

    func testABareTtIdIsAnImdbId() {
        let preview = MetaPreview(id: "tt0816692", type: .movie, rawType: "movie", name: "Interstellar")

        XCTAssertEqual(preview.trackingIds, ["imdb": "tt0816692"])
    }

    func testYearComesOutOfAReleaseRange() {
        var preview = MetaPreview(id: "tt0903747", type: .series, rawType: "series", name: "Breaking Bad")
        preview.releaseInfo = "2008–2013"

        XCTAssertEqual(preview.year, 2008)
    }
}
