import XCTest
@testable import Nuvio

/// Rules ported or fixed in the 1.1.0-beta.9 parity pass. Literal inputs where upstream's own
/// tests had them, so the port is pinned to their behaviour rather than to a reading of it.

// MARK: - Chapter titles

final class ChapterSkipSegmentsTests: XCTestCase {
    private func chapters(_ items: [(Double, String?)]) -> [PlayerChapter] {
        items.map { PlayerChapter(start: $0.0, title: $0.1) }
    }

    func testOpeningSpellingsAreOpenings() {
        for title in ["OP", "OP 2", "Opening", "Opening Credits", "op theme", "  Opening  "] {
            XCTAssertEqual(ChapterSkipSegments.category(of: title), .opening, title)
        }
    }

    func testAChapterThatOnlyMentionsAnOpeningIsNot() {
        XCTAssertNil(ChapterSkipSegments.category(of: "The Opening Scene"))
        XCTAssertNil(ChapterSkipSegments.category(of: "Chapter 1"))
        XCTAssertNil(ChapterSkipSegments.category(of: nil))
    }

    func testEndingsAndCredits() {
        for title in ["ED", "Ending", "ED 2", "Credits", "End Credits", "Closing Credits"] {
            XCTAssertEqual(ChapterSkipSegments.category(of: title), .ending, title)
        }
    }

    func testPostCreditsIsNeverTheCredits() {
        XCTAssertEqual(ChapterSkipSegments.category(of: "Post-Credits Scene"), .postCredits)
        XCTAssertEqual(ChapterSkipSegments.category(of: "Mid Credits"), .postCredits)
    }

    func testRecap() {
        XCTAssertEqual(ChapterSkipSegments.category(of: "Recap"), .recap)
        XCTAssertEqual(ChapterSkipSegments.category(of: "Previously on Severance"), .recap)
    }

    func testSpansRunToTheNextChapterAndTheLastToTheEnd() {
        let segments = ChapterSkipSegments.segments(
            from: chapters([(0, "Prologue"), (60, "Opening"), (150, "Part A"), (1_300, "Ending")]),
            duration: 1_420
        )
        XCTAssertEqual(segments, [
            SkipSegment(kind: .intro, start: 60, end: 150),
            SkipSegment(kind: .outro, start: 1_300, end: 1_420)
        ])
    }

    func testIntroIsIgnoredBesideAnOpening() {
        let segments = ChapterSkipSegments.segments(
            from: chapters([(0, "Intro"), (30, "Opening"), (120, "Episode")]), duration: 1_400
        )
        XCTAssertEqual(segments, [SkipSegment(kind: .intro, start: 30, end: 120)])
    }

    func testIntroAloneIsTheOpening() {
        let segments = ChapterSkipSegments.segments(
            from: chapters([(0, "Intro"), (40, "Episode")]), duration: 1_400
        )
        XCTAssertEqual(segments, [SkipSegment(kind: .intro, start: 0, end: 40)])
    }

    func testLengthLimits() {
        let tooShort = ChapterSkipSegments.segments(
            from: chapters([(0, "Opening"), (3, "Episode")]), duration: 1_400
        )
        let tooLong = ChapterSkipSegments.segments(
            from: chapters([(0, "Opening"), (400, "Episode")]), duration: 1_400
        )
        XCTAssertTrue(tooShort.isEmpty)
        XCTAssertTrue(tooLong.isEmpty)
    }

    func testNothingWithoutADuration() {
        XCTAssertTrue(ChapterSkipSegments.segments(
            from: chapters([(0, "Opening"), (90, "Episode")]), duration: 0
        ).isEmpty)
    }

    func testChaptersWinPerKindForAnEpisode() {
        let api = [SkipSegment(kind: .intro, start: 58, end: 148), SkipSegment(kind: .outro, start: 1_290, end: 1_400)]
        let fromChapters = [SkipSegment(kind: .intro, start: 60, end: 150)]
        XCTAssertEqual(
            ChapterSkipSegments.merge(api: api, chapters: fromChapters, isMovie: false),
            [SkipSegment(kind: .intro, start: 60, end: 150), SkipSegment(kind: .outro, start: 1_290, end: 1_400)]
        )
    }

    func testAFilmKeepsTheProvidersAnswer() {
        let api = [SkipSegment(kind: .movieCredits, start: 7_000, end: 7_300)]
        let fromChapters = [SkipSegment(kind: .outro, start: 6_900, end: 7_100)]
        XCTAssertEqual(ChapterSkipSegments.merge(api: api, chapters: fromChapters, isMovie: true), api)
        XCTAssertEqual(ChapterSkipSegments.merge(api: [], chapters: fromChapters, isMovie: true), fromChapters)
    }
}

