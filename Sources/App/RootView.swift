import SwiftUI

struct RootView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(Router.self) private var router
    @Environment(AddonStore.self) private var addons
    @Environment(SettingsStore.self) private var settings

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
        .fullScreenCover(item: $router.playback) { request in
            PlayerView(request: request)
        }
        .task {
            await addons.refreshAll()
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
