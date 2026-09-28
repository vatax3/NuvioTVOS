import XCTest
@testable import Nuvio

/// MDBList as a third tracking account.
///
/// The network is not exercised here; what is, is every decision made *about* a response — which
/// id a title is opened under, which id a write is addressed by, and when a session is due for
/// renewal. Those are the three places this integration can be silently wrong: the first shows an
/// empty screen, the second writes to the wrong title, and the third reports success and does
/// nothing at all.
final class MDBListTests: XCTestCase {
    // MARK: Which id a title is opened under

    func testImdbIsPreferredBecauseAlmostEveryAddonDeclaresIt() {
        let id = MDBListClient.contentId(from: ["imdb": "tt0903747", "tmdb": "1396"])

        XCTAssertEqual(id, "tt0903747")
    }

    func testANamespacedIdIsUsedWhenThereIsNoImdbOne() {
        XCTAssertEqual(MDBListClient.contentId(from: ["tmdb": "1396"]), "tmdb:1396")
        XCTAssertEqual(MDBListClient.contentId(from: ["tvdb": "81189"]), "tvdb:81189")
    }

    /// MDBList publishes a Trakt id where Simkl never does. It is a real address — some addons
    /// declare `trakt:` — so it is kept, but behind the two namespaces more of them answer.
    func testTheTraktIdIsTheLastResortRatherThanUnused() {
        XCTAssertEqual(MDBListClient.contentId(from: ["trakt": "1390"]), "trakt:1390")
        XCTAssertEqual(
            MDBListClient.contentId(from: ["tvdb": "81189", "trakt": "1390"]), "tvdb:81189"
        )
    }

    /// A title MDBList knows only by its own id cannot be opened by any addon, so it must not
    /// produce a content id at all — a row that opens to "nothing found" is worse than no row.
    func testMdbListsOwnIdIsNeverAContentId() {
        XCTAssertNil(MDBListClient.contentId(from: ["mdblist": "551"]))
        XCTAssertNil(MDBListClient.contentId(from: [:]))
    }

    // MARK: Which type a list row is

    /// The defect this rule was extracted from. `unified=false` answers
    /// `{movies: […], shows: […]}` with no per-row type, so reading `mediatype` off each row and
    /// merging the two groups dropped every row on the watchlist.
    func testTheGroupKeyTypesARowThatCarriesNoTypeOfItsOwn() {
        XCTAssertEqual(MDBListClient.resolvedType(row: nil, group: "movie", list: nil), .movie)
        XCTAssertEqual(MDBListClient.resolvedType(row: nil, group: "show", list: nil), .series)
    }

    func testTheRowsOwnTypeOutranksTheGroupAndTheList() {
        XCTAssertEqual(
            MDBListClient.resolvedType(row: "movie", group: "show", list: "show"), .movie
        )
    }

    /// A single-type static list is a statement about everything in it, and it is the last
    /// resort — a property of the list rather than of this row.
    func testASingleTypeListTypesItsRowsWhenNothingElseDoes() {
        XCTAssertEqual(MDBListClient.resolvedType(row: nil, group: nil, list: "show"), .series)
    }

    /// Guessing here opens a series as a film, asks the wrong addon and finds nothing. No answer
    /// is the better answer.
    func testARowWithNoTypeAnywhereIsNotGuessedAt() {
        XCTAssertNil(MDBListClient.resolvedType(row: nil, group: nil, list: nil))
        XCTAssertNil(MDBListClient.resolvedType(row: "  ", group: nil, list: nil))
    }

    // MARK: Which id a write is addressed by

    func testAWriteIsAddressedByImdbWhenThereIsOne() {
        let ids = MDBListClient.requestIds(contentId: "tt0903747", imdbId: nil)

        XCTAssertEqual(ids?["imdb"], .string("tt0903747"))
    }

    /// An episode's Stremio id is `tt0903747:1:1`, and the show is what a write addresses — the
    /// season and episode ride alongside. Sending the whole thing as an IMDb id addresses nothing.
    func testAnEpisodeIdIsTrimmedToItsShow() {
        let ids = MDBListClient.requestIds(contentId: "tt0903747:1:1", imdbId: nil)

        XCTAssertEqual(ids?["imdb"], .string("tt0903747"))
    }

    func testANamespacedIdIsSentAsANumber() {
        let ids = MDBListClient.requestIds(contentId: "tmdb:1396", imdbId: nil)

        XCTAssertEqual(ids?["tmdb"], .number(1396))
    }

    /// The explicit IMDb id from the metadata wins: a title listed under `kitsu:` may still carry
    /// one, and it is the namespace MDBList matches best.
    func testAnExplicitImdbIdOutranksTheKey() {
        let ids = MDBListClient.requestIds(contentId: "kitsu:7442", imdbId: "tt2560140")

        XCTAssertEqual(ids?["imdb"], .string("tt2560140"))
    }

    /// Kitsu, MAL and AniList are namespaces MDBList does not index. A write addressed by one
    /// would land on whatever happened to share the number, so there is no write to make.
    func testANamespaceMdbListDoesNotIndexYieldsNoWrite() {
        XCTAssertNil(MDBListClient.requestIds(contentId: "kitsu:7442", imdbId: nil))
        XCTAssertNil(MDBListClient.requestIds(contentId: "anilist:101922", imdbId: nil))
    }

    // MARK: The verification URL

