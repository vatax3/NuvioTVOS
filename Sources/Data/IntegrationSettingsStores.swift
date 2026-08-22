import Foundation
import Observation

// MARK: - Debrid (port of DebridSettingsDataStore)

@Observable
@MainActor
final class DebridSettingsStore: PreferenceStore {
    init() { super.init(namespace: "debrid") }

    override var secureKeys: Set<String> {
        ["real_debrid_api_key", "premiumize_api_key", "torbox_api_key"]
    }

    var enabled: Bool {
        get { bool("debrid_enabled", default: false) }
        set { setBool("debrid_enabled", newValue) }
    }

    var cloudLibraryEnabled: Bool {
        get { bool("cloud_library_enabled", default: true) }
        set { setBool("cloud_library_enabled", newValue) }
    }

    var realDebridApiKey: String {
        get { secureString("real_debrid_api_key", default: "") }
        set { setSecureString("real_debrid_api_key", newValue) }
    }

    var premiumizeApiKey: String {
        get { secureString("premiumize_api_key", default: "") }
        set { setSecureString("premiumize_api_key", newValue) }
    }

    var torboxApiKey: String {
        get { secureString("torbox_api_key", default: "") }
        set { setSecureString("torbox_api_key", newValue) }
    }

    var preferredResolverProviderId: String {
        get { string("preferred_resolver_provider_id", default: "") }
        set { setString("preferred_resolver_provider_id", newValue) }
    }

    var instantPlaybackPreparationLimit: Int {
        get { int("instant_playback_preparation_limit", default: 2) }
        set { setInt("instant_playback_preparation_limit", min(max(newValue, 0), 5)) }
    }

    var streamMaxResults: Int {
        get { int("stream_max_results", default: 0) }
        set { setInt("stream_max_results", newValue <= 0 ? 0 : min(newValue, 100)) }
    }

    var streamSortMode: DebridStreamSortMode {
        get { option("stream_sort_mode", default: .default) }
        set { setOption("stream_sort_mode", newValue) }
    }

    var streamMinimumQuality: DebridStreamMinimumQuality {
        get { option("stream_minimum_quality", default: .any) }
        set { setOption("stream_minimum_quality", newValue) }
    }

    var streamDolbyVisionFilter: DebridStreamFeatureFilter {
        get { option("stream_dolby_vision_filter", default: .any) }
        set { setOption("stream_dolby_vision_filter", newValue) }
    }

    var streamHdrFilter: DebridStreamFeatureFilter {
        get { option("stream_hdr_filter", default: .any) }
        set { setOption("stream_hdr_filter", newValue) }
    }

    var streamCodecFilter: DebridStreamCodecFilter {
        get { option("stream_codec_filter", default: .any) }
        set { setOption("stream_codec_filter", newValue) }
    }

    var streamPreferences: DebridStreamPreferences {
        get { codable("stream_preferences", default: DebridStreamPreferences()) }
        set { setCodable("stream_preferences", newValue) }
    }

    // MARK: Derived

    func apiKey(for provider: DebridProvider) -> String {
        switch provider {
        case .realDebrid: return realDebridApiKey
        case .premiumize: return premiumizeApiKey
        case .torbox: return torboxApiKey
        }
    }

    func setApiKey(_ key: String, for provider: DebridProvider) {
        switch provider {
        case .realDebrid: realDebridApiKey = key
        case .premiumize: premiumizeApiKey = key
        case .torbox: torboxApiKey = key
        }
    }

    var configuredCredentials: [DebridCredential] {
        DebridProvider.allCases.compactMap { provider in
            let key = apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : DebridCredential(provider: provider, apiKey: key)
        }
    }

    /// The provider used to turn a torrent into a playable link.
    var activeResolver: DebridCredential? {
        let configured = configuredCredentials
        if let preferred = DebridProvider(rawValue: preferredResolverProviderId),
           let match = configured.first(where: { $0.provider == preferred }) {
            return match
        }
        return configured.first
    }

    var canResolvePlayableLinks: Bool { enabled && activeResolver != nil }

    var cacheCheckCredentials: [DebridCredential] {
        guard enabled else { return [] }
        return configuredCredentials.filter { $0.provider.supportsCacheCheck }
    }
}

