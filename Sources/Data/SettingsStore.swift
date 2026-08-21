import SwiftUI
import Observation

// MARK: - Layout modes (port of HomeLayout / ExperienceMode / ContinueWatchingCardStyle)

enum HomeLayout: String, SettingsOption {
    case classic = "CLASSIC", grid = "GRID", modern = "MODERN"

    var displayName: String {
        switch self {
        case .classic: return "Classic View"
        case .grid: return "Grid View"
        case .modern: return "Modern View"
        }
    }

    var summary: String {
        switch self {
        case .classic: return "Focused backdrop with poster rails underneath."
        case .grid: return "Dense grid of catalogs, no hero."
        case .modern: return "Full-bleed hero carousel with floating rails."
        }
    }
}

enum ExperienceMode: String, SettingsOption {
    case essential = "ESSENTIAL", advanced = "ADVANCED"

    var displayName: String { self == .essential ? "Essential" : "Advanced" }

    var summary: String {
        switch self {
        case .essential: return "A trimmed set of options for a simple, get-out-of-the-way setup."
        case .advanced: return "Every playback, addon and integration control Nuvio exposes."
        }
    }
}

enum ContinueWatchingCardStyle: String, SettingsOption {
    case poster = "POSTER", landscape = "LANDSCAPE"
    var displayName: String { self == .poster ? "Poster" : "Landscape" }
}

// MARK: - Theme & shell settings (port of ThemeDataStore + ExperienceModeDataStore)

@Observable
@MainActor
final class SettingsStore: PreferenceStore {
    init() { super.init(namespace: "app") }

    var theme: AppTheme {
        get { option("selected_theme", default: .crimson) }
        set { setOption("selected_theme", newValue) }
    }

    var font: AppFont {
        get { option("selected_font", default: .inter) }
        set { setOption("selected_font", newValue) }
    }

    var amoledMode: Bool {
        get { bool("amoled_mode", default: false) }
        set { setBool("amoled_mode", newValue) }
    }

    var amoledSurfaces: Bool {
        get { bool("amoled_surfaces_mode", default: false) }
        set { setBool("amoled_surfaces_mode", newValue) }
    }

    /// `advanced_remember_last_profile`: reopen the profile that was active at shutdown.
    var remembersLastProfile: Bool {
        get { bool("remember_last_profile", default: true) }
        set { setBool("remember_last_profile", newValue) }
    }

    var settingsUIStyle: SettingsUIStyle {
        get { option("settings_ui_style", default: .rail) }
        set { setOption("settings_ui_style", newValue) }
    }

    var experienceMode: ExperienceMode {
        get { option("experience_mode", default: .advanced) }
        set { setOption("experience_mode", newValue) }
    }

    var experienceModeChosen: Bool {
        get { bool("experience_mode_chosen", default: false) }
        set { setBool("experience_mode_chosen", newValue) }
    }

    /// Essential mode hides the deep playback/integration surfaces, matching Android.
    var showsAdvancedSettings: Bool { experienceMode == .advanced }

    var colors: NuvioColorScheme {
        NuvioColorScheme(
            palette: ThemeColors.palette(for: theme),
            amoledMode: amoledMode,
            amoledSurfaces: amoledSurfaces
        )
    }
}

// MARK: - Aggregate

/// One handle on every settings store, so views take a single environment object instead of
/// nine, and so cross-cutting reads (e.g. the watched threshold) have one obvious home.
@Observable
@MainActor
final class AppSettings {
    let app = SettingsStore()
    let player = PlayerSettingsStore()
    let layout = LayoutSettingsStore()
    let debrid = DebridSettingsStore()
    let tracking = TrackingSettingsStore()
    let tmdb = TmdbSettingsStore()
    let mdblist = MDBListSettingsStore()
    let skipIntro = SkipIntroSettingsStore()
    let streamBadges = StreamBadgeSettingsStore()
    let trailers = TrailerSettingsStore()

    /// Fraction of a video that counts as watched — used by Continue Watching and episode ticks.
    var watchedThreshold: Double { player.watchedThresholdFraction }

    /// Resolved poster geometry, injected into the environment so every rail and grid picks up
    /// the viewer's Layout settings instead of the static tokens.
    var posterMetrics: PosterMetrics {
        PosterMetrics(
            width: dp(CGFloat(layout.posterCardWidthDp)),
            height: dp(CGFloat(layout.posterCardHeightDp)),
            cornerRadius: dp(CGFloat(layout.posterCardCornerRadiusDp)),
            showsLabels: layout.posterLabelsEnabled,
            preferLandscape: layout.modernLandscapePostersEnabled,
            backdropExpandEnabled: layout.focusedPosterBackdropExpandEnabled,
            backdropExpandDelay: layout.focusedPosterBackdropExpandDelaySeconds,
            showsFullReleaseDate: layout.showFullReleaseDate
        )
    }

