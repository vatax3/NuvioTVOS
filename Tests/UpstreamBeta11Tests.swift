import XCTest
@testable import Nuvio

/// Rules ported or fixed in the 1.1.0-beta.11 parity pass. Literal inputs where upstream's own
/// tests had them, and literal JSON in upstream's shape for anything the two apps exchange.

// MARK: - Settings blob (shared with the Android app)

final class SettingsBlobContractTests: XCTestCase {
    private func object(_ value: AnyJSONValue?) -> [String: AnyJSONValue]? {
        if case .object(let o)? = value { return o }
        return nil
    }

    private func decodeBlob(_ json: String) throws -> [String: AnyJSON] {
        try JSONDecoder().decode([String: AnyJSON].self, from: Data(json.utf8))
    }

    func testExportIsUpstreamsShape() throws {
        let blob = SettingsBlob.export([
            "player": [
                "skip_intro_enabled": NSNumber(value: true),
                "still_watching_episode_threshold": NSNumber(value: 3),
                "subtitle_text_color": "#FFFFFFFF",
                "subtitle_background_color": "#80000000",
                "next_episode_threshold_percent_v2": NSNumber(value: 90),
                // Local-only upstream: never leaves the device.
                "audio_output_channels": "STEREO",
                "internal_player_engine": "MPV"
            ],
            "app": ["experience_mode": "ADVANCED"]
        ])
        if case .int(let version)? = blob["version"] { XCTAssertEqual(version, 1) } else { XCTFail("version") }
        let features = try XCTUnwrap(object(blob["features"]))
        let player = try XCTUnwrap(object(features["player_settings"]))

        XCTAssertEqual(player["skip_intro_enabled"], .object(["type": .string("boolean"), "value": .bool(true)]))
        XCTAssertEqual(player["still_watching_episode_threshold"], .object(["type": .string("int"), "value": .int(3)]))
        // `Color.White.toArgb()` is -1; 0x80000000 is Int.min for 32 bits.
        XCTAssertEqual(player["subtitle_text_color"], .object(["type": .string("int"), "value": .int(-1)]))
        XCTAssertEqual(player["subtitle_background_color"], .object(["type": .string("int"), "value": .int(-2147483648)]))
        XCTAssertEqual(player["next_episode_threshold_percent_v2"], .object(["type": .string("float"), "value": .double(90)]))
        XCTAssertNil(player["audio_output_channels"])
        XCTAssertNil(player["internal_player_engine"])

        let experience = try XCTUnwrap(object(features["experience_settings"]))
        XCTAssertEqual(experience["mode"], .object(["type": .string("string"), "value": .string("ADVANCED")]))
    }

    func testAnIntegerOneIsNotABoolean() {
        // UserDefaults hands back NSNumber; `as? Bool` would read 1 as true.
        XCTAssertFalse(SettingsBlob.isBoolean(NSNumber(value: 1)))
        XCTAssertTrue(SettingsBlob.isBoolean(NSNumber(value: true)))
        XCTAssertNil(SettingsBlob.encode(NSNumber(value: 1), key: "skip_intro_enabled", as: .boolean))
        XCTAssertTrue(SettingsBlob.isFloatingPoint(NSNumber(value: 2.0)))
        XCTAssertNil(SettingsBlob.integer(NSNumber(value: 2.0)))
    }

    func testAKeyWithAnUnconvertibleTypeIsSkippedBothWays() throws {
        // Upstream declares `subtitle_size` as an Int percentage; ours is a Double scale. Sending
        // it would make Android's typed read throw.
        let blob = SettingsBlob.export(["player": ["subtitle_size": NSNumber(value: 1.25)]])
        let features = try XCTUnwrap(object(blob["features"]))
        XCTAssertNil(object(features["player_settings"])?["subtitle_size"])
    }