// MARK: - Stream languages

final class StreamLanguageDetectionTests: XCTestCase {
    private func languages(_ filename: String, title: String? = nil) -> [DebridStreamLanguage] {
        var stream = Nuvio.Stream(title: filename, addonName: "x")
        stream.name = nil
        return StreamAttributeParser.parse(stream, title: title).languages
    }

    func testCodesAreLanguages() {
        XCTAssertEqual(languages("Movie.2023.1080p.ITA.ENG.WEB-DL"), [.en, .it])
    }

    func testCastellanoIsSpanish() {
        XCTAssertEqual(languages("Movie (2023) [BluRay][Castellano]"), [.es])
    }

    func testTitleWordsAreNotLanguages() {
        XCTAssertEqual(languages("The.French.Dispatch.2021.1080p.WEB-DL", title: "The French Dispatch"), [])
        XCTAssertEqual(languages("The.Italian.Job.2003.1080p.ENG", title: "The Italian Job"), [.en])
        XCTAssertEqual(languages("The Italian Job 2003 1080p ITA", title: "The Italian Job"), [.it])
    }

    func testOnlyTheFirstOccurrenceIsTheTitle() {
        XCTAssertEqual(languages("French.2020.FRENCH.1080p", title: "French"), [.fr])
    }

    func testShortTitleWordsAreNotAliases() {
        XCTAssertEqual(languages("Por.Siempre.2019.1080p"), [])
    }

    func testWholeWordsOnly() {
        XCTAssertEqual(languages("Spider-Man.Into.the.Multiverse.1080p"), [])
    }

    func testHebrew() {
        XCTAssertEqual(languages("Movie.2023.HEB.1080p"), [.he])
    }
}

// MARK: - Poster patterns

final class CustomPosterEncodedPatternTests: XCTestCase {
    func testEncodedPlaceholdersAreDecodedCaseInsensitively() {
        XCTAssertEqual(
            CustomPosterURL.decodingPlaceholders("https://x.test/%7bshape%7D/%7Bimdb_id%7Ctmdb_id%7D.jpg"),
            "https://x.test/{shape}/{imdb_id|tmdb_id}.jpg"
        )
    }

    func testOtherEscapesAreLeftAlone() {
        XCTAssertEqual(
            CustomPosterURL.decodingPlaceholders("https://x.test/a%20b/{imdb_id}.jpg"),
            "https://x.test/a%20b/{imdb_id}.jpg"
        )
    }
}

// MARK: - Languages, badges, lift, live, refresh

final class UpstreamBeta9RuleTests: XCTestCase {
    func testMontenegrinCodesAreSerbianMontenegro() {
        for code in ["cnr", "mne", "me", "Montenegrin", "sr-ME"] {
            XCTAssertEqual(MediaLanguage.normalise(code), "sr-me", code)
        }
        XCTAssertEqual(MediaLanguage.normalise("srp"), "sr")
        // A Serbian preference picks them, as upstream's `matchesLanguageCode("mne", "sr")`.
        XCTAssertNotNil(SubtitleSelector.match("mne", against: "sr"))
    }

    func testDolbyVisionPrefixNamesTheBaseCodec() {
        let av1 = playbackBadgeTokens(PlayerStreamInfo(videoCodec: "dav1.10.06"))
        XCTAssertTrue(av1.contains("AV1"))
        XCTAssertTrue(av1.contains("DV"))
        XCTAssertFalse(av1.contains("x265"))
        XCTAssertTrue(playbackBadgeTokens(PlayerStreamInfo(videoCodec: "dvhe.08.06")).contains("x265"))
    }

    func testAC4AndPCM() {
        XCTAssertTrue(playbackBadgeTokens(PlayerStreamInfo(audioCodec: "AC-4")).contains("AC4"))
        XCTAssertTrue(playbackBadgeTokens(PlayerStreamInfo(audioCodec: "pcm_s24le")).contains("PCM"))
    }

    func testAFilenameSharpensButNeverAddsAFormat() {
        let dts = playbackBadgeTokens(PlayerStreamInfo(audioCodec: "DTS"))
        XCTAssertTrue(refinedPlaybackBadgeTokens(dts, metadata: ["Movie.2160p.DTS-X.mkv"]).contains("DTS:X"))
        let ac3 = playbackBadgeTokens(PlayerStreamInfo(audioCodec: "AC-3"))
        XCTAssertFalse(refinedPlaybackBadgeTokens(ac3, metadata: ["Movie.DTS-X.Atmos.mkv"]).contains("DTS:X"))
        XCTAssertFalse(refinedPlaybackBadgeTokens(ac3, metadata: ["Movie.DTS-X.Atmos.mkv"]).contains("Atmos"))
        let eac3 = playbackBadgeTokens(PlayerStreamInfo(audioCodec: "eac3"))
        XCTAssertTrue(refinedPlaybackBadgeTokens(eac3, metadata: ["Movie.DDP5.1.Atmos.mkv"]).contains("Atmos"))
    }