    /// Subtitle appearance, shared by the overlay that draws addon tracks and the style rules
    /// applied to tracks embedded in the stream.
    var subtitleStyle: SubtitleStyle {
        SubtitleStyle(
            sizeScale: player.subtitleSize,
            bold: player.subtitleBold,
            textColor: Color(argbHex: player.subtitleTextColor),
            backgroundColor: Color(argbHex: player.subtitleBackgroundColor),
            outlineEnabled: player.subtitleOutlineEnabled,
            outlineColor: Color(argbHex: player.subtitleOutlineColor),
            outlineWidth: player.subtitleOutlineWidth,
            verticalOffset: player.subtitleVerticalOffset,
            assOverride: player.subtitleStyleOverride.mpvValue,
            stripsSDH: player.subtitleStripSDH
        )
    }

    /// Track languages in preference order, with the placeholders resolved. mpv takes the list
    /// and picks the best match; an empty list leaves the choice to the file.
    private func trackLanguages(_ preferred: String, _ fallback: String) -> [String] {
        [preferred, fallback]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { value -> [String] in
                switch value {
                case "": return []
                case "device": return [Locale.current.language.languageCode?.identifier].compactMap { $0 }
                default: return [MediaLanguage.normalise(value)]
                }
            }
            .reduce(into: [String]()) { list, code in
                if !list.contains(code) { list.append(code) }
            }
    }

    var audioTrackLanguages: [String] {
        trackLanguages(player.preferredAudioLanguage, player.secondaryPreferredAudioLanguage)
    }

    var subtitleTrackLanguages: [String] {
        trackLanguages(player.subtitlePreferredLanguage, player.subtitleSecondaryLanguage)
    }

    var navigationFeel: NavigationFeel {
        NavigationFeel(
            fastHorizontal: layout.fastHorizontalNavigationEnabled,
            smoothBringIntoView: layout.smoothBringIntoViewEnabled
        )
    }

    var catalogPresentation: CatalogPresentation {
        CatalogPresentation(
            showsAddonName: layout.catalogAddonNameEnabled,
            showsTypeSuffix: layout.catalogTypeSuffixEnabled,
            customTitles: layout.customCatalogTitles,
            hidesUnreleased: layout.hideUnreleasedContent,
            showsFullReleaseDate: layout.showFullReleaseDate
        )
    }

    var cardDepthStyle: CardDepthStyle {
        guard layout.cardDepthEnabled else { return .disabled }
        return CardDepthStyle(
            posters: layout.cardDepthPostersEnabled,
            continueWatching: layout.cardDepthContinueWatchingEnabled,
            episodes: layout.cardDepthEpisodeCardsEnabled,
            cast: layout.cardDepthCastEnabled,
            trailers: layout.cardDepthTrailersEnabled,
            edgeStrength: layout.cardDepthEdgeStrength,
            edgeCoverage: layout.cardDepthEdgeCoverage,
            sheenStrength: layout.cardDepthSheenStrength
        )
    }

    // MARK: - Account sync

    /// Namespaced stores, in the order the settings blob carries them.
    private var syncedStores: [(String, PreferenceStore)] {
        [
            ("app", app), ("player", player), ("layout", layout), ("debrid", debrid),
            ("tracking", tracking), ("tmdb", tmdb), ("mdblist", mdblist),
            ("skipIntro", skipIntro), ("streamBadges", streamBadges), ("trailers", trailers)
        ]
    }

    /// When this device last changed a setting, used to decide which side of the sync wins.
    /// `PreferenceStore` stamps it on every write.
    var settingsUpdatedAt: Date? {
        let value = UserDefaults.standard.double(forKey: PreferenceStore.syncStampKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    /// One object per namespace, so a key cannot collide across stores.
    func exportSyncedSettings() -> [String: AnyJSONValue] {
        var out: [String: AnyJSONValue] = [:]
        for (name, store) in syncedStores {
            out[name] = .object(store.exportForSync())
        }
        return out
    }

    func importSyncedSettings(_ payload: [String: AnyJSON]) {
        for (name, store) in syncedStores {
            guard case .object(let values)? = payload[name] else { continue }
            store.importFromSync(values)
        }
    }

    var tmdbOptions: TMDBClient.TMDBOptions {
        TMDBClient.TMDBOptions(
            useArtwork: tmdb.useArtwork,
            useBasicInfo: tmdb.useBasicInfo,
            useCredits: tmdb.useCredits,
            useDetails: tmdb.useDetails,
            useTrailers: tmdb.useTrailers,
            useNetworks: tmdb.useNetworks,
            useProductions: tmdb.useProductions,
            useReleaseDates: tmdb.useReleaseDates,
            useMoreLikeThis: tmdb.useMoreLikeThis
        )
    }

    var streamFilterInput: StreamFilterEngine.Input {
        StreamFilterEngine.Input(
            minimumQuality: debrid.streamMinimumQuality,
            dolbyVisionFilter: debrid.streamDolbyVisionFilter,
            hdrFilter: debrid.streamHdrFilter,
            codecFilter: debrid.streamCodecFilter,
            sortMode: debrid.streamSortMode,
            maxResults: debrid.streamMaxResults,
            preferences: debrid.streamPreferences
        )
    }
}
