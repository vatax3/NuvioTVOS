import SwiftUI

struct RootView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(Router.self) private var router
    @Environment(AddonStore.self) private var addons
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(CollectionStore.self) private var collections
    @Environment(PluginStore.self) private var plugins
    @Environment(ProfileStore.self) private var profiles
    @Environment(NuvioAccountStore.self) private var account
    @Environment(NuvioSyncService.self) private var sync
    @Environment(\.scenePhase) private var scenePhase

    /// Latched once at appearance rather than recomputed: the walk-through must not vanish
    /// under the viewer the moment they install their first add-on in step three.
    @State private var showsFirstRun: Bool?

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
        .fullScreenCover(isPresented: Binding(
            get: { showsFirstRun == true },
            set: { if !$0 { showsFirstRun = false } }
        )) {
            FirstRunView { showsFirstRun = false }
        }
        .onAppear {
            guard showsFirstRun == nil else { return }
            showsFirstRun = FirstRunView.shouldPresent(settings: settings, addons: addons)
        }
        .environment(\.posterMetrics, settings.posterMetrics)
        .environment(\.cardDepth, settings.cardDepthStyle)
        .environment(\.navigationFeel, settings.navigationFeel)
        // Presented here rather than per-rail: the same gesture has to reach the same dialog
        // from Home, Discover, Search, Library and every collection folder.
        .fullScreenCover(item: $router.posterOptions) { request in
            PosterOptionsDialog(request: request) { router.posterOptions = nil }
        }
        .fullScreenCover(item: $router.playback) { request in
            PlayerView(request: request)
                // Replacing a source remains in the same full-screen presentation, but the
                // decoder must be rebuilt for the new URL rather than retaining the old engine.
                .id(request.id)
                // What Menu means during playback is decided in one place — `PlayerExitPolicy`,
                // which closes a panel before it hides the transport and hides the transport
                // before it ends playback. The presentation must not have an opinion of its
                // own: any press that slips past the player's own handling and reaches the
                // presentation controller would tear playback down mid-panel, which is the
                // failure this guards. Playback still ends the moment the player calls
                // `dismiss()` — that is not interactive dismissal.
                .interactiveDismissDisabled()
        }
        .task {
            #if DEBUG
            // Opens playback directly, so the UI tests can exercise the transport's focus
            // behaviour without an account, an addon or a stream picker in the way. Inert
            // unless the launch argument is passed.
            if let harness = PlayerHarness.request() { router.playback = harness }
            #endif
            // "Add Profile" and the long-press gesture leave the chooser asking for the
            // Profiles settings rather than Home.
            if profiles.consumeProfileManagementRequest() {
                router.select(.settings)
            }
            await addons.refreshAll()
            // Startup sync, the equivalent of Android's StartupSyncService. Runs after the addon
            // refresh so a pulled addon list lands on top of resolved manifests.
            syncAccount()
        }
        // Playback closing is the moment watch progress is worth pushing.
        .onChange(of: router.playback == nil) { _, closed in
            if closed { syncAccount() }
        }
        // Signing in is the other one. Waiting for the next launch to pull a library the viewer
        // has just proved they own makes the sign-in look as though it did nothing.
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn { syncAccount() }
        }
        // And coming back to the app: a television is left running for days, so "at launch"
        // can mean "a week ago". What was watched on a phone this afternoon should be here.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { syncAccount() }
        }
        // The addon store owns catalog ordering but the preference lives in Layout settings.
        .onChange(of: settings.layout.followAddonsOrder, initial: true) { _, follows in
            addons.followsAddonOrder = follows
        }
        .onOpenURL { url in
            guard let deepLink = DeepLink.parse(url) else { return }
            router.open(deepLink)
        }
    }

    private func syncAccount() {
        guard account.isSignedIn else { return }
        sync.sync(
            account: account,
            library: library,
            collections: collections,
            addons: addons,
            plugins: plugins,
            profiles: profiles,
            settings: settings
        )
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
        case .collectionFolder(let request):
            CollectionFolderView(request: request)
        case .comments(let request):
            CommentsView(
                imdbId: request.imdbId,
                contentType: request.contentType,
                title: request.title
            )
        case .qrSignIn:
            AuthQrSignInView()
        case .addonManager:
            AddonManagerView()
        case .pluginManager:
            PluginManagerView()
        case .collectionManager:
            CollectionManagerView()
        case .streamFormat:
            StreamFormatEditorView()
        case .streamBadgeRules:
            StreamBadgeRulesView()
        case .repositoryConfig:
            RepositoryConfigView()
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
        // `horizontalPadding` *is* the overscan allowance — it is `tvSafeHorizontal`. Laying it
        // out inside the platform's own 80pt margin charged for the same thing twice and put a
        // pushed screen's content 176pt into a 1920pt one. `SidebarScaffold` takes the same
        // ownership for the screens that live inside it; this keeps a pushed screen in step with
        // them. Vertical is left alone.
        .ignoresSafeArea(edges: .horizontal)
    }
}