    func testImportFromAnAndroidBlob() throws {
        let json = """
        {"version":1,"features":{
          "player_settings":{
            "skip_intro_enabled":{"type":"boolean","value":false},
            "subtitle_text_color":{"type":"int","value":-256},
            "subtitle_outline_width":{"type":"int","value":3},
            "next_episode_threshold_minutes_before_end_v2":{"type":"float","value":2.0},
            "audio_amplification_db":{"type":"int","value":6}
          },
          "experience_settings":{"mode":{"type":"string","value":"ESSENTIAL"}},
          "plugin_settings":{
            "group_streams_by_repository":{"type":"boolean","value":true},
            "repositories":{"type":"string","value":"[]"}
          },
          "debrid_settings":{"torbox_api_key":{"type":"string","value":"secret"}}
        }}
        """
        let changes = SettingsBlob.changes(from: try decodeBlob(json), local: [:])
        let player = try XCTUnwrap(changes["player"])
        XCTAssertEqual(player.set["skip_intro_enabled"], .bool(false))
        XCTAssertEqual(player.set["subtitle_text_color"], .string("#FFFFFF00"))
        XCTAssertEqual(player.set["subtitle_outline_width"], .double(3))
        XCTAssertEqual(player.set["next_episode_threshold_minutes_before_end_v2"], .int(2))
        XCTAssertEqual(player.set["group_streams_by_repository"], .bool(true))
        // Device-local upstream and kept so here; and the plugin list never comes through.
        XCTAssertNil(player.set["audio_amplification_db"])
        XCTAssertNil(player.set["repositories"])
        XCTAssertEqual(changes["app"]?.set["experience_mode"], .string("ESSENTIAL"))
        XCTAssertNil(changes["debrid"]?.set["torbox_api_key"])
    }

    func testAKnownKeyMissingFromAPresentFeatureResetsAndAnOursOnlyKeyStays() throws {
        let json = #"{"version":1,"features":{"player_settings":{"skip_intro_enabled":{"type":"boolean","value":true}}}}"#
        let local: [String: [String: Any]] = ["player": [
            "pause_overlay_enabled": NSNumber(value: false),   // upstream knows it
            "verbose_logging_enabled": NSNumber(value: true)   // ours only
        ]]
        let changes = SettingsBlob.changes(from: try decodeBlob(json), local: local)
        XCTAssertEqual(changes["player"]?.remove, ["pause_overlay_enabled"])
    }

