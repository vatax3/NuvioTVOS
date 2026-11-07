import XCTest
@testable import Nuvio

/// Upstream's `AnimeSkipIntervalsTest` (1.1.0-beta.12), case for case. Their open-ended ending
/// runs to `Double.MAX_VALUE`; ours closes at the episode's length, so those expectations read
/// `length` instead.
final class AnimeSkipIntervalsTests: XCTestCase {
    private let length = 1440.0

    private func ts(_ at: Double, _ name: String) -> SkipIntroClient.AnimeSkipResponse.Timestamp {
        .init(at: at, type: .init(name: name))
    }

    private func intervals(
        _ timestamps: [SkipIntroClient.AnimeSkipResponse.Timestamp], baseDuration: Double? = nil
    ) -> [SkipSegment] {
        SkipIntroClient.intervals(from: timestamps, baseDuration: baseDuration, episodeLength: length)
    }

    func testLoneIntroMarkerWithoutEndIsDropped() {
        XCTAssertTrue(intervals([ts(22, "Intro")]).isEmpty)
    }

    func testLoneRecapMarkerWithoutEndIsDropped() {
        XCTAssertTrue(intervals([ts(0, "Recap")], baseDuration: 1430).isEmpty)
    }

    func testTrailingCreditsMarkerRunsToTheEndOfTheEpisode() {
        XCTAssertEqual(
            intervals([ts(0, "Intro"), ts(90, "Canon"), ts(1300, "Credits")], baseDuration: 1430),
            [SkipSegment(kind: .intro, start: 0, end: 90), SkipSegment(kind: .outro, start: 1300, end: length)]
        )
    }

    func testTrailingCreditsMarkerInTheFirstHalfIsDropped() {
        XCTAssertTrue(intervals([ts(22, "Credits")], baseDuration: 1430).isEmpty)
    }

    func testTrailingMixedCreditsMarkerRunsToTheEnd() {
        XCTAssertEqual(
            intervals([ts(1300, "Mixed Credits")], baseDuration: 1430),
            [SkipSegment(kind: .outro, start: 1300, end: length)]
        )
    }

    func testTrailingCreditsMarkerIsKeptWhenTheDurationIsUnknown() {
        XCTAssertEqual(intervals([ts(1300, "Credits")]), [SkipSegment(kind: .outro, start: 1300, end: length)])
    }

    func testSegmentsEndWhereTheNextMarkerStartsRegardlessOfOrder() {
        XCTAssertEqual(
            intervals([ts(1300, "Credits"), ts(90, "Canon"), ts(1390, "Preview"), ts(0, "Recap"), ts(30, "New Intro")]),
            [
                SkipSegment(kind: .recap, start: 0, end: 30),
                SkipSegment(kind: .intro, start: 30, end: 90),
                SkipSegment(kind: .outro, start: 1300, end: 1390)
            ]
        )
    }

    func testZeroLengthSegmentFromDuplicateTimestampsIsDropped() {
        XCTAssertEqual(
            intervals([ts(10, "Intro"), ts(10, "Canon"), ts(100, "Credits"), ts(200, "Canon")]),
            [SkipSegment(kind: .outro, start: 100, end: 200)]
        )
    }

    private func ep(_ timestamps: SkipIntroClient.AnimeSkipResponse.Timestamp...) -> SkipIntroClient.AnimeSkipResponse.Episode {
        .init(season: nil, number: "1042", baseDuration: 1430, timestamps: timestamps)
    }

    private func best(_ episodes: [SkipIntroClient.AnimeSkipResponse.Episode]) -> [SkipSegment] {
        SkipIntroClient.segments(from: episodes, episode: 1042, season: nil, episodeLength: length)
    }

    func testEntryCoveringTheMostCategoriesWins() {
        let result = best([
            ep(ts(974, "Intro")),
            ep(ts(13, "Intro"), ts(130, "Canon")),
            ep(ts(0, "Intro"), ts(130, "Recap"), ts(300, "Canon"), ts(1300, "Credits"), ts(1395, "Preview"))
        ])
        XCTAssertEqual(result.map(\.kind), [.intro, .recap, .outro])
    }

    func testMoreSegmentsBreakACategoryTieAndTheEarlierEntryWinsAFullTie() {
        let twoOpenings = ep(ts(0, "Intro"), ts(30, "Canon"), ts(600, "Mixed Intro"), ts(650, "Canon"))
        let oneOpening = ep(ts(10, "Intro"), ts(100, "Canon"))
        let otherOneOpening = ep(ts(20, "Intro"), ts(110, "Canon"))

        XCTAssertEqual(best([oneOpening, twoOpenings]).count, 2)
        XCTAssertEqual(best([oneOpening, otherOneOpening]).map(\.start), [10])
    }

    func testNoUsableEntryGivesNoSegments() {
        XCTAssertTrue(best([ep(ts(22, "Intro")), ep()]).isEmpty)
    }

