import SwiftUI

struct HomeView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router
    @Environment(RemoteProgressService.self) private var remoteProgress

    @State private var model = HomeViewModel()

    /// True while the only thing on screen is the spinner, which offers nothing to focus.
    private var isShowingSpinner: Bool {
        (model.isInitialLoading || addons.isRefreshing) && model.rows.allSatisfy(\.items.isEmpty)
    }

    var body: some View {
        Group {
            if isShowingSpinner {
                NuvioLoadingView(message: "Loading catalogs…")
            } else if let error = model.loadError, model.rows.isEmpty {
                EmptyStateView(
                    systemImage: "puzzlepiece.extension",
                    title: "Nothing to show yet",
                    message: error,
                    actionTitle: "Open Addon Manager",
                    action: { router.push(.addonManager) }
                )
            } else {
                layout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.background)
        .task(id: addons.catalogSignature) {
            await model.load(addonStore: addons, presentation: settings.catalogPresentation)
        }
        // Continue Watching from a tracking account rather than this device, when that is what
        // the viewer asked for. A no-op on the local setting, which is the default.
        .task(id: settings.effectiveWatchProgressSource) {
            await remoteProgress.refreshIfNeeded(settings: settings, library: library, addons: addons)
            await remoteProgress.enrichContinueWatching(
                library.continueWatching(
                    threshold: settings.watchedThreshold,
                    withinDays: settings.tracking.continueWatchingDaysCap,
                    nextUp: settings.nextUpOptions
                ),
                settings: settings,
                library: library
            )
        }
        .onChange(of: settings.catalogPresentation) { _, presentation in
            model.apply(presentation: presentation)
        }
        .onChange(of: settings.layout.heroCatalogKeys, initial: true) { _, keys in
            model.heroCatalogKeys = Set(keys)
        }
        .onChange(of: isShowingSpinner, initial: true) { _, spinning in
            router.contentHasFocusableViews = !spinning
        }
        .onDisappear { router.contentHasFocusableViews = true }
    }

    @ViewBuilder
    private var layout: some View {
        switch settings.layout.selectedLayout {
        case .modern: ModernHomeContent(model: model)
        case .classic: ClassicHomeContent(model: model)
        case .grid: GridHomeContent(model: model)
        }
    }
}

// MARK: - Shared rail list

