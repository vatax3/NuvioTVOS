import XCTest
@testable import Nuvio

/// The settings that had a control and no reader, tested at the level the reader works at.
///
/// The 1.0.4 audit found eleven of these — a switch a viewer could throw with nothing behind it.
/// `Scripts/check-settings-wiring.sh` now fails the build when a new one appears; these tests
/// cover the behaviour the old ones were supposed to have, which a grep cannot check.
final class SettingsWiringTests: XCTestCase {

    // MARK: watch_progress_source / library_source_mode

    /// A source pointing at an account nobody signed into falls back to this device. Without
    /// this, choosing Trakt and then signing out leaves an empty library rather than the local
    /// one — and the preference can arrive from another device through account sync, so it is
    /// not enough to police it at the point of choice.
    func testASourceWithoutItsAccountFallsBackToLocal() {
        XCTAssertEqual(
            TrackingSources.effectiveWatchProgressSource(.trakt, connected: []),
            .local
        )
        XCTAssertEqual(
            TrackingSources.effectiveWatchProgressSource(.trakt, connected: [.trakt]),
            .trakt
        )
        XCTAssertEqual(
            TrackingSources.effectiveLibrarySourceMode(.simkl, connected: [.trakt]),
            .local
        )
        XCTAssertEqual(
            TrackingSources.effectiveLibrarySourceMode(.simkl, connected: [.trakt, .simkl]),
            .simkl
        )
    }

    func testOnlyConnectedAccountsAreOffered() {
        XCTAssertEqual(TrackingSources.availableWatchProgressSources(connected: []), [.local])
        XCTAssertEqual(
            TrackingSources.availableWatchProgressSources(connected: [.simkl]),
            [.local, .simkl]
        )
        XCTAssertEqual(
            TrackingSources.availableLibrarySourceModes(connected: [.trakt, .simkl]),
            [.local, .trakt, .simkl]
        )
    }

