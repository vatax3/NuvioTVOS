import SwiftUI

/// Port of `LibraryScreen` — saved titles plus everything currently in progress.
struct LibraryView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.posterMetrics) private var metrics
    @Environment(LibraryStore.self) private var library
    @Environment(CollectionStore.self) private var collections
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    enum Filter: String, CaseIterable, Identifiable {
        case all, movies, series, continueWatching, collections
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .movies: return "Movies"
            case .series: return "Series"
            case .continueWatching: return "Continue Watching"
            case .collections: return "Collections"
            }
        }
    }

    @State private var filter: Filter = .all

    private var columns: [GridItem] { metrics.gridColumns() }

    private var continueWatching: [ContinueWatchingEntry] {
        library.continueWatching(
            threshold: settings.watchedThreshold,
            sort: settings.layout.continueWatchingSortMode,
            withinDays: settings.tracking.continueWatchingDaysCap
        )
    }

    private var savedItems: [MetaPreview] {
        let items = library.library.map(\.preview)
        switch filter {
        case .all, .continueWatching, .collections: return items
        case .movies: return items.filter { $0.type == .movie }
        case .series: return items.filter { $0.type == .series }
        }
    }

    private var remoteTypeFilter: ContentType? {
        switch filter {
        case .movies: return .movie
        case .series: return .series
        case .all, .continueWatching, .collections: return nil
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                Text(L10n.text("navigation.library"))
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

                ChipRow(title: "Filter") {
                    ForEach(Filter.allCases) { option in
                        NuvioChip(
                            label: option.title,
                            isSelected: filter == option,
                            action: { filter = option }
                        )
                    }
                }

                CloudLibrarySection()

                content
            }
            .padding(.top, NuvioTheme.layout.tvSafeVertical)
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        .scrollClipDisabled()
        .background(colors.background)
        // The tab is restored rather than reset. `@State` cannot read the environment at
        // initialisation, so it is seeded here and written back on every change.
        .task { filter = Filter(rawValue: settings.layout.libraryFilter) ?? .all }
        .onChange(of: filter) { _, selection in
            settings.layout.libraryFilter = selection.rawValue
        }
    }

    @ViewBuilder
    private var content: some View {
        if filter == .continueWatching {
            if continueWatching.isEmpty {
                emptyState(
                    icon: "play.circle",
                    title: "Nothing in progress",
                    message: "Titles you start watching show up here."
                )
            } else {
                ContinueWatchingRow(
                    entries: continueWatching,
                    style: settings.layout.continueWatchingCardStyle,
                    onSelect: { router.openDetail($0.preview) }
                )
            }
        } else if settings.effectiveLibrarySourceMode == .trakt {
            TraktLibraryContent(typeFilter: remoteTypeFilter)
        } else if settings.effectiveLibrarySourceMode == .simkl {
            SimklLibraryContent(typeFilter: remoteTypeFilter)
        } else if filter == .collections {
            collectionsContent
        } else if savedItems.isEmpty {
            emptyState(
                icon: "bookmark",
                title: "Your library is empty",
                message: "Open any title and press Add to Library to keep it here."
            )
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                ForEach(savedItems, id: \.rowKey) { item in
                    ContentCard(
                        item: item,
                        allowsBackdropExpand: false,
                        action: { router.openDetail(item) }
                    )
                }
            }
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
        }
    }

    /// One rail per collection, each rail a row of its folders.
    ///
    /// Browsing only. Building a collection means choosing catalogues, TMDB queries and Trakt
    /// lists, which is a settings job rather than something to do over a grid of posters — the
    /// editor lives next to Add-ons and Plugins.
    @ViewBuilder
    private var collectionsContent: some View {
        if collections.collections.isEmpty {
            EmptyStateView(
                systemImage: "folder",
                title: "No collections yet",
                message: "A collection is a set of folders, and a folder is a live query — an addon catalog, a TMDB search, a Trakt list. Build one in Settings → Sources → Collections.",
                actionTitle: "Open Collections",
                action: { router.push(.collectionManager) }
            )
            .frame(height: dp(340))
        } else {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.rail.rowGap) {
                ForEach(collections.ordered) { collection in
                    CollectionRail(collection: collection)
                }
            }
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        EmptyStateView(systemImage: icon, title: title, message: message)
            .frame(height: dp(340))
    }
}

// MARK: - See all

/// Port of `CatalogSeeAllScreen` — a paged grid for one catalog.
struct CatalogSeeAllView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.posterMetrics) private var metrics
    @Environment(AddonStore.self) private var addons
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let request: CatalogRequest

    @State private var items: [MetaPreview] = []
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var error: String?

    private var columns: [GridItem] { metrics.gridColumns() }

    /// `hide_unreleased_content` applies here as well as on Home; paging still runs against
    /// the unfiltered list so a hidden item does not stall the next page.
    private var visibleItems: [MetaPreview] {
        settings.catalogPresentation.filter(items)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                Text(request.title)
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

                if visibleItems.isEmpty && isLoading {
                    PosterSkeletonRow(showsTitle: false)
                } else if visibleItems.isEmpty {
                    EmptyStateView(
                        systemImage: "rectangle.on.rectangle",
                        title: "Empty catalog",
                        message: error ?? "This catalog returned no items."
                    )
                    .frame(height: dp(340))
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.rowKey) { index, item in
                            ContentCard(
                                item: item,
                                allowsBackdropExpand: false,
                                onFocus: { _ in
                                    if index >= visibleItems.count - 14 { Task { await loadMore() } }
                                },
                                action: { router.openDetail(item) }
                            )
                        }
                    }
                    .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

                    if isLoading {
                        ProgressView()
                            .tint(colors.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.top, NuvioTheme.layout.tvSafeVertical)
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        .scrollClipDisabled()
        .background(colors.background)
        .task { await loadFirstPage() }
    }

    private var addon: Addon? { addons.addon(withBaseUrl: request.addonBaseUrl) }

    private func loadFirstPage() async {
        guard items.isEmpty, !isLoading, let addon else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var extras: [(String, String)] = []
            if let genre = request.genre { extras.append(("genre", genre)) }
            if let search = request.search { extras.append(("search", search)) }
            items = try await StremioClient.shared.fetchCatalog(
                addon: addon, type: request.type, catalogId: request.catalogId, extraArgs: extras
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !isLoading, !reachedEnd, let addon else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var extras: [(String, String)] = []
            if let genre = request.genre { extras.append(("genre", genre)) }
            if let search = request.search { extras.append(("search", search)) }
            let page = try await StremioClient.shared.fetchCatalog(
                addon: addon, type: request.type, catalogId: request.catalogId,
                skip: items.count, extraArgs: extras
            )
            let existing = Set(items.map(\.rowKey))
            let additions = page.filter { !existing.contains($0.rowKey) }
            if additions.isEmpty { reachedEnd = true } else { items.append(contentsOf: additions) }
        } catch {
            reachedEnd = true
        }
    }
}
