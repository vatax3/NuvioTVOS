import XCTest
@testable import Nuvio

/// Keeping the next episode in the release the viewer was already watching.
///
/// `bingeGroup` is the right answer when the addon publishes one, and the problem is how often it
/// does not: a debrid result is a file on somebody's cache and most addons serving them send no
/// `bingeGroup` at all. The chain then fell through to the ordinary ranking, and the next episode
/// could arrive as a different encode with different audio and differently-timed subtitles, in the
/// middle of a season.
///
/// Upstream's answer in 1.1.0-beta.7 is the filename, because a release names its episodes to a
/// pattern. The tests here are mostly about the two rules that keep it from guessing: the pattern
/// must describe the episode that was *playing*, and a name it cannot read produces no match.
final class NextEpisodeSourceMatchTests: XCTestCase {
    private func stream(
        _ name: String, bingeGroup: String? = nil, filename: String? = nil, url: String? = nil
    ) -> Nuvio.Stream {
        Nuvio.Stream(
            name: name, title: nil, description: nil,
            url: url ?? "https://example.test/\(name).mkv",
            ytId: nil, infoHash: nil, fileIdx: nil, externalUrl: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: bingeGroup, filename: filename),
            addonName: "Test addon", addonLogo: nil, sources: nil, quality: nil
        )
    }

    // MARK: The addon's own marker still wins

    func testTheBingeGroupIsPreferredOverTheFilename() {
        let streams = [
            stream("other", filename: "Show.S01E04.1080p.GROUP.mkv"),
            stream("grouped", bingeGroup: "torrentio|1080p|WEB-DL")
        ]

        let match = NextEpisodeSourceMatch.find(
            in: streams,
            release: .init(
                bingeGroup: "torrentio|1080p|WEB-DL",
                filename: "Show.S01E03.1080p.GROUP.mkv",
                season: 1,
                episode: 3
            ),
            season: 1,
            episode: 4
        )

        XCTAssertEqual(match?.stream.displayName, "grouped")
        XCTAssertEqual(match?.reason, .bingeGroup)
    }

    /// Exact equality: matching on anything looser would be guessing at what the addon means by
    /// "the same".
    func testABingeGroupMatchesExactlyOrNotAtAll() {
        let streams = [stream("a", bingeGroup: "torrentio|1080p|WEB-DL")]

        XCTAssertNotNil(
            NextEpisodeSourceMatch.bingeGroupMatch(in: streams, group: "torrentio|1080p|WEB-DL")
        )
        XCTAssertNil(NextEpisodeSourceMatch.bingeGroupMatch(in: streams, group: "torrentio|1080p"))
        XCTAssertNil(NextEpisodeSourceMatch.bingeGroupMatch(in: streams, group: "   "))
    }

    // MARK: The filename, when there is no marker

    /// The case the whole thing exists for: no `bingeGroup` anywhere, and the right file is the
    /// one whose name is the played one with the episode advanced.
    func testTheNextEpisodeOfTheSameReleaseIsFoundByName() {
        let streams = [
            stream("wrong-release", filename: "Show.S01E04.2160p.OTHER.mkv"),
            stream("right-release", filename: "Show.S01E04.1080p.GROUP.mkv"),
            stream("wrong-episode", filename: "Show.S01E05.1080p.GROUP.mkv")
        ]

        let match = NextEpisodeSourceMatch.find(
            in: streams,
            release: .init(filename: "Show.S01E03.1080p.GROUP.mkv", season: 1, episode: 3),
            season: 1,
            episode: 4
        )

        XCTAssertEqual(match?.stream.displayName, "right-release")
        XCTAssertEqual(match?.reason, .filename)
    }

    /// Zero-padding is part of how a release names its files, so a rebuilt name that differs in
    /// padding matches nothing. Both widths have to come out as the original wrote them.
    func testPaddingIsPreserved() {
        XCTAssertEqual(
            NextEpisodeSourceMatch.nextFilename(
                from: "Show.S01E03.mkv", currentSeason: 1, currentEpisode: 3,
                nextSeason: 1, nextEpisode: 4
            ),
            "Show.S01E04.mkv"
        )
        XCTAssertEqual(
            NextEpisodeSourceMatch.nextFilename(
                from: "Show.S1E3.mkv", currentSeason: 1, currentEpisode: 3,
                nextSeason: 1, nextEpisode: 4
            ),
            "Show.S1E4.mkv"
        )
    }

    /// Padding is a minimum, not a truncation: episode 10 of a season written `E3` is `E10`.
    func testANumberWiderThanItsPaddingIsNotTruncated() {
        XCTAssertEqual(
            NextEpisodeSourceMatch.nextFilename(
                from: "Show.S1E9.mkv", currentSeason: 1, currentEpisode: 9,
                nextSeason: 1, nextEpisode: 10
            ),
            "Show.S1E10.mkv"
        )
    }

    func testLetterCaseIsPreserved() {
        XCTAssertEqual(
            NextEpisodeSourceMatch.nextFilename(
                from: "show.s01e03.mkv", currentSeason: 1, currentEpisode: 3,
                nextSeason: 1, nextEpisode: 4
            ),
            "show.s01e04.mkv"
        )
    }

    func testTheSeasonCrossesToo() {
        XCTAssertEqual(
            NextEpisodeSourceMatch.nextFilename(
                from: "Show.S01E10.mkv", currentSeason: 1, currentEpisode: 10,
                nextSeason: 2, nextEpisode: 1
            ),
            "Show.S02E01.mkv"
        )
    }

    // MARK: The other two patterns

    func testTheCrossPatternIsRecognised() {
        XCTAssertEqual(
            NextEpisodeSourceMatch.nextFilename(
                from: "Show 1x03 [GROUP].mkv", currentSeason: 1, currentEpisode: 3,
                nextSeason: 1, nextEpisode: 4
            ),
            "Show 1x04 [GROUP].mkv"
        )
    }

    func testAnEpisodeOnlyNameIsRecognised() {
        for (name, expected) in [
            ("Show - E03.mkv", "Show - E04.mkv"),
            ("Show EP03.mkv", "Show EP04.mkv"),
            ("Show Ep.03.mkv", "Show Ep.04.mkv")
        ] {
            XCTAssertEqual(
                NextEpisodeSourceMatch.nextFilename(
                    from: name, currentSeason: 1, currentEpisode: 3,
                    nextSeason: 1, nextEpisode: 4
                ),
                expected,
                "\(name) should advance"
            )
        }
    }

    /// A name with no season in it cannot express a season change, so crossing one is refused
    /// rather than producing a file from the wrong season.
    func testAnEpisodeOnlyNameRefusesASeasonChange() {
        XCTAssertNil(
            NextEpisodeSourceMatch.nextFilename(
                from: "Show - E10.mkv", currentSeason: 1, currentEpisode: 10,
                nextSeason: 2, nextEpisode: 1
            )
        )
    }

    // MARK: What must not be rewritten

    /// **The rule that makes this safe.** The pattern has to describe the episode that was
    /// playing; otherwise the first number-shaped thing in the name gets incremented. Here the
    /// name says S01E03 and S02E07 was playing, so there is nothing to advance.
    func testAPatternThatDoesNotDescribeTheCurrentEpisodeIsNotRewritten() {
        XCTAssertNil(
            NextEpisodeSourceMatch.nextFilename(
                from: "Show.S01E03.mkv", currentSeason: 2, currentEpisode: 7,
                nextSeason: 2, nextEpisode: 8
            )
        )
    }

    /// A film, or anything else with no episode pattern at all. No match, rather than a name with
    /// a year or a resolution quietly incremented.
    func testANameWithNoEpisodePatternProducesNothing() {
        for name in [
            "Some.Film.2019.2160p.HDR.mkv",
            "Show.Complete.Season.1080p.mkv",
            "video.mkv"
        ] {
            XCTAssertNil(
                NextEpisodeSourceMatch.nextFilename(
                    from: name, currentSeason: 1, currentEpisode: 3,
                    nextSeason: 1, nextEpisode: 4
                ),
                "\(name) must not be rewritten"
            )
        }
    }

    /// And the year is the specific trap: `2019` is four digits beside a `.`, which is what the
    /// episode-only pattern looks for — so it must not match one.
    func testAYearIsNotReadAsAnEpisodeNumber() {
        XCTAssertNil(
            NextEpisodeSourceMatch.nextFilename(
                from: "Show.2019.1080p.mkv", currentSeason: nil, currentEpisode: 2_019,
                nextSeason: nil, nextEpisode: 2_020
            )
        )
    }

    /// Nothing remembered, nothing to match. The ordinary ranking decides, which is the behaviour
    /// a viewer who picked a source by hand expects.
    func testAnEmptyReleaseMatchesNothing() {
        let streams = [stream("a", filename: "Show.S01E04.mkv")]
        let empty = NextEpisodeSourceMatch.Release()

        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(
            NextEpisodeSourceMatch.find(in: streams, release: empty, season: 1, episode: 4)
        )
    }

    // MARK: Reading the name off a URL

    /// Most addons send no `filename` hint, and a debrid link almost always ends in the real one.
    /// Without this the filename half of the match would be unreachable for exactly the sources
    /// that need it most.
    func testAFilenameIsReadFromADebridUrl() {
        XCTAssertEqual(
            NextEpisodeSourceMatch.filenameFromURL(
                "https://cdn.example.test/dl/abc123/Show.S01E04.1080p.GROUP.mkv"
            ),
            "Show.S01E04.1080p.GROUP.mkv"
        )
    }

    func testAQueryStringIsNotPartOfTheName() {
        XCTAssertEqual(
            NextEpisodeSourceMatch.filenameFromURL(
                "https://cdn.example.test/Show.S01E04.mkv?token=deadbeef"
            ),
            "Show.S01E04.mkv"
        )
    }

    func testPercentEncodingIsUndone() {
        XCTAssertEqual(
            NextEpisodeSourceMatch.filenameFromURL("https://cdn.example.test/Show%20S01E04.mkv"),
            "Show S01E04.mkv"
        )
    }

    /// Requiring an extension is what stops an addon endpoint being read as a filename — and
    /// `…/stream/12345` would otherwise be a name whose digits the matcher might advance.
    func testAnEndpointIsNotAFilename() {
        XCTAssertNil(NextEpisodeSourceMatch.filenameFromURL("https://addon.test/stream/12345"))
        XCTAssertNil(NextEpisodeSourceMatch.filenameFromURL("https://addon.test/stream/"))
    }

    /// The hint wins when there is one: the addon knows the name of the file inside the torrent,
    /// which the URL need not carry at all.
    func testTheAddonHintIsPreferredOverTheUrl() {
        let hinted = stream(
            "a", filename: "Show.S01E04.mkv", url: "https://cdn.test/opaque-id.mkv"
        )

        XCTAssertEqual(NextEpisodeSourceMatch.filename(of: hinted), "Show.S01E04.mkv")
    }

    /// End to end on the shape a debrid chain actually has: no hints, no groups, just URLs.
    func testADebridChainMatchesOnUrlsAlone() {
        let streams = [
            stream("other", url: "https://cdn.test/dl/x/Show.S01E04.2160p.OTHER.mkv"),
            stream("same", url: "https://cdn.test/dl/y/Show.S01E04.1080p.GROUP.mkv")
        ]

        let match = NextEpisodeSourceMatch.find(
            in: streams,
            release: .init(filename: "Show.S01E03.1080p.GROUP.mkv", season: 1, episode: 3),
            season: 1,
            episode: 4
        )

        XCTAssertEqual(match?.stream.displayName, "same")
    }
}
