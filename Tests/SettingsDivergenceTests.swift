import XCTest
@testable import Nuvio

/// Two settings the key sweep against upstream's manifest found diverging from the Android app.
@MainActor
final class SettingsDivergenceTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let suite = "SettingsDivergenceTests.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    // MARK: Auto-play scope — upstream's StreamAutoPlaySelector

    private func addon(_ name: String, _ url: String) -> Nuvio.Stream {
        Nuvio.Stream(url: url, addonName: name)
    }

    private func plugin(_ repository: String, _ scraper: String?, _ url: String) -> Nuvio.Stream {
        Nuvio.Stream(url: url, addonName: repository, pluginSourceName: scraper)
    }

    private func pick(_ streams: [Nuvio.Stream], _ scope: StreamFilterEngine.AutoPlayScope) -> [String] {
        streams.filter { scope.admits($0, cacheStates: [:]) }.compactMap(\.url)
    }

    private let streams: [Nuvio.Stream] = [
        Nuvio.Stream(url: "https://a/1", addonName: "Torrentio"),
        Nuvio.Stream(url: "https://b/1", addonName: "Comet"),
        Nuvio.Stream(url: "https://p/1", addonName: "MoviesDrive"),
        Nuvio.Stream(url: "https://p/2", addonName: "Repo", pluginSourceName: "HDHub")
    ]
    private let installed: Set<String> = ["Torrentio", "Comet"]

    func testAllSourcesWithNothingSelectedAdmitsEverything() {
        XCTAssertEqual(pick(streams, .init(installedAddonNames: installed)).count, 4)
    }

    func testInstalledAddonsOnlyDropsPluginStreams() {
        XCTAssertEqual(
            pick(streams, .init(source: .installedAddonsOnly, installedAddonNames: installed)),
            ["https://a/1", "https://b/1"]
        )
    }

    func testEnabledPluginsOnlyDropsAddonStreams() {
        XCTAssertEqual(
            pick(streams, .init(source: .enabledPluginsOnly, installedAddonNames: installed)),
            ["https://p/1", "https://p/2"]
        )
    }

    func testPluginsOnlyWithPluginsOffFallsBackToAddons() {
        XCTAssertEqual(
            pick(streams, .init(source: .enabledPluginsOnly, installedAddonNames: installed, pluginsEnabled: false)),
            ["https://a/1", "https://b/1"]
        )
    }

    /// A selection narrows its own kind only: selected addons leave plugin streams alone.
    func testSelectedAddonsFilterOnlyAddonStreams() {
        XCTAssertEqual(
            pick(streams, .init(installedAddonNames: installed, selectedAddons: ["Comet"])),
            ["https://b/1", "https://p/1", "https://p/2"]
        )
    }

    /// A plugin grouped under its repository is matched by its own name.
    func testSelectedPluginsMatchTheScraperNotTheRepository() {
        XCTAssertEqual(
            pick(streams, .init(installedAddonNames: installed, selectedPlugins: ["HDHub"])),
            ["https://a/1", "https://b/1", "https://p/2"]
        )
    }

    func testDebridFilterStillApplies() {
        let magnet = Nuvio.Stream(infoHash: "abc", addonName: "Torrentio")
        let cached = SettingsDivergenceTests.cache("abc", .cached)
        let scope = StreamFilterEngine.AutoPlayScope(installedAddonNames: installed, debridFilter: .cachedOnly)
        XCTAssertTrue(scope.admits(magnet, cacheStates: cached))
        XCTAssertFalse(scope.admits(streams[0], cacheStates: cached))
    }

    private static func cache(_ hash: String, _ state: DebridCacheState) -> [String: DebridCacheResult] {
        [hash: DebridCacheResult(provider: .realDebrid, state: state)]
    }

    // MARK: Migrations

    func testOldSourceValuesMigrate() throws {
        for (old, filter) in [("ANY", StreamAutoPlayDebridFilter.off), ("DEBRID_ONLY", .debridOnly), ("CACHED_ONLY", .cachedOnly)] {
            let defaults = try defaults()
            defaults.set(old, forKey: "player.stream_auto_play_source")
            let store = PlayerSettingsStore(defaults: defaults)
            XCTAssertEqual(store.streamAutoPlaySource, .allSources, old)
            XCTAssertEqual(store.streamAutoPlayDebridFilter, filter, old)
            XCTAssertEqual(store.storedValue("stream_auto_play_source") as? String, "ALL_SOURCES")
        }
    }

    func testUpstreamSourceValueIsKept() throws {
        let defaults = try defaults()
        defaults.set("ENABLED_PLUGINS_ONLY", forKey: "player.stream_auto_play_source")
        XCTAssertEqual(PlayerSettingsStore(defaults: defaults).streamAutoPlaySource, .enabledPluginsOnly)
    }

    func testAutoSkipMovesToUpstreamsKey() throws {
        let defaults = try defaults()
        defaults.set(["intro", "movieCredits"], forKey: "skipintro.auto_skip_segment_kinds")
        let store = SkipIntroSettingsStore(defaults: defaults)
        XCTAssertEqual(store.autoSkipSegmentKinds, [.intro, .movieCredits])
        XCTAssertEqual(store.storedValue("auto_skip_segment_types") as? [String], ["intro", "movie-credits"])
        XCTAssertNil(store.storedValue("auto_skip_segment_kinds"))
    }

    // MARK: The blob

    func testBothTravelInUpstreamsShape() throws {
        let blob = SettingsBlob.export([
            "player": [
                "stream_auto_play_source": "INSTALLED_ADDONS_ONLY",
                "stream_auto_play_selected_addons": ["Torrentio"]
            ],
            "skipIntro": ["auto_skip_segment_types": ["intro", "movie-credits"]]
        ])
        guard case .object(let features)? = blob["features"],
              case .object(let player)? = features["player_settings"] else { return XCTFail("player_settings") }
        XCTAssertEqual(player["stream_auto_play_source"], .object(["type": .string("string"), "value": .string("INSTALLED_ADDONS_ONLY")]))
        XCTAssertEqual(player["stream_auto_play_selected_addons"], .object(["type": .string("string_set"), "value": .array([.string("Torrentio")])]))
        XCTAssertEqual(player["auto_skip_segment_types"], .object(["type": .string("string_set"), "value": .array([.string("intro"), .string("movie-credits")])]))
        XCTAssertNil(features["animeskip_settings"].flatMap { value -> AnyJSONValue? in
            if case .object(let entries) = value { return entries["auto_skip_segment_types"] }
            return nil
        })

        let pulled = try JSONDecoder().decode([String: AnyJSON].self, from: Data(#"""
        {"version":1,"features":{"player_settings":{"auto_skip_segment_types":{"type":"string_set","value":["outro"]}}}}
        """#.utf8))
        let changes = SettingsBlob.changes(from: pulled, local: [:])
        XCTAssertEqual(changes["skipIntro"]?.set["auto_skip_segment_types"], .strings(["outro"]))
    }
}
