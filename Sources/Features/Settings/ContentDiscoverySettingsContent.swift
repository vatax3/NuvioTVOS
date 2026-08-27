import SwiftUI

/// Content & Discovery — port of `ContentDiscoverySettingsContent`. The official app groups
/// addons, plugins and catalog ordering here rather than giving each a rail entry of its own.
struct ContentDiscoverySettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(PluginStore.self) private var plugins
    @Environment(CollectionStore.self) private var collections
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    /// Plugins are an advanced-mode surface, matching `showPlugins` on Android.
    private var showsPlugins: Bool { settings.app.showsAdvancedSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: L10n.text("settings.discovery.sources", fallback: "Sources"),
                footnote: L10n.text("settings.discovery.sources_footnote", fallback: "Add-ons, plugins, catalogs and discovery sources.")
            ) {
                SettingsRow(
                    title: L10n.text("settings.discovery.addons", fallback: "Add-ons"),
                    subtitle: "\(addons.installed.count) installed · \(addons.enabledAddons.count) enabled",
                    systemImage: "square.grid.2x2",
                    trailing: { SettingsValueLabel(value: "") },
                    action: { router.push(.addonManager) }
                )
                SettingsRow(
                    title: L10n.text("settings.discovery.catalog_order", fallback: "Catalog order"),
                    subtitle: L10n.text("settings.discovery.catalog_order_sub", fallback: "Choose which catalogs appear on Home and in what order"),
                    systemImage: "list.number",
                    trailing: { SettingsValueLabel(value: "") },
                    action: { router.push(.catalogOrder) }
                )
                SettingsRow(
                    title: L10n.text("settings.discovery.collections", fallback: "Collections"),
                    subtitle: collectionSubtitle,
                    systemImage: "folder",
                    trailing: { SettingsValueLabel(value: "") },
                    action: { router.push(.collectionManager) }
                )
                if showsPlugins {
                    SettingsRow(
                        title: L10n.text("settings.discovery.plugins", fallback: "Plugins"),
                        subtitle: pluginSubtitle,
                        systemImage: "wrench.and.screwdriver",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { router.push(.pluginManager) }
                    )
                    SettingsRow(
                        title: L10n.text("settings.discovery.repositories", fallback: "Repositories"),
                        subtitle: L10n.text("settings.discovery.repositories_sub", fallback: "Add or remove plugin repositories from a phone"),
                        systemImage: "shippingbox",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { router.push(.repositoryConfig) }
                    )
                }
            }

            DiscoverySettingsCard()
        }
    }

    private var collectionSubtitle: String {
        let count = collections.collections.count
        guard count > 0 else { return L10n.text("settings.discovery.collections_sub", fallback: "Folders of catalogs, TMDB searches and Trakt lists") }
        let folders = collections.collections.reduce(0) { $0 + $1.folders.count }
        return "\(count) collection\(count == 1 ? "" : "s") · \(folders) folder\(folders == 1 ? "" : "s")"
    }

    private var pluginSubtitle: String {
        let repositories = plugins.repositories.count
        let enabled = plugins.enabledScrapers.count
        guard repositories > 0 else { return L10n.text("settings.discovery.plugins_sub", fallback: "Local JavaScript scrapers") }
        return "\(repositories) repositor\(repositories == 1 ? "y" : "ies") · \(enabled) scraper\(enabled == 1 ? "" : "s") active"
    }
}

/// The discovery half: where Discover lives and how catalogs are labelled.
struct DiscoverySettingsCard: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var layout = settings.layout

        Group {
            SettingsCard(title: L10n.text("settings.discovery.discover", fallback: "Discover")) {
                SettingsOptionRow(
                    title: L10n.text("settings.discovery.discover_placement", fallback: "Discover placement"),
                    systemImage: "square.grid.2x2",
                    selection: $layout.discoverLocation
                )
                SettingsToggle(
                    title: L10n.text("settings.discovery.discover_in_search", fallback: "Discover inside Search"),
                    subtitle: L10n.text("settings.discovery.discover_in_search_sub", fallback: "Show the catalog browser when the search field is empty"),
                    isOn: $layout.searchDiscoverEnabled
                )
            }

            SettingsCard(title: L10n.text("settings.discovery.catalog_titles", fallback: "Catalog titles")) {
                SettingsToggle(
                    title: L10n.text("settings.discovery.show_addon_name", fallback: "Show addon name"),
                    subtitle: L10n.text("settings.discovery.show_addon_name_sub", fallback: "Next to each rail title"),
                    isOn: $layout.catalogAddonNameEnabled
                )
                SettingsToggle(
                    title: L10n.text("settings.discovery.show_type_suffix", fallback: "Show type suffix"),
                    subtitle: L10n.text("settings.discovery.show_type_suffix_sub", fallback: "Append Movies / Series to rail titles"),
                    isOn: $layout.catalogTypeSuffixEnabled
                )
                SettingsToggle(
                    title: L10n.text("settings.discovery.follow_addon_order", fallback: "Follow addon order"),
                    subtitle: L10n.text("settings.discovery.follow_addon_order_sub", fallback: "Order rails by the addon list rather than manually"),
                    isOn: $layout.followAddonsOrder
                )
            }

            SettingsCard(title: L10n.text("settings.discovery.content", fallback: "Content")) {
                SettingsToggle(
                    title: L10n.text("settings.discovery.hide_unreleased", fallback: "Hide unreleased content"),
                    subtitle: L10n.text("settings.discovery.hide_unreleased_sub", fallback: "Drop titles whose release date is still in the future"),
                    isOn: $layout.hideUnreleasedContent
                )
                SettingsToggle(
                    title: L10n.text("settings.discovery.full_dates", fallback: "Show full release dates"),
                    subtitle: L10n.text("settings.discovery.full_dates_sub", fallback: "Rather than just the year"),
                    isOn: $layout.showFullReleaseDate
                )
                SettingsToggle(
                    title: L10n.text("settings.discovery.prefer_external", fallback: "Prefer external metadata addon"),
                    subtitle: L10n.text("settings.discovery.prefer_external_sub", fallback: "Ask a dedicated metadata addon before the catalog's own"),
                    isOn: $layout.preferExternalMetaAddonDetail
                )
            }
        }
    }
}