    /// It is put on screen for someone to type into a phone, so a substituted host would be a
    /// working link to somewhere else.
    func testOnlyAnHttpsMdbListUrlIsAccepted() {
        XCTAssertEqual(
            MDBListClient.verificationURL("https://mdblist.com/device"),
            "https://mdblist.com/device"
        )
        XCTAssertNil(MDBListClient.verificationURL("http://mdblist.com/device"))
        XCTAssertNil(MDBListClient.verificationURL("https://mdblist.com.example.test/device"))
        XCTAssertNil(MDBListClient.verificationURL("https://user:pass@mdblist.com/device"))
        XCTAssertNil(MDBListClient.verificationURL(nil))
    }

    // MARK: Tokens

    func testATokenWithoutTheWriteScopeIsRefused() {
        let body = #"{"access_token":"a","refresh_token":"r","token_type":"Bearer","scope":"read"}"#

        XCTAssertNil(MDBListClient.tokens(from: Data(body.utf8)))
    }

    func testATokenWithTheWriteScopeIsAccepted() {
        let body = #"{"access_token":"a","refresh_token":"r","token_type":"Bearer","scope":"read write","expires_in":3600}"#

        let tokens = MDBListClient.tokens(from: Data(body.utf8))

        XCTAssertEqual(tokens?.accessToken, "a")
        XCTAssertEqual(tokens?.expiresIn, 3600)
    }

    /// A refresh may answer without reissuing the refresh token. Losing it here would sign the
    /// viewer out at the next expiry, with nothing to say why.
    func testARefreshWithoutANewRefreshTokenKeepsTheOldOne() {
        let body = #"{"access_token":"new","token_type":"Bearer","expires_in":3600}"#

        let tokens = MDBListClient.tokens(from: Data(body.utf8), fallbackRefreshToken: "original")

        XCTAssertEqual(tokens?.accessToken, "new")
        XCTAssertEqual(tokens?.refreshToken, "original")
    }

    func testAResponseThatIsNotABearerTokenIsRefused() {
        let body = #"{"access_token":"a","refresh_token":"r","token_type":"mac"}"#

        XCTAssertNil(MDBListClient.tokens(from: Data(body.utf8)))
    }

    func testThePollingErrorCodeIsRead() {
        XCTAssertEqual(
            MDBListClient.errorCode(in: Data(#"{"error":"slow_down"}"#.utf8)), "slow_down"
        )
        XCTAssertNil(MDBListClient.errorCode(in: Data(#"{}"#.utf8)))
    }

    // MARK: When the session is renewed

    func testASessionIsRenewedBeforeItExpiresRatherThanAfter() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Sixty seconds left, inside the two-minute margin.
        XCTAssertTrue(MDBListSession.needsRefresh(expiry: 1_000_060, now: now))
        // Ten minutes left.
        XCTAssertFalse(MDBListSession.needsRefresh(expiry: 1_000_600, now: now))
    }

    /// Zero is a session stored before the expiry was recorded. Treating it as expired would sign
    /// out an account that is working.
    func testAnUnknownExpiryIsNotTreatedAsExpired() {
        XCTAssertFalse(
            MDBListSession.needsRefresh(expiry: 0, now: Date(timeIntervalSince1970: 1_000_000))
        )
    }

    // MARK: How it fits the rest of the app

    /// Removing a title from MDBList is a list operation. Its watched history lives behind a
    /// different endpoint that this call does not reach, so there is nothing to warn about —
    /// the same answer as Trakt and the opposite of Simkl.
    func testRemovingFromMdbListDestroysNothingWorthWarningAbout() {
        XCTAssertFalse(TrackingRemovalImpact.requiresConfirmation(removingFrom: .mdblist))
        XCTAssertTrue(TrackingRemovalImpact.requiresConfirmation(removingFrom: .simkl))
    }

    /// A source preference is a request, not a fact: choosing MDBList and then signing out has to
    /// fall back to this device rather than render an empty library.
    func testChoosingMdbListWithoutAnAccountFallsBackToThisDevice() {
        XCTAssertEqual(
            TrackingSources.effectiveLibrarySourceMode(.mdblist, connected: []), .local
        )
        XCTAssertEqual(
            TrackingSources.effectiveLibrarySourceMode(.mdblist, connected: [.mdblist]), .mdblist
        )
    }

    func testMdbListIsOfferedOnlyOnceItIsConnected() {
        XCTAssertFalse(
            TrackingSources.availableWatchProgressSources(connected: [.trakt]).contains(.mdblist)
        )
        XCTAssertTrue(
            TrackingSources.availableWatchProgressSources(connected: [.mdblist]).contains(.mdblist)
        )
    }

    // MARK: Resume points

    func testAPlaybackRowBecomesAResumePoint() {
        let entry = MDBListClient.PlaybackEntry(
            contentId: "tt0903747",
            contentType: .series,
            season: 2,
            episode: 4,
            progressPercent: 42,
            runtimeMinutes: 47,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            playbackId: 91
        )

        let progress = RemoteProgressService.progress(from: entry)

        XCTAssertEqual(progress?.videoId, "tt0903747:2:4")
        XCTAssertEqual(progress?.contentId, "tt0903747")
        XCTAssertEqual(progress?.fraction ?? 0, 0.42, accuracy: 0.0001)
    }

    /// A row at zero is not something to resume. Adopting it would put a title on the rail that
    /// the viewer has never started.
    func testARowAtZeroIsNotAResumePoint() {
        let entry = MDBListClient.PlaybackEntry(
            contentId: "tt1375666", contentType: .movie, season: nil, episode: nil,
            progressPercent: 0, runtimeMinutes: 148, updatedAt: nil, playbackId: 1
        )

        XCTAssertNil(RemoteProgressService.progress(from: entry))
    }
}