/// The rail stack shared by all three home layouts.
struct HomeRailList: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CollectionStore.self) private var collections
    @Environment(AddonStore.self) private var addons
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let model: HomeViewModel
    var allowsBackdropExpand: Bool = true

    @FocusState private var focusedCardKey: String?
    @State private var didClaimInitialFocus = false

    private var continueWatching: [ContinueWatchingEntry] {
        // Gated here rather than at the row, so the rail is also absent from the focus order
        // and from `firstCardKey` — a hidden row that still takes the first press is worse than
        // no setting at all.
        guard settings.layout.continueWatchingEnabled else { return [] }
        return library.continueWatching(
            threshold: settings.watchedThreshold,
            sort: settings.layout.continueWatchingSortMode,
            withinDays: settings.tracking.continueWatchingDaysCap,
            nextUp: settings.nextUpOptions
        )
    }

    /// The card that should own focus when Home first has something to show — Continue
    /// Watching wins when present, then whatever leads the rails.
    private var firstCardKey: String? {
        continueWatching.first?.preview.rowKey
            ?? pinnedCollections.first?.folders.first?.id
            ?? displayRows.compactMap { row -> String? in
                switch row {
                case .catalog(let catalog): return catalog.items.first?.rowKey
                case .collection(let collection): return collection.folders.first?.id
                }
            }.first
    }

    /// Pinned collections lead the screen, ahead of every catalogue; the rest follow them.
    /// `CollectionStore.homePlacement` carries the rule and the reasoning.
    private var homeCollections: (leading: [MediaCollection], trailing: [MediaCollection]) {
        guard settings.layout.collectionsOnHomeEnabled else { return ([], []) }
        return collections.homePlacement
    }

    private var pinnedCollections: [MediaCollection] { homeCollections.leading }
    private var trailingCollections: [MediaCollection] { homeCollections.trailing }

    /// One rail, of either kind.
    private enum DisplayRow: Identifiable {
        case catalog(CatalogRowState)
        case collection(MediaCollection)

        var id: String {
            switch self {
            case .catalog(let row): return row.id
            case .collection(let collection): return collection.homeRowKey
            }
        }
    }

    /// Catalogues and unpinned collections in the single order the viewer arranged, which is how
    /// upstream builds its home rows — a collection is an equal in that list, not something
    /// appended after it.
    private var displayRows: [DisplayRow] {
        let unpinned = trailingCollections
        guard !unpinned.isEmpty else { return model.rows.map(DisplayRow.catalog) }

        let rowsByKey = Dictionary(model.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let collectionsById = Dictionary(unpinned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return addons.orderedHomeRows(collectionIds: unpinned.map(\.id)).compactMap { key in
            switch key {
            case .catalog(let catalogKey): return rowsByKey[catalogKey].map(DisplayRow.catalog)
            case .collection(let id): return collectionsById[id].map(DisplayRow.collection)
            }
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: NuvioTheme.spacing.rail.rowGap) {
            if !continueWatching.isEmpty {
                ContinueWatchingRow(
                    entries: continueWatching,
                    style: settings.layout.continueWatchingCardStyle,
                    onFocusItem: { model.focusedItem = $0 },
                    onSelect: { entry in
                        router.openDetail(entry.preview)
                    },
                    cardFocus: $focusedCardKey
                )
            }

            ForEach(pinnedCollections) { collection in
                CollectionRail(
                    collection: collection,
                    focusBinding: $focusedCardKey,
                    onFocusItem: { model.focusedItem = $0 }
                )
            }

            ForEach(displayRows) { entry in
                switch entry {
                case .catalog(let row):
                    if !row.items.isEmpty || row.isLoading {
                        CatalogRowView(
                            title: row.title,
                            subtitle: row.subtitle,
                            items: row.items,
                            isLoading: row.isLoading || row.isLoadingMore,
                            backdropExpandEnabled: allowsBackdropExpand,
                            onFocusItem: { model.focusedItem = $0 },
                            onSelect: { router.openDetail($0) },
                            onSeeAll: { router.push(.catalogSeeAll(row.request)) },
                            onReachEnd: {
                                Task { await model.loadMore(row) }
                            },
                            cardFocus: $focusedCardKey
                        )
                    }
                case .collection(let collection):
                    CollectionRail(
                        collection: collection,
                        focusBinding: $focusedCardKey,
                        onFocusItem: { model.focusedItem = $0 }
                    )
                }
            }
        }
        // Claim focus for the content the moment there is a card to hold it. Without this the
        // sidebar pill — the only focusable view while the catalogs load — keeps focus and the
        // panel stays bloomed open, which is not how the app starts on Android.
        .onChange(of: firstCardKey, initial: true) { _, key in
            guard !didClaimInitialFocus, let key else { return }
            didClaimInitialFocus = true
            Task { @MainActor in
                // The card is not registered with the focus engine on the first runloop pass, so
                // a single assignment is silently dropped and the engine parks focus on the
                // sidebar instead. Retry until it sticks.
                //
                // The check has to happen *after* a sleep, never straight after the write:
                // `@FocusState` read back immediately returns what was just written, whether or
                // not the engine accepted it. The old loop asked "did that work?" one line after
                // asking for it, always got yes, and gave up after a single attempt — so whether
                // the content or the menu held focus at launch came down to whether the catalogue
                // had painted within 250ms.
                for delay in [150, 250, 400, 600, 900, 1400] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    // Non-nil here means something in the content has focus — the card we asked
                    // for, or one the viewer has since moved to. Either way, leave it alone.
                    guard focusedCardKey == nil else { return }
                    focusedCardKey = key
                }
            }
        }
    }
}

// MARK: - Modern layout (port of ModernHomeContent / ModernHomeHero)

