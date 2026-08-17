import SwiftUI

struct RootView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(Router.self) private var router
    @Environment(AddonStore.self) private var addons
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var router = router

        NavigationStack(path: $router.path) {
            SidebarScaffold {
                tabContent
            }
            .navigationDestination(for: Route.self) { route in
                destination(for: route)
            }
        }
        .background(colors.background)
        .environment(\.posterMetrics, settings.posterMetrics)
        .environment(\.cardDepth, settings.cardDepthStyle)
        .environment(\.navigationFeel, settings.navigationFeel)
        .fullScreenCover(item: $router.playback) { request in
            PlayerView(request: request)
        }
        .task {
            await addons.refreshAll()
        }
        // The addon store owns catalog ordering but the preference lives in Layout settings.
        .onChange(of: settings.layout.followAddonsOrder, initial: true) { _, follows in
            addons.followsAddonOrder = follows
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch router.selectedTab {
        case .home: HomeView()
        case .discover: DiscoverView()
        case .search: SearchView()
        case .library: LibraryView()
        case .settings: SettingsView()
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .detail(let request):
            MetaDetailsView(request: request)
        case .streams(let request):
            StreamsView(request: request)
        case .catalogSeeAll(let request):
            CatalogSeeAllView(request: request)
        case .castMember(let request):
            CastDetailView(request: request)
        case .tmdbBrowse(let request):
            TMDBBrowseView(request: request)
        case .addonManager:
            AddonManagerView()
        case .catalogOrder:
            CatalogOrderView()
        case .themeSettings:
            ThemeSettingsView()
        case .layoutSettings:
            LayoutSettingsView()
        case .playbackSettings:
            PlaybackSettingsView()
        case .about:
            AboutView()
        }
    }
}

/// Shared page chrome for the pushed screens — full-bleed background plus the TV-safe inset
/// the Compose screens get from `NuvioLayout.tvSafe*`.
struct NuvioScreenBackground<Content: View>: View {
    @Environment(\.nuvioColors) private var colors
    var horizontalPadding: CGFloat = NuvioTheme.layout.tvSafeHorizontal
    var verticalPadding: CGFloat = NuvioTheme.layout.tvSafeVertical
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            colors.background.ignoresSafeArea()
            content
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