// MARK: - Tracking (port of TraktSettingsDataStore)

@Observable
@MainActor
final class TrackingSettingsStore: PreferenceStore {
    init() { super.init(namespace: "tracking") }

    override var secureKeys: Set<String> {
        ["trakt_client_secret", "trakt_access_token", "trakt_refresh_token", "simkl_access_token"]
    }

    var watchProgressSource: WatchProgressSource {
        get { option("watch_progress_source", default: .local) }
        set { setOption("watch_progress_source", newValue) }
    }

    var librarySourceMode: LibrarySourceMode {
        get { option("library_source_mode", default: .local) }
        set { setOption("library_source_mode", newValue) }
    }

    var moreLikeThisSource: MoreLikeThisSource {
        get { option("more_like_this_source", default: .addonCatalog) }
        set { setOption("more_like_this_source", newValue) }
    }

    var continueWatchingDaysCap: Int {
        get { int("continue_watching_days_cap", default: 90) }
        set { setInt("continue_watching_days_cap", newValue) }
    }

    var showMetaComments: Bool {
        get { bool("show_meta_comments", default: false) }
        set { setBool("show_meta_comments", newValue) }
    }

    var showUnairedNextUp: Bool {
        get { bool("show_unaired_next_up", default: false) }
        set { setBool("show_unaired_next_up", newValue) }
    }

    var nextUpFromFurthestEpisode: Bool {
        get { bool("next_up_from_furthest_episode", default: true) }
        set { setBool("next_up_from_furthest_episode", newValue) }
    }

    // Trakt credentials. The Android build bakes Nuvio's own client ID into BuildConfig; a
    // third-party client cannot ship those, so the viewer supplies their own Trakt app.
    var traktClientId: String {
        get { string("trakt_client_id", default: "") }
        set { setString("trakt_client_id", newValue) }
    }

    var traktClientSecret: String {
        get { secureString("trakt_client_secret", default: "") }
        set { setSecureString("trakt_client_secret", newValue) }
    }

    var traktAccessToken: String {
        get { secureString("trakt_access_token", default: "") }
        set { setSecureString("trakt_access_token", newValue) }
    }

    var traktRefreshToken: String {
        get { secureString("trakt_refresh_token", default: "") }
        set { setSecureString("trakt_refresh_token", newValue) }
    }

    var traktUsername: String {
        get { string("trakt_username", default: "") }
        set { setString("trakt_username", newValue) }
    }

    var traktScrobbleEnabled: Bool {
        get { bool("trakt_scrobble_enabled", default: true) }
        set { setBool("trakt_scrobble_enabled", newValue) }
    }

    var isTraktAuthenticated: Bool { !traktAccessToken.isEmpty }
    var canStartTraktAuth: Bool { !traktClientId.isEmpty && !traktClientSecret.isEmpty }

    func clearTraktSession() {
        traktAccessToken = ""
        traktRefreshToken = ""
        traktUsername = ""
    }

    // MARK: - Simkl

    var simklClientId: String {
        get { string("simkl_client_id", default: "") }
        set { setString("simkl_client_id", newValue) }
    }

    var simklAccessToken: String {
        get { secureString("simkl_access_token", default: "") }
        set { setSecureString("simkl_access_token", newValue) }
    }

    var simklUsername: String {
        get { string("simkl_username", default: "") }
        set { setString("simkl_username", newValue) }
    }

    var simklScrobbleEnabled: Bool {
        get { bool("simkl_scrobble_enabled", default: true) }
        set { setBool("simkl_scrobble_enabled", newValue) }
    }

    var isSimklAuthenticated: Bool { !simklAccessToken.isEmpty }
    var canStartSimklAuth: Bool { !simklClientId.isEmpty }

    func clearSimklSession() {
        simklAccessToken = ""
        simklUsername = ""
    }
}

// MARK: - TMDB (port of TmdbSettingsDataStore)

@Observable
@MainActor
final class TmdbSettingsStore: PreferenceStore {
    init() { super.init(namespace: "tmdb") }

    override var secureKeys: Set<String> { ["tmdb_api_key"] }