struct ModernHomeContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(\.shellLeadingInset) private var shellLeadingInset
    let model: HomeViewModel

    private var showsHero: Bool { settings.layout.heroSectionEnabled }
    /// `modern_hero_full_screen_backdrop`: the artwork covers the whole frame and the
    /// gradient reaches further right, instead of being confined to the hero band.
    private var fullScreenBackdrop: Bool { settings.layout.modernHeroFullScreenBackdrop }

    /// The height the rails scroll inside. The hero takes the rest and **does not scroll**.
    ///
    /// That is the whole point of the Modern layout: the details at the top describe the card you
    /// are on, so they cannot slide away the moment you touch a rail. Ours had the hero and the
    /// rails in one scroll view, so focusing the first poster pushed the hero half off the top.
    ///
    /// Android hard-codes this at 0.52 of the screen (0.49 with landscape posters). That works
    /// there because its poster size is fixed; here it is a setting — Layout → Poster cards lets
    /// a viewer ask for 330dp-tall posters — so a fixed fraction would clip the row labels for
    /// anyone who changed it, which is exactly what 0.52 did at the default size. Derived from
    /// the row's own parts instead, and clamped so the hero cannot be squeezed out.
    private func rowsViewportHeight(in total: CGFloat) -> CGFloat {
        let metrics = settings.posterMetrics
        let rowTitle = dp(26) + NuvioTheme.components.row.titleBottomSpacing
        // Reserved for the tallest state the row can reach, not the one it starts in: a card
        // expanded into its backdrop grows a metadata line and two lines of synopsis under it,
        // and sizing for the collapsed label alone cut the synopsis off at the screen edge.
        let labels: CGFloat
        if metrics.showsLabels {
            labels = metrics.backdropExpandEnabled ? dp(76) : dp(52)
        } else {
            labels = 0
        }
        let oneRow = rowTitle + NuvioTheme.components.row.verticalPadding * 2 + metrics.height + labels
        return min(max(oneRow, total * 0.42), total * 0.62)
    }

    var body: some View {
        GeometryReader { proxy in
            let rowsHeight = showsHero ? rowsViewportHeight(in: proxy.size.height) : proxy.size.height

            ZStack(alignment: .topLeading) {
                if showsHero {
                    // Back under the menu column and out through the safe margin. The rest of
                    // the stack does not move: see `bleedingLeading`.
                    heroBackdrop(
                        size: proxy.size,
                        bleed: shellLeadingInset + proxy.safeAreaInsets.leading
                    )
                }

                VStack(alignment: .leading, spacing: 0) {
                    if showsHero {
                        ModernHeroInfo(item: model.heroItem)
                            .frame(
                                height: proxy.size.height - rowsHeight,
                                alignment: .bottomLeading
                            )
                            .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)
                    }

                    ScrollView(.vertical, showsIndicators: false) {
                        // The viewport clips, as Android's does: rows scrolled past the top
                        // would otherwise paint over the hero they are meant to describe.
                        HomeRailList(model: model)
                            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
                    }
                    .frame(height: rowsHeight)
                }
            }
        }
        .ignoresSafeArea()
    }

    /// `bleed` is how much of the screen the shell's menu column and the television's own safe
    /// margin took off the left. Every frame here is widened by it and the whole layer slid back
    /// over them, so the artwork — and the gradient that keeps the menu legible on top of it —
    /// runs to the physical edge of the panel.
    private func heroBackdrop(size: CGSize, bleed: CGFloat) -> some View {
        let width = size.width + max(0, bleed)
        let height = fullScreenBackdrop ? size.height : size.height * 0.82

        return ZStack(alignment: .topLeading) {
            RemoteImage(url: model.heroItem?.backdropUrl, contentMode: .fill) {
                colors.background
            }
            .frame(width: width, height: height, alignment: .top)
            .clipped()
            .animation(NuvioMotion.slowTween, value: model.heroItem?.rowKey)

            ModernHeroGradient(background: colors.background, fullScreen: fullScreenBackdrop)
                .frame(width: width, height: height)
        }
        .frame(width: width, height: size.height, alignment: .top)
        .bleedingLeading(by: bleed)
    }
}

/// Port of `ModernHeroGradientLayer` — a horizontal fade over the left 45% of the frame
/// plus a bottom strip that grounds the rails.
struct ModernHeroGradient: View {
    let background: Color
    var fullScreen: Bool = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    stops: horizontalStops,
                    startPoint: .leading,
                    endPoint: UnitPoint(x: fullScreen ? 0.65 : 0.45, y: 0.5)
                )

                LinearGradient(
                    stops: verticalStops,
                    startPoint: UnitPoint(x: 0.5, y: fullScreen ? 0.64 : 0.82),
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    private var horizontalStops: [Gradient.Stop] {
        if fullScreen {
            return [
                .init(color: background, location: 0),
                .init(color: background.opacity(0.90), location: 0.22),
                .init(color: background.opacity(0.80), location: 0.46),
                .init(color: background.opacity(0.42), location: 0.76),
                .init(color: .clear, location: 1)
            ]
        }
        return [
            .init(color: background, location: 0),
            .init(color: background.opacity(0.86), location: 0.22),
            .init(color: background.opacity(0.56), location: 0.46),
            .init(color: background.opacity(0.16), location: 0.76),
            .init(color: .clear, location: 1)
        ]
    }

    private var verticalStops: [Gradient.Stop] {
        if fullScreen {
            return [
                .init(color: .clear, location: 0),
                .init(color: background.opacity(0.35), location: 0.30),
                .init(color: background.opacity(0.75), location: 0.60),
                .init(color: background, location: 1)
            ]
        }
        return [
            .init(color: .clear, location: 0),
            .init(color: background.opacity(0.25), location: 0.40),
            .init(color: background.opacity(0.65), location: 0.75),
            .init(color: background, location: 1)
        ]
    }
}