    func testTheNameDoesNotReopenAGroupTheDecoderAnswered() {
        let filters = StreamBadgeMatcher.compile(StreamBadgeRules(imports: [
            StreamBadgeImport(sourceUrl: "https://example.test/pack.json", filters: [
                StreamBadgeFilter(id: "4k", groupId: "res", name: "4K", pattern: "2160p", imageURL: "", isEnabled: true),
                StreamBadgeFilter(id: "hd", groupId: "res", name: "1080p", pattern: "1080p", imageURL: "", isEnabled: true),
                StreamBadgeFilter(id: "web", groupId: "src", name: "WEB-DL", pattern: "WEB-?DL", imageURL: "", isEnabled: true)
            ], isActive: true)
        ]))
        let badges = StreamBadgeMatcher.playerBadges(
            decoder: ["2160p"], metadata: ["Movie.1080p.WEB-DL.mkv"], filters: filters
        )
        XCTAssertEqual(badges.map(\.name), ["4K", "WEB-DL"])
    }

    func testTheLiftDropsAtOnceWhenTheControlsHaveGone() {
        XCTAssertTrue(SubtitlePlacement.dropsImmediately(isPlaying: true, previewing: false, controlsVisible: false))
        XCTAssertTrue(SubtitlePlacement.dropsImmediately(isPlaying: false, previewing: false, controlsVisible: true))
        XCTAssertFalse(SubtitlePlacement.dropsImmediately(isPlaying: true, previewing: false, controlsVisible: true))
    }

    func testAGrowingDurationIsLive() {
        var growth = PlayerLivePolicy.DurationGrowth()
        for reading in [8.0, 18, 32] { growth.observe(reading) }
        XCTAssertTrue(growth.grew)
    }

    func testASettlingDurationIsNot() {
        var growth = PlayerLivePolicy.DurationGrowth()
        for reading in [1_320.0, 1_320, 1_325] { growth.observe(reading) }
        XCTAssertFalse(growth.grew)
    }

    func testChannelIsLiveAndTvIsNot() {
        XCTAssertTrue(PlayerLivePolicy.isLiveContentType("channel"))
        XCTAssertFalse(PlayerLivePolicy.isLiveContentType("tv"))
    }

    func testFrameRatesKeepTheirDecimals() {
        XCTAssertEqual(PlayerStreamInfo.frameRateLabel(23.976), "23.976 fps")
        XCTAssertEqual(PlayerStreamInfo.frameRateLabel(29.97), "29.97 fps")
        XCTAssertEqual(PlayerStreamInfo.frameRateLabel(24), "24 fps")
    }

    func testControlsDimOnlyWhenEverythingAgrees() {
        XCTAssertEqual(SubtitleStyle.playerControlsBrightness(isHDRVideo: true, hdrStyleEnabled: true, dimsControls: true, brightness: 0), 0.3, accuracy: 0.001)
        XCTAssertEqual(SubtitleStyle.playerControlsBrightness(isHDRVideo: false, hdrStyleEnabled: true, dimsControls: true, brightness: 0), 1)
        XCTAssertEqual(SubtitleStyle.playerControlsBrightness(isHDRVideo: true, hdrStyleEnabled: true, dimsControls: false, brightness: 0), 1)
    }

    func testOnlyARefusedRefreshEndsTheMDBListSession() {
        let ok = Data(#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#.utf8)
        if case .renewed = MDBListClient.refreshOutcome(status: 200, data: ok, refreshToken: "r") {} else {
            XCTFail("a 200 with tokens renews")
        }
        if case .rejected = MDBListClient.refreshOutcome(status: 401, data: Data(), refreshToken: "r") {} else {
            XCTFail("a 401 is a refusal")
        }
        let invalidGrant = Data(#"{"error":"invalid_grant"}"#.utf8)
        if case .rejected = MDBListClient.refreshOutcome(status: 500, data: invalidGrant, refreshToken: "r") {} else {
            XCTFail("invalid_grant is a refusal")
        }
        if case .unavailable = MDBListClient.refreshOutcome(status: 503, data: Data(), refreshToken: "r") {} else {
            XCTFail("a 503 says nothing about the token")
        }
    }

    func testABracketedSpeakerLabelTakesItsColon() {
        XCTAssertEqual(SubtitleSDHFilter.strip("[John]: Hello there"), "Hello there")
        XCTAssertEqual(SubtitleSDHFilter.strip("Note: this stays"), "Note: this stays")
    }
}