    /// `baseDuration` is part of the episodes query now, and decodes when present.
    func testBaseDurationDecodes() throws {
        let json = #"{"data":{"findEpisodesByShowId":[{"season":null,"number":"3","baseDuration":1430.5,"timestamps":[]}]}}"#
        let response = try JSONDecoder().decode(SkipIntroClient.AnimeSkipResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data?.findEpisodesByShowId?.first?.baseDuration, 1430.5)
    }
}

final class SkipProviderRoutingTests: XCTestCase {
    /// Upstream's `mergeByPriority(introDb, aniSkip, animeSkip)`. Ours had IntroDB last.
    func testIntroDBOutranksAniSkipWhichOutranksAnimeSkip() {
        let merged = SkipIntroClient.merge(SkipIntroClient.byPriority(
            introDb: [SkipSegment(kind: .intro, start: 10, end: 90)],
            aniSkip: [SkipSegment(kind: .intro, start: 12, end: 92), SkipSegment(kind: .outro, start: 1300, end: 1390)],
            animeSkip: [SkipSegment(kind: .outro, start: 1310, end: 1400), SkipSegment(kind: .recap, start: 0, end: 10)]
        ))
        XCTAssertEqual(merged, [
            SkipSegment(kind: .recap, start: 0, end: 10),
            SkipSegment(kind: .intro, start: 10, end: 90),
            SkipSegment(kind: .outro, start: 1300, end: 1390)
        ])
    }

    func testKitsuAndMALIdsAreBothRead() {
        XCTAssertEqual(PlayerView.animeEpisode(from: "kitsu:7442:12"),
                       PlayerView.AnimeEpisodeId(source: "kitsu", id: "7442", episode: 12))
        XCTAssertEqual(PlayerView.animeEpisode(from: "mal:21:1000"),
                       PlayerView.AnimeEpisodeId(source: "mal", id: "21", episode: 1000))
        XCTAssertNil(PlayerView.animeEpisode(from: "tt0388629:1:1"))
        XCTAssertNil(PlayerView.animeEpisode(from: "kitsu:7442"))
    }
}

@MainActor
final class TrackMemoryTests: XCTestCase {
    private func track(
        _ id: Int64, _ title: String, _ language: String?, external: Bool = false, forced: Bool = false
    ) -> PlayerTrack {
        PlayerTrack(
            id: id, title: title, language: language, isSelected: false, isExternal: external,
            isDefault: false, isForced: forced, isHearingImpaired: false, codec: nil, channelCount: nil
        )
    }

    /// Upstream's `TrackPreferenceDataStore` keys and values, literally: the Android app reads
    /// these out of the shared settings blob.
    func testStoredFieldsAreUpstreams() {
        let memory = TrackMemory(
            audio: .init(language: "eng", name: "English 5.1", trackId: "2"),
            subtitle: .embedded(.init(language: "fre", name: "Forced", trackId: "4", isForced: true))
        )
        let fields = memory.storedFields
        XCTAssertEqual(Set(fields.keys), Set(TrackMemory.fields))
        XCTAssertEqual(fields["sub_type"], "INTERNAL")
        XCTAssertEqual(fields["sub_is_forced"], "true")
        XCTAssertEqual(fields["audio_track_id"], "2")
        XCTAssertEqual(fields["sub_addon_id"], .some(nil))
        XCTAssertEqual(TrackMemory.key("sub_type", contentId: "tt0903747"), "sub_type|tt0903747")

        XCTAssertEqual(TrackMemory { fields[$0] ?? nil }, memory)
    }

    func testAddonAndDisabledRoundTrip() {
        let addon = TrackMemory(subtitle: .addon(id: "os-123", url: "https://x/y.srt", language: "eng", addonName: "OpenSubtitles v3"))
        XCTAssertEqual(addon.storedFields["sub_type"], "ADDON")
        XCTAssertEqual(addon.storedFields["sub_addon_name"], "OpenSubtitles v3")
        XCTAssertEqual(TrackMemory { addon.storedFields[$0] ?? nil }, addon)

        let off = TrackMemory(subtitle: .disabled)
        XCTAssertEqual(off.storedFields["sub_type"], "DISABLED")
        XCTAssertEqual(TrackMemory { off.storedFields[$0] ?? nil }, off)

        XCTAssertNil(TrackMemory { _ in nil }, "nothing remembered loads as nil, as upstream")
    }

