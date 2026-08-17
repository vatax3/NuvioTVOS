import SwiftUI

/// Content & Discovery — port of `ContentDiscoverySettingsContent`. The official app groups
/// addons, plugins and catalog ordering here rather than giving each a rail entry of its own.
struct ContentDiscoverySettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(PluginStore.self) private var plugins
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    /// Plugins are an advanced-mode surface, matching `showPlugins` on Android.
    private var showsPlugins: Bool { settings.app.showsAdvancedSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "Sources",
                footnote: "Add-ons, plugins, catalogs and discovery sources."
            ) {
                SettingsRow(
                    title: "Add-ons",
                    subtitle: "\(addons.installed.count) installed · \(addons.enabledAddons.count) enabled",
                    systemImage: "square.grid.2x2",
                    trailing: { SettingsValueLabel(value: "") },
                    action: { router.push(.addonManager) }
                )
                SettingsRow(
                    title: "Catalog order",
                    subtitle: "Choose which catalogs appear on Home and in what order",
                    systemImage: "list.number",
                    trailing: { SettingsValueLabel(value: "") },
                    action: { router.push(.catalogOrder) }
                )
                if showsPlugins {
                    SettingsRow(
                        title: "Plugins",
                        subtitle: pluginSubtitle,
                        systemImage: "wrench.and.screwdriver",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { router.push(.pluginManager) }
                    )
                }
            }

            DiscoverySettingsCard()
        }
    }

    private var pluginSubtitle: String {
        let repositories = plugins.repositories.count
        let enabled = plugins.enabledScrapers.count
        guard repositories > 0 else { return "Local JavaScript scrapers" }
        return "\(repositories) repositor\(repositories == 1 ? "y" : "ies") · \(enabled) scraper\(enabled == 1 ? "" : "s") active"
    }
}

/// The discovery half: where Discover lives and how catalogs are labelled.
struct DiscoverySettingsCard: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var layout = settings.layout

        Group {
            SettingsCard(title: "Discover") {
                SettingsOptionRow(
                    title: "Discover placement",
                    systemImage: "square.grid.2x2",
                    selection: $layout.discoverLocation
                )
                SettingsToggle(
                    title: "Discover inside Search",
                    subtitle: "Show the catalog browser when the search field is empty",
                    isOn: $layout.searchDiscoverEnabled
                )
            }

            SettingsCard(title: "Catalog titles") {
                SettingsToggle(
                    title: "Show addon name",
                    subtitle: "Next to each rail title",
                    isOn: $layout.catalogAddonNameEnabled
                )
                SettingsToggle(
                    title: "Show type suffix",
                    subtitle: "Append Movies / Series to rail titles",
                    isOn: $layout.catalogTypeSuffixEnabled
                )
                SettingsToggle(
                    title: "Follow addon order",
                    subtitle: "Order rails by the addon list rather than manually",
                    isOn: $layout.followAddonsOrder
                )
            }

            SettingsCard(title: "Content") {
                SettingsToggle(
                    title: "Hide unreleased content",
                    subtitle: "Drop titles whose release date is still in the future",
                    isOn: $layout.hideUnreleasedContent
                )
                SettingsToggle(
                    title: "Show full release dates",
                    subtitle: "Rather than just the year",
                    isOn: $layout.showFullReleaseDate
                )
                SettingsToggle(
                    title: "Prefer external metadata addon",
                    subtitle: "Ask a dedicated metadata addon before the catalog's own",
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
            case .hub: return "Integrations"
            case .debrid: return "Debrid"
            case .tmdb: return "TMDB"
            case .mdblist: return "MDBList"
            case .animeSkip: return "Anime-Skip"
            }
        }

        var subtitle: String {
            switch self {
            case .hub: return ""
            case .debrid: return "Real-Debrid, Premiumize and TorBox, plus stream filtering"
            case .tmdb: return "Better artwork, logos, cast and recommendations"
            case .mdblist: return "Aggregated ratings on the detail screen"
            case .animeSkip: return "Skip anime intros and outros"
            }
        }
    }

    @State private var section: Section = .hub

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            if section != .hub {
                SettingsRow(
                    title: "Back to integrations",
                    systemImage: "chevron.left",
                    action: { section = .hub }
                )
            }

            switch section {
            case .hub:
                SettingsCard(title: "Integrations") {
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
        case .debrid: return settings.debrid.enabled && settings.debrid.activeResolver != nil ? "On" : "Off"
        case .tmdb: return settings.tmdb.enabled && !settings.tmdb.apiKey.isEmpty ? "On" : "Off"
        case .mdblist: return settings.mdblist.enabled && !settings.mdblist.apiKey.isEmpty ? "On" : "Off"
        case .animeSkip:
            let skip = settings.skipIntro
            return skip.aniSkipEnabled || skip.animeSkipEnabled ? "On" : "Off"
        }
    }
}