    var enabled: Bool {
        get { bool("tmdb_enabled", default: false) }
        set { setBool("tmdb_enabled", newValue) }
    }

    var apiKey: String {
        get { secureString("tmdb_api_key", default: "") }
        set { setSecureString("tmdb_api_key", newValue) }
    }

    var language: String {
        get { string("tmdb_language", default: "en-US") }
        set { setString("tmdb_language", newValue) }
    }

    var useArtwork: Bool {
        get { bool("tmdb_use_artwork", default: true) }
        set { setBool("tmdb_use_artwork", newValue) }
    }

    var useBasicInfo: Bool {
        get { bool("tmdb_use_basic_info", default: true) }
        set { setBool("tmdb_use_basic_info", newValue) }
    }

    var useCredits: Bool {
        get { bool("tmdb_use_credits", default: true) }
        set { setBool("tmdb_use_credits", newValue) }
    }

    var useDetails: Bool {
        get { bool("tmdb_use_details", default: true) }
        set { setBool("tmdb_use_details", newValue) }
    }

    var useEpisodes: Bool {
        get { bool("tmdb_use_episodes", default: true) }
        set { setBool("tmdb_use_episodes", newValue) }
    }

    var useTrailers: Bool {
        get { bool("tmdb_use_trailers", default: true) }
        set { setBool("tmdb_use_trailers", newValue) }
    }

    var useNetworks: Bool {
        get { bool("tmdb_use_networks", default: true) }
        set { setBool("tmdb_use_networks", newValue) }
    }

    var useProductions: Bool {
        get { bool("tmdb_use_productions", default: true) }
        set { setBool("tmdb_use_productions", newValue) }
    }

    var useReleaseDates: Bool {
        get { bool("tmdb_use_release_dates", default: true) }
        set { setBool("tmdb_use_release_dates", newValue) }
    }

    var useMoreLikeThis: Bool {
        get { bool("tmdb_use_more_like_this", default: true) }
        set { setBool("tmdb_use_more_like_this", newValue) }
    }

    var enrichContinueWatching: Bool {
        get { bool("tmdb_enrich_continue_watching", default: true) }
        set { setBool("tmdb_enrich_continue_watching", newValue) }
    }