    /// Trakt reports a percentage and no duration, so the record it produces carries a nominal
    /// hundred-second duration. `fraction` is what the rail reads, and it has to come out exact.
    func testTraktResumePointsBecomeAFractionTheRailCanRead() throws {
        let item = TraktClient.PlaybackItem(
            imdbId: "tt0903747", type: .series, season: 2, episode: 4,
            progress: 37.5, pausedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let progress = try XCTUnwrap(RemoteProgressService.progress(from: item))
        XCTAssertEqual(progress.videoId, "tt0903747:2:4", "Stremio episode ids are series:season:episode")
        XCTAssertEqual(progress.contentId, "tt0903747")
        XCTAssertEqual(progress.fraction, 0.375, accuracy: 0.0001)
        XCTAssertEqual(progress.updatedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testAMovieResumePointKeepsItsPlainId() throws {
        let item = TraktClient.PlaybackItem(
            imdbId: "tt1375666", type: .movie, season: nil, episode: nil,
            progress: 10, pausedAt: nil
        )
        let progress = try XCTUnwrap(RemoteProgressService.progress(from: item))
        XCTAssertEqual(progress.videoId, "tt1375666")
    }

    func testAZeroResumePointIsNotAContinueWatchingRow() {
        let item = TraktClient.PlaybackItem(
            imdbId: "tt1", type: .movie, season: nil, episode: nil, progress: 0, pausedAt: nil
        )
        XCTAssertNil(RemoteProgressService.progress(from: item))
    }

    // MARK: continue_watching_days_cap

    func testTheDaysCapHasOneDefinitionOfNoCap() {
        XCTAssertNil(LibraryStore.cutoffDate(withinDays: 0))
        XCTAssertNil(LibraryStore.cutoffDate(withinDays: -30))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cutoff = LibraryStore.cutoffDate(withinDays: 90, now: now)
        XCTAssertEqual(cutoff, now.addingTimeInterval(-90 * 86_400))
    }

    // MARK: subtitle_use_forced_subtitles

    /// The rule is narrower than the label. When the audio is already in the language you read
    /// subtitles in, a full track repeats dialogue you can hear — so only a forced track should
    /// come on, and when there is none, nothing should.
    func testForcedSubtitlesOnlyApplyWhenTheAudioIsAlreadyUnderstood() {
        let tracks = [
            Subtitle(id: "1", url: "https://x/en.srt", lang: "eng", addonName: "OpenSubtitles"),
            Subtitle(id: "2", url: "https://x/en.forced.srt", lang: "eng", addonName: "OpenSubtitles")
        ]

        let sameLanguageAudio = SubtitleSelector.autoSelection(
            tracks, preferred: "eng", audioLanguage: "eng", useForced: true
        )
        XCTAssertEqual(sameLanguageAudio?.id, "2", "only the forced track should come on")

        let foreignAudio = SubtitleSelector.autoSelection(
            tracks, preferred: "eng", audioLanguage: "jpn", useForced: true
        )
        XCTAssertEqual(foreignAudio?.id, "1", "a forced track alone would leave dialogue untranslated")
    }

    func testWithNoForcedTrackAndMatchingAudioNothingIsTurnedOn() {
        let tracks = [Subtitle(id: "1", url: "https://x/en.srt", lang: "eng", addonName: nil)]
        XCTAssertNil(SubtitleSelector.autoSelection(
            tracks, preferred: "eng", audioLanguage: "eng", useForced: true
        ))
    }

    func testWithTheSettingOffTheFirstMatchWinsAsBefore() {
        let tracks = [
            Subtitle(id: "1", url: "https://x/en.forced.srt", lang: "eng", addonName: nil),
            Subtitle(id: "2", url: "https://x/en.srt", lang: "eng", addonName: nil)
        ]
        XCTAssertEqual(
            SubtitleSelector.autoSelection(tracks, preferred: "eng", audioLanguage: "eng", useForced: false)?.id,
            "1"
        )
    }

    /// Addons do not flag forced tracks, so the word is looked for wherever they put it.
    func testForcedIsRecognisedInTheIdUrlOrAddonName() {
        XCTAssertTrue(SubtitleSelector.isForced(
            Subtitle(id: "sub-FORCED-3", url: "https://x/a.srt", lang: "eng", addonName: nil)
        ))
        XCTAssertTrue(SubtitleSelector.isForced(
            Subtitle(id: "3", url: "https://x/Forced.srt", lang: "eng", addonName: nil)
        ))
        XCTAssertFalse(SubtitleSelector.isForced(
            Subtitle(id: "3", url: "https://x/a.srt", lang: "eng", addonName: "OpenSubtitles")
        ))
    }

    // MARK: tmdb_use_episodes

    /// TMDB fills blanks and never overwrites: the addon knows which cut of the episode it is
    /// serving and TMDB does not.
    func testEpisodeEnrichmentFillsBlanksAndLeavesTheAddonsOwnDataAlone() {
        let videos = [
            Video(id: "tt1:1:1", name: "The Addon's Title", season: 1, episode: 1),
            Video(id: "tt1:1:2", season: 1, episode: 2),
            Video(id: "tt1:2:1", season: 2, episode: 1)
        ]
        let details = [
            TMDBClient.EpisodeDetail(season: 1, episode: 1, name: "TMDB Title", overview: "o1", still: "s1", airDate: "2020-01-01", runtimeMinutes: 42),
            TMDBClient.EpisodeDetail(season: 1, episode: 2, name: "TMDB Two", overview: "o2", still: "s2", airDate: "2020-01-08", runtimeMinutes: 44),
            TMDBClient.EpisodeDetail(season: 1, episode: 3, name: "Not present", overview: nil, still: nil, airDate: nil, runtimeMinutes: nil)
        ]

        let merged = MetaDetailsViewModel.merging(details, into: videos, season: 1)
        XCTAssertEqual(merged[0].name, "The Addon's Title", "an existing title is never replaced")
        XCTAssertEqual(merged[0].thumbnail, "s1", "but a missing still is filled")
        XCTAssertEqual(merged[1].name, "TMDB Two")
        XCTAssertEqual(merged[1].runtime, "44 min")
        XCTAssertNil(merged[2].thumbnail, "another season is not touched")
        XCTAssertEqual(merged.count, 3, "TMDB cannot add episodes the addon does not list")
    }

    // MARK: stream_auto_play_reuse_binge_group

    func testTheNextEpisodePrefersTheReleaseAlreadyPlaying() {
        let streams: [Nuvio.Stream] = [
            stream(name: "Other", bingeGroup: "other-group"),
            stream(name: "Same", bingeGroup: "torrentio|1080p|WEB-DL"),
            stream(name: "None", bingeGroup: nil)
        ]
        XCTAssertEqual(
            StreamFilterEngine.bingeGroupMatch(in: streams, group: "torrentio|1080p|WEB-DL")?.displayName,
            "Same"
        )
        XCTAssertNil(StreamFilterEngine.bingeGroupMatch(in: streams, group: "nothing-like-this"))
        XCTAssertNil(StreamFilterEngine.bingeGroupMatch(in: streams, group: "   "))
    }

    private func stream(name: String, bingeGroup: String?) -> Nuvio.Stream {
        Nuvio.Stream(
            name: name, title: nil, description: nil,
            url: "https://example.test/\(name).mkv",
            ytId: nil, infoHash: nil, fileIdx: nil, externalUrl: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: bingeGroup),
            addonName: "Test addon", addonLogo: nil, sources: nil, quality: nil
        )
    }

    // MARK: external_player_forward_subtitles

    func testASubtitleTrackTravelsWithTheHandOffWhereThePlayerAcceptsOne() throws {
        let infuse = try XCTUnwrap(ExternalPlayer.infuse.playbackURL(
            for: "https://example.test/a.mkv", title: "A", subtitleURL: "https://example.test/a.srt"
        ))
        XCTAssertTrue(infuse.absoluteString.contains("&sub="), "Infuse takes a sidecar track")

        let outplayer = try XCTUnwrap(ExternalPlayer.outplayer.playbackURL(
            for: "https://example.test/a.mkv", title: "A", subtitleURL: "https://example.test/a.srt"
        ))
        XCTAssertFalse(outplayer.absoluteString.contains("sub="), "Outplayer takes the video URL only")
        XCTAssertFalse(ExternalPlayer.outplayer.acceptsSubtitleURL)
    }

    func testWithoutATrackTheHandOffIsUnchanged() throws {
        let withNone = try XCTUnwrap(ExternalPlayer.vlc.playbackURL(for: "https://x/a.mkv", title: nil))
        XCTAssertFalse(withNone.absoluteString.contains("sub="))
    }

    // MARK: resize_mode

    /// Android's five values do not map one to one onto the seven the player cycles through.
    func testTheDefaultAspectMapsOntoTheModesThePlayerHas() {
        XCTAssertEqual(MPVEngine.AspectMode(resizeMode: .fit), .fit)
        XCTAssertEqual(MPVEngine.AspectMode(resizeMode: .fill), .stretch)
        XCTAssertEqual(MPVEngine.AspectMode(resizeMode: .zoom), .crop)
        XCTAssertEqual(MPVEngine.AspectMode(resizeMode: .fixedWidth), .fitWidth)
        XCTAssertEqual(MPVEngine.AspectMode(resizeMode: .fixedHeight), .fitHeight)
    }
}
