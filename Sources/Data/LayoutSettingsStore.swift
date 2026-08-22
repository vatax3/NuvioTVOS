import Foundation
import Observation

/// Port of `LayoutPreferenceDataStore` — home layout, poster metrics, card depth, hero and
/// sidebar behaviour. Keys match the Android preference names.
@Observable
@MainActor
final class LayoutSettingsStore: PreferenceStore {
    init() { super.init(namespace: "layout") }

    // MARK: - Layout choice

    var selectedLayout: HomeLayout {
        get { option("selected_layout", default: .modern) }
        set { setOption("selected_layout", newValue) }
    }

    var hasChosenLayout: Bool {
        get { bool("has_chosen_layout", default: false) }
        set { setBool("has_chosen_layout", newValue) }
    }

    // MARK: - Sidebar

    var modernSidebarEnabled: Bool {
        get { bool("modern_sidebar_enabled", default: true) }
        set { setBool("modern_sidebar_enabled", newValue) }
    }

    var modernSidebarBlurEnabled: Bool {
        get { bool("modern_sidebar_blur_enabled", default: true) }
        set { setBool("modern_sidebar_blur_enabled", newValue) }
    }

    var sidebarCollapsedByDefault: Bool {
        get { bool("sidebar_collapsed_by_default", default: true) }
        set { setBool("sidebar_collapsed_by_default", newValue) }
    }

    var glassSidePanelEnabled: Bool {
        get { bool("glass_sidepanel_enabled", default: true) }
        set { setBool("glass_sidepanel_enabled", newValue) }
    }

    // MARK: - Hero

    var heroSectionEnabled: Bool {
        get { bool("hero_section_enabled", default: true) }
        set { setBool("hero_section_enabled", newValue) }
    }

    var modernHeroFullScreenBackdrop: Bool {
        get { bool("modern_hero_full_screen_backdrop", default: true) }
        set { setBool("modern_hero_full_screen_backdrop", newValue) }
    }

    var classicFocusGradientEnabled: Bool {
        get { bool("classic_focus_gradient_enabled", default: true) }
        set { setBool("classic_focus_gradient_enabled", newValue) }
    }

    var heroCatalogKeys: [String] {
        get { stringList("hero_catalog_keys") }
        set { setStringList("hero_catalog_keys", newValue) }
    }

    // MARK: - Poster cards

    var posterCardWidthDp: Int {
        get { int("poster_card_width_dp", default: 126) }
        set { setInt("poster_card_width_dp", newValue) }
    }

    var posterCardHeightDp: Int {
        get { int("poster_card_height_dp", default: 189) }
        set { setInt("poster_card_height_dp", newValue) }
    }

    var posterCardCornerRadiusDp: Int {
        get { int("poster_card_corner_radius_dp", default: 12) }
        set { setInt("poster_card_corner_radius_dp", newValue) }
    }

    var posterLabelsEnabled: Bool {
        get { bool("poster_labels_enabled", default: true) }
        set { setBool("poster_labels_enabled", newValue) }
    }

    var modernLandscapePostersEnabled: Bool {
        get { bool("modern_landscape_posters_enabled", default: false) }
        set { setBool("modern_landscape_posters_enabled", newValue) }
    }

    // MARK: - Focused poster expansion

    var focusedPosterBackdropExpandEnabled: Bool {
        get { bool("focused_poster_backdrop_expand_enabled", default: true) }
        set { setBool("focused_poster_backdrop_expand_enabled", newValue) }
    }

    var focusedPosterBackdropExpandDelaySeconds: Int {
        get { int("focused_poster_backdrop_expand_delay_seconds", default: 3) }
        set { setInt("focused_poster_backdrop_expand_delay_seconds", newValue) }
    }

    /// Collections as rails on Home, after the addon catalogues — where Android puts them by
    /// default. Without this they existed only inside the Library's Collections tab, which is
    /// somewhere you have to already know to look.
    var collectionsOnHomeEnabled: Bool {
        get { bool("collections_on_home_enabled", default: true) }
        set { setBool("collections_on_home_enabled", newValue) }
    }

    // MARK: - Library

    /// The library's type tab, kept across launches. Picking "Series" every single time you open
    /// the library is the kind of small tax that only shows up in use, never in a screenshot.
    /// Stored as the raw tab name so the view owns the list of tabs, not the settings layer.
    var libraryFilter: String {
        get { string("library_filter", default: "all") }
        set { setString("library_filter", newValue) }
    }

    /// Same, for the debrid cloud list. Empty means "every type".
    var cloudLibraryTypeFilter: String {
        get { string("cloud_library_type_filter", default: "") }
        set { setString("cloud_library_type_filter", newValue) }
    }

    // MARK: - Card depth

    var cardDepthEnabled: Bool {
        get { bool("card_depth_enabled", default: true) }
        set { setBool("card_depth_enabled", newValue) }
    }

    var cardDepthPostersEnabled: Bool {
        get { bool("card_depth_posters_enabled", default: true) }
        set { setBool("card_depth_posters_enabled", newValue) }
    }

    var cardDepthContinueWatchingEnabled: Bool {
        get { bool("card_depth_continue_watching_enabled", default: true) }
        set { setBool("card_depth_continue_watching_enabled", newValue) }
    }