// MARK: - Integrations hub

/// Port of `IntegrationSettingsContent`: a hub listing Debrid, TMDB, MDBList and Anime-Skip,
/// each opening in place rather than as its own rail entry.
struct IntegrationsHubContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    enum Section: String, CaseIterable, Identifiable {
        case hub, debrid, tmdb, mdblist, animeSkip
        var id: String { rawValue }

        var title: String {
            switch self {
            case .hub: return L10n.text("settings.discovery.integrations", fallback: "Integrations")
            case .debrid: return "Debrid"
            case .tmdb: return "TMDB"
            case .mdblist: return "MDBList"
            case .animeSkip: return "Anime-Skip"
            }
        }

        var subtitle: String {
            switch self {
            case .hub: return ""
            case .debrid: return L10n.text("settings.discovery.debrid_sub", fallback: "Real-Debrid, Premiumize and TorBox, plus stream filtering")
            case .tmdb: return L10n.text("settings.discovery.tmdb_sub", fallback: "Better artwork, logos, cast and recommendations")
            case .mdblist: return L10n.text("settings.discovery.mdblist_sub", fallback: "Aggregated ratings on the detail screen")
            case .animeSkip: return L10n.text("settings.discovery.animeskip_sub", fallback: "Skip anime intros and outros")
            }
        }
    }

    @State private var section: Section = .hub

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            if section != .hub {
                SettingsRow(
                    title: L10n.text("settings.discovery.back_to_integrations", fallback: "Back to integrations"),
                    systemImage: "chevron.left",
                    action: { section = .hub }
                )
            }

            switch section {
            case .hub:
                SettingsCard(title: L10n.text("settings.discovery.integrations", fallback: "Integrations")) {
                    ForEach(Section.allCases.filter { $0 != .hub }) { entry in
                        SettingsRow(
                            title: entry.title,
                            subtitle: entry.subtitle,
                            trailing: { SettingsValueLabel(value: statusLabel(for: entry)) },
                            action: { section = entry }
                        )
                    }
                }
            case .debrid:
                DebridSettingsContent()
            case .tmdb:
                TmdbSettingsCard()
            case .mdblist:
                MDBListSettingsCard()
            case .animeSkip:
                AnimeSkipSettingsCard()
            }
        }
    }

    /// A hub row says whether the integration is actually set up, which the Android hub also does.
    private func statusLabel(for entry: Section) -> String {
        switch entry {
        case .hub: return ""
        case .debrid: return settings.debrid.enabled && settings.debrid.activeResolver != nil ? L10n.text("settings.discovery.on", fallback: "On") : L10n.text("settings.discovery.off", fallback: "Off")
        case .tmdb: return settings.tmdb.enabled && !settings.tmdb.apiKey.isEmpty ? L10n.text("settings.discovery.on", fallback: "On") : L10n.text("settings.discovery.off", fallback: "Off")
        case .mdblist: return settings.mdblist.enabled && !settings.mdblist.apiKey.isEmpty ? L10n.text("settings.discovery.on", fallback: "On") : L10n.text("settings.discovery.off", fallback: "Off")
        case .animeSkip:
            // IntroDB and AniSkip always run, so the card is never truly "off" — what this
            // reports is whether the viewer added anything to them.
            let skip = settings.skipIntro
            return skip.animeSkipEnabled || !skip.autoSkipSegmentKinds.isEmpty ? L10n.text("settings.discovery.on", fallback: "On") : L10n.text("settings.discovery.off", fallback: "Off")
        }
    }
}
