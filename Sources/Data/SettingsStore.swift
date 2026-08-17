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
            verticalOffset: player.subtitleVerticalOffset
        )
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