    var isUsable: Bool { enabled && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: - MDBList (port of MDBListSettingsDataStore)

@Observable
@MainActor
final class MDBListSettingsStore: PreferenceStore {
    init() { super.init(namespace: "mdblist") }

    override var secureKeys: Set<String> { ["mdblist_api_key"] }

    var enabled: Bool {
        get { bool("mdblist_enabled", default: false) }
        set { setBool("mdblist_enabled", newValue) }
    }

    var apiKey: String {
        get { secureString("mdblist_api_key", default: "") }
        set { setSecureString("mdblist_api_key", newValue) }
    }

    var showImdb: Bool {
        get { bool("mdblist_show_imdb", default: true) }
        set { setBool("mdblist_show_imdb", newValue) }
    }

    var showTmdb: Bool {
        get { bool("mdblist_show_tmdb", default: true) }
        set { setBool("mdblist_show_tmdb", newValue) }
    }

    var showTomatoes: Bool {
        get { bool("mdblist_show_tomatoes", default: true) }
        set { setBool("mdblist_show_tomatoes", newValue) }
    }

    var showAudience: Bool {
        get { bool("mdblist_show_audience", default: true) }
        set { setBool("mdblist_show_audience", newValue) }
    }

    var showMetacritic: Bool {
        get { bool("mdblist_show_metacritic", default: true) }
        set { setBool("mdblist_show_metacritic", newValue) }
    }

    var showTrakt: Bool {
        get { bool("mdblist_show_trakt", default: false) }
        set { setBool("mdblist_show_trakt", newValue) }
    }

    var showLetterboxd: Bool {
        get { bool("mdblist_show_letterboxd", default: false) }
        set { setBool("mdblist_show_letterboxd", newValue) }
    }

    var showMal: Bool {
        get { bool("mdblist_show_mal", default: false) }
        set { setBool("mdblist_show_mal", newValue) }
    }

    var isUsable: Bool { enabled && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: - Skip intro (port of AnimeSkipSettingsDataStore)

@Observable
@MainActor
final class SkipIntroSettingsStore: PreferenceStore {
    init() { super.init(namespace: "skipintro") }

    var animeSkipEnabled: Bool {
        get { bool("animeskip_enabled", default: false) }
        set { setBool("animeskip_enabled", newValue) }
    }

    var animeSkipClientId: String {
        get { string("animeskip_client_id", default: "") }
        set { setString("animeskip_client_id", newValue) }
    }

    /// Overrides IntroDB's endpoint. Empty means the public one — see
    /// `SkipIntroClient.introDbDefaultBaseURL`. Kept so a self-hosted instance can be pointed at,
    /// not because anything has to be configured for skip marks to work.
    ///
    /// There is deliberately no "AniSkip on/off" here. The official app has no such setting —
    /// AniSkip needs no account and always runs — and an inert toggle that suggests otherwise is
    /// worse than none.
    var introDbApiUrl: String {
        get { string("introdb_api_url", default: "") }
        set { setString("introdb_api_url", newValue) }
    }

    /// Which kinds of segment are jumped without waiting for the button.
    ///
    /// A set rather than a pair of booleans, because the three kinds are genuinely independent:
    /// skipping the outro automatically ejects you from the end of an episode, which is a very
    /// different appetite from skipping an opening. Empty by default, as upstream.
    ///
    /// The `auto_skip_intro` and `auto_skip_outro` keys this replaces were never read by
    /// anything, so nothing is migrated — there is no setting to carry over.
    var autoSkipSegmentKinds: Set<SkipSegment.Kind> {
        get { Set(stringList("auto_skip_segment_kinds").compactMap(SkipSegment.Kind.init(rawValue:))) }
        set { setStringList("auto_skip_segment_kinds", newValue.map(\.rawValue).sorted()) }
    }

    func autoSkips(_ kind: SkipSegment.Kind) -> Bool {
        autoSkipSegmentKinds.contains(kind)
    }

    func setAutoSkip(_ kind: SkipSegment.Kind, _ enabled: Bool) {
        var kinds = autoSkipSegmentKinds
        if enabled { kinds.insert(kind) } else { kinds.remove(kind) }
        autoSkipSegmentKinds = kinds
    }
}

// MARK: - Stream badges (port of StreamBadgeSettingsDataStore)

@Observable
@MainActor
final class StreamBadgeSettingsStore: PreferenceStore {
    init() { super.init(namespace: "streambadge") }

    var placement: StreamBadgePlacement {
        get { option("stream_badge_placement", default: .inline) }
        set { setOption("stream_badge_placement", newValue) }
    }

    var showAddonLogo: Bool {
        get { bool("show_addon_logo", default: true) }
        set { setBool("show_addon_logo", newValue) }
    }

    var showFileSizeBadges: Bool {
        get { bool("show_file_size_badges", default: true) }
        set { setBool("show_file_size_badges", newValue) }
    }

    var showSeederBadges: Bool {
        get { bool("show_seeder_badges", default: true) }
        set { setBool("show_seeder_badges", newValue) }
    }

    var showCacheBadges: Bool {
        get { bool("show_cache_badges", default: true) }
        set { setBool("show_cache_badges", newValue) }
    }
}

// MARK: - Trailers (port of TrailerSettingsDataStore)

@Observable
@MainActor
/// Kept, deliberately empty, so the account keeps round-tripping Android's `trailer` namespace.
///
/// Hero trailers cannot exist on this platform: Stremio trailers are YouTube ids, tvOS has no
/// WKWebView, and AVPlayer cannot resolve a YouTube watch page — the same reason
/// `TrailerLauncher` hands off to the YouTube app instead of playing anything itself. So there
/// are no properties here and no settings rows: an inert switch would have been a promise this
/// client cannot keep.
///
/// The store still exists because `PreferenceStore.importFromSync` persists whatever keys arrive
/// and `exportForSync` writes them back out, declared or not. Dropping the namespace from
/// `syncedStores` is what would lose Android's values, not dropping the properties.
final class TrailerSettingsStore: PreferenceStore {
    init() { super.init(namespace: "trailer") }
}