/// Port of the hero text column: logo (or title), metadata row, description.
struct ModernHeroInfo: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    let item: MetaPreview?
    @State private var logoFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
            Spacer(minLength: 0)

            if let item {
                titleBlock(item)

                if !metaTokens(item).isEmpty {
                    HStack(spacing: NuvioTheme.spacing.md) {
                        ForEach(Array(metaTokens(item).enumerated()), id: \.offset) { index, token in
                            if index > 0 {
                                Circle()
                                    .fill(colors.textSecondary.opacity(0.6))
                                    .frame(width: dp(4), height: dp(4))
                            }
                            Text(token)
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(colors.textSecondary)
                        }
                    }
                }

                if let description = item.description?.nilIfBlank {
                    Text(description)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: dp(520), alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(NuvioMotion.mediumTween, value: item?.rowKey)
    }

    @ViewBuilder
    private func titleBlock(_ item: MetaPreview) -> some View {
        if let logo = item.logo?.nilIfBlank, !logoFailed {
            RemoteImage(url: logo, contentMode: .fit, onFailure: { logoFailed = true }) {
                Color.clear
            }
            .frame(height: dp(100), alignment: .leading)
            .frame(minWidth: dp(100), maxWidth: dp(220), alignment: .leading)
        } else {
            Text(item.name)
                .nuvioText(NuvioTextStyles.display)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: dp(760), alignment: .leading)
        }
    }

    private func metaTokens(_ item: MetaPreview) -> [String] {
        var tokens: [String] = []
        if let info = item.releaseInfo?.nilIfBlank { tokens.append(info) }
        if settings.layout.homeRatingsVisibility.showsRatings, let rating = item.imdbRating {
            tokens.append(String(format: "★ %.1f", rating))
        }
        if let runtime = item.runtime?.nilIfBlank { tokens.append(runtime) }
        if let age = item.ageRating?.nilIfBlank { tokens.append(age) }
        if !item.genres.isEmpty { tokens.append(item.genres.prefix(3).joined(separator: ", ")) }
        return tokens
    }
}

// MARK: - Classic layout (port of ClassicHomeContent / ClassicFocusGradientBackdrop)

struct ClassicHomeContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(\.shellLeadingInset) private var shellLeadingInset
    let model: HomeViewModel

    private var showsHero: Bool { settings.layout.heroSectionEnabled }
    /// `classic_focus_gradient_enabled`: without it Classic drops the backdrop wash entirely
    /// and sits the rails on the flat background.
    private var showsFocusGradient: Bool { settings.layout.classicFocusGradientEnabled }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if showsFocusGradient {
                    // Classic keeps the backdrop as a soft, heavily scrimmed wash behind the
                    // rails — reaching the same edge Modern's does.
                    let bleed = shellLeadingInset + proxy.safeAreaInsets.leading
                    RemoteImage(url: model.heroItem?.backdropUrl, contentMode: .fill) {
                        colors.background
                    }
                    .frame(width: proxy.size.width + max(0, bleed), height: proxy.size.height * 0.75)
                    .clipped()
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: colors.background.opacity(0.55), location: 0),
                                .init(color: colors.background.opacity(0.88), location: 0.55),
                                .init(color: colors.background, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .animation(NuvioMotion.slowTween, value: model.heroItem?.rowKey)
                    .bleedingLeading(by: bleed)
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                        if showsHero {
                            ModernHeroInfo(item: model.heroItem)
                                .frame(height: proxy.size.height * 0.42, alignment: .bottomLeading)
                                .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)
                                .padding(.top, NuvioTheme.layout.tvSafeVertical)
                        }

                        HomeRailList(model: model)
                            .padding(.top, showsHero ? 0 : NuvioTheme.layout.tvSafeVertical)
                            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
                    }
                }
                .scrollClipDisabled()
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Grid layout (port of GridHomeContent)

struct GridHomeContent: View {
    @Environment(\.nuvioColors) private var colors
    let model: HomeViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.rail.rowGap) {
                Text(L10n.text("navigation.home"))
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
                    .padding(.top, NuvioTheme.layout.tvSafeVertical)

                // Grid view drops the hero entirely and disables the focus-expand animation
                // so the denser rail stack stays visually stable.
                HomeRailList(model: model, allowsBackdropExpand: false)
                    .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
            }
        }
        .scrollClipDisabled()
        .background(colors.background)
    }
}