    /// Upstream 1.1.0-beta.12 (19b8a0c2): an audio pick after a restore must not write the
    /// restored subtitle away.
    func testAPickKeepsTheOtherHalf() throws {
        let suite = "TrackMemoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TrackPreferenceStore(defaults: defaults)

        store.rememberSubtitle(.addon(id: "a", url: "u", language: "fre", addonName: "Subs"), forContentId: "tt1")
        store.rememberAudio(.init(language: "jpn", name: nil, trackId: "1"), forContentId: "tt1")
        XCTAssertEqual(store.memory(forContentId: "tt1")?.subtitle,
                       .addon(id: "a", url: "u", language: "fre", addonName: "Subs"))
        XCTAssertEqual(store.memory(forContentId: "tt1")?.audio?.language, "jpn")

        store.rememberSubtitle(.disabled, forContentId: "tt1")
        XCTAssertNil(store.storedValue("sub_addon_id|tt1"), "fields a pick no longer uses are removed")
        XCTAssertEqual(store.memory(forContentId: "tt1")?.audio?.language, "jpn")
        XCTAssertNil(store.memory(forContentId: "tt2"))
    }

    func testStrictMatchPrefersTheTrackIdThenTheName() {
        let tracks = [track(1, "Commentary", "eng"), track(2, "English", "eng"), track(3, "Japanese", "jpn")]
        XCTAssertEqual(TrackMemory.match(.init(language: "eng", name: "English", trackId: "2"), in: tracks)?.id, 2)
        XCTAssertEqual(TrackMemory.match(.init(language: "eng", name: "Commentary", trackId: "9"), in: tracks)?.id, 1)
        XCTAssertEqual(TrackMemory.match(.init(language: "eng", name: "comment", trackId: nil), in: tracks)?.id, 1)
    }

    /// Android stores `en` where mpv reports `eng`; the memory is shared, so both must match.
    func testLanguageFallbackAcrossSpellings() {
        let tracks = [track(1, "", "fre"), track(3, "", "eng")]
        XCTAssertEqual(TrackMemory.match(.init(language: "en", name: nil, trackId: "7"), in: tracks)?.id, 3)
        XCTAssertNil(TrackMemory.match(.init(language: "de", name: nil, trackId: nil), in: tracks))
    }

    func testARememberedForcedTrackOnlyMatchesAForcedOne() {
        let tracks = [track(1, "Full", "fre"), track(2, "", "fre", forced: true)]
        XCTAssertEqual(TrackMemory.match(.init(language: "fre", name: nil, trackId: nil, isForced: true), in: tracks)?.id, 2)
        XCTAssertEqual(TrackMemory.match(.init(language: "fre", name: nil, trackId: nil, isForced: false), in: tracks)?.id, 1)
    }

    /// The nth external track is the nth addon subtitle, the order they are added in.
    func testExternalTracksMapToAddonSubtitlesByOrder() {
        let a = Nuvio.Subtitle(id: "a", url: "https://a", lang: "eng", addonName: "One")
        let b = Nuvio.Subtitle(id: "b", url: "https://b", lang: "fre", addonName: "Two")
        let tracks = [track(1, "", "eng"), track(5, "English", "eng", external: true), track(6, "French", "fre", external: true)]
        XCTAssertEqual(TrackMemory.addonSubtitle(for: tracks[2], in: tracks, addonSubtitles: [a, b]), b)
        XCTAssertEqual(TrackMemory.externalTrack(for: a, in: tracks, addonSubtitles: [a, b])?.id, 5)
        XCTAssertNil(TrackMemory.addonSubtitle(for: tracks[0], in: tracks, addonSubtitles: [a, b]))
    }

    /// The memory travels in the settings blob as upstream's `track_preference` feature,
    /// including the delay and speed entries only the Android app reads.
    func testTrackPreferenceRidesTheSettingsBlob() throws {
        let blob = SettingsBlob.export(["trackPreference": [
            "sub_type|tt1": "ADDON",
            "sub_delay_ms|tt1:1:1": NSNumber(value: 1200)
        ]])
        guard case .object(let features)? = blob["features"],
              case .object(let feature)? = features["track_preference"] else { return XCTFail("feature") }
        XCTAssertEqual(feature["sub_type|tt1"], .object(["type": .string("string"), "value": .string("ADDON")]))
        XCTAssertEqual(feature["sub_delay_ms|tt1:1:1"], .object(["type": .string("int"), "value": .int(1200)]))

        let pulled = try JSONDecoder().decode([String: AnyJSON].self, from: Data(#"""
        {"version":1,"features":{"track_preference":{
          "audio_lang|tt2":{"type":"string","value":"jpn"},
          "playback_speed|tt2":{"type":"float","value":1.25}}}}
        """#.utf8))
        let changes = SettingsBlob.changes(from: pulled, local: ["trackPreference": ["sub_type|tt1": "ADDON"]])
        XCTAssertEqual(changes["trackPreference"]?.set["audio_lang|tt2"], .string("jpn"))
        XCTAssertEqual(changes["trackPreference"]?.set["playback_speed|tt2"], .double(1.25))
        XCTAssertEqual(changes["trackPreference"]?.remove, ["sub_type|tt1"], "the feature is replaced, as upstream")
    }
}