    func testPushCarriesRemoteEntriesWeDoNotHold() throws {
        let remote = try decodeBlob(#"{"version":1,"features":{"player_settings":{"tunneling_enabled":{"type":"boolean","value":true},"use_libass":{"type":"boolean","value":true}},"ambient_mode_settings":{"x":{"type":"int","value":1}}}}"#)
        let blob = SettingsBlob.export(["player": ["skip_intro_enabled": NSNumber(value: true)]], preserving: remote)
        let features = try XCTUnwrap(object(blob["features"]))
        let player = try XCTUnwrap(object(features["player_settings"]))
        XCTAssertNotNil(player["use_libass"])
        XCTAssertNotNil(player["skip_intro_enabled"])
        XCTAssertNotNil(features["ambient_mode_settings"])
    }

    func testTheOldShapeIsReadOnce() throws {
        let old = try decodeBlob(#"{"player":{"skip_intro_enabled":false,"audio_output_channels":"STEREO"}}"#)
        XCTAssertFalse(SettingsBlob.isCurrentShape(old))
        let legacy = SettingsBlob.legacyChanges(from: old)
        XCTAssertNotNil(legacy["player"]?["skip_intro_enabled"])
        XCTAssertNil(legacy["player"]?["audio_output_channels"])
    }

    func testColourConversionRoundTrips() {
        for hex in ["#FFFFFFFF", "#00000000", "#80112233", "#FF000000"] {
            XCTAssertEqual(SettingsBlob.argb(fromHex: hex).map(SettingsBlob.hex(fromARGB:)), hex)
        }
        XCTAssertEqual(SettingsBlob.argb(fromHex: "#FFFFFF"), -1)
    }

    func testManifestCoversTheFeaturesTheBlobCarries() {
        for feature in Set(SettingsBlob.storeFeature.values) {
            XCTAssertNotNil(UpstreamSettingsManifest.keys[feature], feature)
        }
    }
}

// MARK: - Episode numbering

final class EpisodeRemapTests: XCTestCase {
    private func list(_ counts: [Int], titles: [String: String] = [:]) -> [EpisodeRemap.Entry] {
        counts.enumerated().flatMap { index, count in
            (1...count).map { episode in
                let season = index + 1
                return EpisodeRemap.Entry(
                    season: season, episode: episode,
                    title: titles["\(season):\(episode)"],
                    videoId: "tt1:\(season):\(episode)"
                )
            }
        }
    }

    func testOneLongSeasonAgainstTwoCoursRemapsByPosition() {
        let addon = list([24, 24])
        let trakt = list([48])
        XCTAssertFalse(EpisodeRemap.hasSameSeasonStructure(addon, trakt))
        let mapped = EpisodeRemap.remap(season: 2, episode: 11, from: addon, to: trakt)
        XCTAssertEqual(mapped?.season, 1)
        XCTAssertEqual(mapped?.episode, 35)
        let back = EpisodeRemap.remap(season: 1, episode: 35, from: trakt, to: addon)
        XCTAssertEqual(back?.season, 2)
        XCTAssertEqual(back?.episode, 11)
        XCTAssertEqual(back?.videoId, "tt1:2:11")
    }

    func testDailyShowCountsDifferButSeasonsMatch() {
        // Upstream's test: Trakt 61/160, the addon 65/160. Structures differ — which is why
        // reads now remap only an episode the addon lacks — while MDBList's rule keeps them.
        let addon = list([65, 160]), trakt = list([61, 160])
        XCTAssertFalse(EpisodeRemap.hasSameSeasonStructure(addon, trakt))
        XCTAssertTrue(EpisodeRemap.hasSameSeasons(addon, trakt))
        XCTAssertTrue(addon.contains { $0.season == 2 && $0.episode == 1 })
    }

    func testAUniqueTitleBeatsPosition() {
        let addon = list([3], titles: ["1:3": "The Reckoning"])
        let trakt = list([1, 2], titles: ["1:1": "The Reckoning"])
        let mapped = EpisodeRemap.remap(season: 1, episode: 3, from: addon, to: trakt)
        XCTAssertEqual(mapped?.season, 1)
        XCTAssertEqual(mapped?.episode, 1)
    }

    func testEpisodeNumberTitlesAreNotTitles() {
        XCTAssertFalse(EpisodeRemap.isUsefulTitle(EpisodeRemap.normalisedTitle("Episode 12")))
        XCTAssertFalse(EpisodeRemap.isUsefulTitle(EpisodeRemap.normalisedTitle("Ep. 4")))
        XCTAssertTrue(EpisodeRemap.isUsefulTitle(EpisodeRemap.normalisedTitle("Episode of Doom")))
        XCTAssertEqual(EpisodeRemap.normalisedTitle("  The — End!! "), "the end")
    }
}

// MARK: - Plugin variants (upstream's PluginProviderPriorityTest literals)

final class PluginBingeGroupTests: XCTestCase {
    private func group(_ id: String, name: String? = nil, title: String? = nil, quality: String? = nil) -> String {
        PluginBingeGroup.make(scraperId: id, name: name, title: title, quality: quality)
    }

    func testScraperIdAndTokens() {
        XCTAssertEqual(PluginBingeGroup.scraperId(of: group("example")), "example")
        XCTAssertEqual(PluginBingeGroup.scraperId(of: "local-plugin-example|1080"), "example")
        XCTAssertNil(PluginBingeGroup.scraperId(of: "addon-group"))
        XCTAssertNil(PluginBingeGroup.scraperId(of: "local-plugin-"))
        XCTAssertEqual(PluginBingeGroup.tokenize([nil, nil, nil, "1080p HDR"]), ["1080", "hdr"])
        XCTAssertEqual(PluginBingeGroup.tokenize(["4K"]), ["4k"])
        XCTAssertEqual(PluginBingeGroup.tokenize(["Français (VOSTFR)"]), ["français", "vostfr"])
        XCTAssertEqual(PluginBingeGroup.tokenize(["Server 1"]), ["1", "server"])
    }

    func testNextEpisodeKeepsTheVariant() {
        let saved = group("example-scraper", name: "ExampleHost", title: "Episode 1 Dual Audio", quality: "720p")
        let original = group("example-scraper", name: "ExampleHost", title: "Episode 2 Original", quality: "720p")
        let dual = group("example-scraper", name: "ExampleHost", title: "Épisode 2 Dual Audio", quality: "720P")
        XCTAssertEqual(PluginBingeGroup.indexOfMatch(target: saved, candidates: [original, dual]), 1)

        let french = group("example-scraper", title: "S01E02 Français VOSTFR", quality: "1080p")
        let frenchNext = group("example-scraper", title: "S01E03 Français VOSTFR", quality: "1080p")
        let frenchOther = group("example-scraper", title: "S01E03 Français VF", quality: "1080p")
        XCTAssertEqual(PluginBingeGroup.indexOfMatch(target: french, candidates: [frenchNext, frenchOther]), 0)
        XCTAssertTrue(PluginBingeGroup.matches(candidate: frenchNext, target: french))
        XCTAssertTrue(PluginBingeGroup.matches(candidate: frenchOther, target: french))
    }

    func testQualityMustMatch() {
        XCTAssertTrue(PluginBingeGroup.matches(candidate: "local-plugin-example|720", target: "local-plugin-example|720"))
        XCTAssertFalse(PluginBingeGroup.matches(candidate: "local-plugin-example|1080", target: "local-plugin-example|720"))
        XCTAssertTrue(PluginBingeGroup.matches(candidate: "local-plugin-example|1080", target: "local-plugin-example"))
        XCTAssertFalse(PluginBingeGroup.matches(candidate: "example-addon|1080p", target: "example-addon|720p"))
        XCTAssertFalse(PluginBingeGroup.matches(
            candidate: "local-plugin-example|1080 examplehost", target: "local-plugin-example|720 examplehost"
        ))
    }

    func testClosestNumberedAlternative() {
        let saved = group("example-scraper", name: "Server 1", title: "Example Note")
        let sameServerOtherAudio = group("example-scraper", name: "Server 1", title: "Example Voice")
        let otherServerSameAudio = group("example-scraper", name: "Server 2", title: "Example Note")
        let exact = group("example-scraper", name: "Server 1", title: "Example Note")
        XCTAssertEqual(PluginBingeGroup.indexOfMatch(target: saved, candidates: [sameServerOtherAudio, otherServerSameAudio]), 1)
        XCTAssertEqual(PluginBingeGroup.indexOfMatch(target: saved, candidates: [exact, otherServerSameAudio]), 0)
    }

    func testSavedQualityWhenHigherQualitiesComeFirst() {
        let saved = group("example-plugin", name: "ExamplePlugin", title: "Example S01E05 480p", quality: "480p")
        let ultra = group("example-plugin", name: "ExamplePlugin", title: "Example S01E06 2160p", quality: "2160p")
        let fullHd = group("example-plugin", name: "ExamplePlugin", title: "Example S01E06 1080p", quality: "1080p")
        let sd = group("example-plugin", name: "ExamplePlugin", title: "Example S01E06 480p", quality: "480p")
        XCTAssertEqual(PluginBingeGroup.indexOfMatch(target: saved, candidates: [ultra, fullHd, sd]), 2)
        XCTAssertNil(PluginBingeGroup.indexOfMatch(target: saved, candidates: [ultra, fullHd]))
    }

    func testNextEpisodeSourceMatchUsesThePluginBranch() {
        func stream(_ group: String, url: String) -> Nuvio.Stream {
            Nuvio.Stream(url: url, behaviorHints: StreamBehaviorHints(bingeGroup: group), addonName: "Plugins")
        }
        let saved = group("example-plugin", name: "Host", title: "Show S01E01", quality: "720p")
        let candidates = [
            stream(group("example-plugin", name: "Host", title: "Show S01E02", quality: "1080p"), url: "https://a/1080"),
            stream(group("example-plugin", name: "Host", title: "Show S01E02", quality: "720p"), url: "https://a/720")
        ]
        let match = NextEpisodeSourceMatch.find(
            in: candidates, release: .init(bingeGroup: saved), season: 1, episode: 2
        )
        XCTAssertEqual(match?.stream.url, "https://a/720")
        XCTAssertEqual(match?.reason, .pluginVariant)
    }

    func testProviderHeadingsGroupAndAnnounceEachProvider() {
        func s(_ provider: String, _ url: String) -> Nuvio.Stream {
            Nuvio.Stream(url: url, addonName: "Repo", pluginSourceName: provider)
        }
        let grouped = PluginProviderHeading.grouped([s("beta", "1"), s("Alpha", "2"), s("beta", "3")])
        XCTAssertEqual(grouped.map(\.url), ["2", "1", "3"])
        XCTAssertEqual(PluginProviderHeading.heading(for: grouped[0], after: nil), "Alpha")
        XCTAssertEqual(PluginProviderHeading.heading(for: grouped[1], after: grouped[0]), "beta")
        XCTAssertNil(PluginProviderHeading.heading(for: grouped[2], after: grouped[1]))
    }
}

// MARK: - Smaller rules

final class UpstreamBeta11RuleTests: XCTestCase {
    func testCantoneseJoinsChinese() {
        for code in ["yue", "zhc", "ZC", "Cantonese", "Chinese (Cantonese)", "zh-CA"] {
            XCTAssertEqual(MediaLanguage.normalise(code), "zh-ca", code)
        }
        XCTAssertNotNil(SubtitleSelector.match("yue", against: "zh"))
        XCTAssertFalse(MediaLanguage.named("zh-ca")?.contains("Canada") ?? true)
    }

    func testLfeLevelReachesTheResampler() {
        XCTAssertNil(PlayerAudioMix.swresampleOptions(centerMixDb: 0, lfe: .off))
        XCTAssertEqual(PlayerAudioMix.swresampleOptions(centerMixDb: 0, lfe: .half), "lfe_mix_level=0.5000")
        let both = PlayerAudioMix.swresampleOptions(centerMixDb: 3, lfe: .full)
        XCTAssertTrue(both?.hasPrefix("center_mix_level=") ?? false)
        XCTAssertTrue(both?.hasSuffix(",lfe_mix_level=1.0000") ?? false)
        // Upstream's values, which the synced key carries.
        XCTAssertEqual(DownmixLfeLevel.allCases.map(\.rawValue), ["off", "50", "100"])
    }

    func testAnySavedPositionIsInProgress() {
        func p(_ position: Double) -> WatchProgress {
            WatchProgress(contentId: "c", contentType: "movie", videoId: "c",
                          positionSeconds: position, durationSeconds: 1000, updatedAt: Date())
        }
        XCTAssertTrue(p(5).isInProgress(threshold: 0.9))      // 0.5%: on the rail and resumable
        XCTAssertFalse(p(0).isInProgress(threshold: 0.9))
        XCTAssertFalse(p(950).isInProgress(threshold: 0.9))
        XCTAssertTrue(NextUpAnchor.isResumable(p(15), threshold: 0.9))
    }

    func testContinueWatchingCardMarksItsEpisode() {
        var context = PosterOptionsPolicy.Context(
            type: .series, isInLibrary: false, isWatched: false, hasProgress: true,
            canWalkEpisodes: true, continueWatchingEpisodeAired: true
        )
        var actions = PosterOptionsPolicy.actions(for: context)
        XCTAssertTrue(actions.contains(.markEpisodeWatched))
        XCTAssertFalse(actions.contains(.markWatched))

        context.continueWatchingEpisodeAired = false
        actions = PosterOptionsPolicy.actions(for: context)
        XCTAssertFalse(actions.contains(.markEpisodeWatched))
        XCTAssertFalse(actions.contains(.markWatched))

        context.continueWatchingEpisodeAired = nil
        XCTAssertTrue(PosterOptionsPolicy.actions(for: context).contains(.markWatched))
    }

    func testReusedLinksExpire() {
        let now = Date()
        let link = LastStreamLink(url: "https://x/f.mkv", streamName: "1080p", headers: [:], cachedAt: now.addingTimeInterval(-3 * 3600))
        XCTAssertTrue(LastStreamLinkStore.isFresh(link, maxAgeHours: 24, now: now))
        XCTAssertFalse(LastStreamLinkStore.isFresh(link, maxAgeHours: 2, now: now))
        // Clamped to upstream's 1–168: zero means one hour, not "never".
        XCTAssertFalse(LastStreamLinkStore.isFresh(link, maxAgeHours: 0, now: now))
        var empty = link
        empty.url = ""
        XCTAssertFalse(LastStreamLinkStore.isFresh(empty, maxAgeHours: 24, now: now))
    }
}