    var cardDepthEpisodeCardsEnabled: Bool {
        get { bool("card_depth_episode_cards_enabled", default: true) }
        set { setBool("card_depth_episode_cards_enabled", newValue) }
    }

    var cardDepthCastEnabled: Bool {
        get { bool("card_depth_cast_enabled", default: false) }
        set { setBool("card_depth_cast_enabled", newValue) }
    }

    var cardDepthTrailersEnabled: Bool {
        get { bool("card_depth_trailers_enabled", default: false) }
        set { setBool("card_depth_trailers_enabled", newValue) }
    }

    var cardDepthEdgeStrength: Double {
        get { double("card_depth_edge_strength", default: 0.5) }
        set { setDouble("card_depth_edge_strength", newValue) }
    }

    var cardDepthEdgeCoverage: Double {
        get { double("card_depth_edge_coverage", default: 0.35) }
        set { setDouble("card_depth_edge_coverage", newValue) }
    }

    var cardDepthSheenStrength: Double {
        get { double("card_depth_sheen_strength", default: 0.4) }
        set { setDouble("card_depth_sheen_strength", newValue) }
    }

    // MARK: - Catalog presentation

    var catalogAddonNameEnabled: Bool {
        get { bool("catalog_addon_name_enabled", default: true) }
        set { setBool("catalog_addon_name_enabled", newValue) }
    }

    var catalogTypeSuffixEnabled: Bool {
        get { bool("catalog_type_suffix_enabled", default: false) }
        set { setBool("catalog_type_suffix_enabled", newValue) }
    }

    var followAddonsOrder: Bool {
        get { bool("follow_addons_order", default: true) }
        set { setBool("follow_addons_order", newValue) }
    }

    // Ordering and per-catalog enablement live in `AddonStore.catalogOrder`, which is
    // file-backed and already drives `orderedHomeCatalogs`. Mirroring them here as preference
    // keys would give two sources of truth for the same list.

    var customCatalogTitles: [String: String] {
        get { codable("custom_catalog_titles", default: [:]) }
        set { setCodable("custom_catalog_titles", newValue) }
    }

    // MARK: - Continue Watching

    var continueWatchingCardStyle: ContinueWatchingCardStyle {
        get { option("continue_watching_card_style", default: .landscape) }
        set { setOption("continue_watching_card_style", newValue) }
    }

    var continueWatchingSortMode: ContinueWatchingSortMode {
        get { option("continue_watching_sort_mode", default: .recentlyWatched) }
        set { setOption("continue_watching_sort_mode", newValue) }
    }

    var useEpisodeThumbnailsInContinueWatching: Bool {
        get { bool("use_episode_thumbnails_in_cw", default: true) }
        set { setBool("use_episode_thumbnails_in_cw", newValue) }
    }

    var blurContinueWatchingNextUp: Bool {
        get { bool("blur_continue_watching_next_up", default: false) }
        set { setBool("blur_continue_watching_next_up", newValue) }
    }

    var blurUnwatchedEpisodes: Bool {
        get { bool("blur_unwatched_episodes", default: false) }
        set { setBool("blur_unwatched_episodes", newValue) }
    }

    var nextUpFromFurthestEpisode: Bool {
        get { bool("next_up_from_furthest_episode", default: true) }
        set { setBool("next_up_from_furthest_episode", newValue) }
    }

    var showUnairedNextUp: Bool {
        get { bool("show_unaired_next_up", default: false) }
        set { setBool("show_unaired_next_up", newValue) }
    }

    // MARK: - Discover & search

    var discoverLocation: DiscoverLocation {
        get { option("discover_location", default: .sidebar) }
        set { setOption("discover_location", newValue) }
    }

    var searchDiscoverEnabled: Bool {
        get { bool("search_discover_enabled", default: true) }
        set { setBool("search_discover_enabled", newValue) }
    }

    // MARK: - Content presentation

    var hideUnreleasedContent: Bool {
        get { bool("hide_unreleased_content", default: false) }
        set { setBool("hide_unreleased_content", newValue) }
    }

    var showFullReleaseDate: Bool {
        get { bool("show_full_release_date", default: false) }
        set { setBool("show_full_release_date", newValue) }
    }

    var detailPageTrailerButtonEnabled: Bool {
        get { bool("detail_page_trailer_button_enabled", default: true) }
        set { setBool("detail_page_trailer_button_enabled", newValue) }
    }

    var preferExternalMetaAddonDetail: Bool {
        get { bool("prefer_external_meta_addon_detail", default: false) }
        set { setBool("prefer_external_meta_addon_detail", newValue) }
    }

    // MARK: - Navigation feel

    var fastHorizontalNavigationEnabled: Bool {
        get { bool("fast_horizontal_navigation_enabled", default: true) }
        set { setBool("fast_horizontal_navigation_enabled", newValue) }
    }

    var smoothBringIntoViewEnabled: Bool {
        get { bool("smooth_bring_into_view_enabled", default: true) }
        set { setBool("smooth_bring_into_view_enabled", newValue) }
    }

    // `memory_only_vertical_scroll` is not carried over: it exists on Android because Compose
    // persists LazyColumn offsets across navigation. SwiftUI rebuilds the stack instead, so the
    // behaviour the preference opts into is already the only behaviour here.
}
