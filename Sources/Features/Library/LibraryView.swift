import SwiftUI

/// Port of `LibraryScreen` — saved titles plus everything currently in progress.
struct LibraryView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(Router.self) private var router

    private enum Filter: String, CaseIterable, Identifiable {
        case all, movies, series, continueWatching
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .movies: return "Movies"
            case .series: return "Series"
            case .continueWatching: return "Continue Watching"
            }
        }
    }

    @State private var filter: Filter = .all

    private let columns = Array(
        repeating: GridItem(.fixed(NuvioTheme.components.posterCard.width), spacing: NuvioTheme.components.row.itemSpacing),
        count: 7
    )

    private var continueWatching: [ContinueWatchingEntry] {
        library.continueWatching(threshold: settings.resumeThresholdPercent)
    }

    private var savedItems: [MetaPreview] {
        let items = library.library.map(\.preview)
        switch filter {
        case .all, .continueWatching: return items
        case .movies: return items.filter { $0.type == .movie }
        case .series: return items.filter { $0.type == .series }
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                Text("Library")
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

                content
            }
            .padding(.top, NuvioTheme.layout.tvSafeVertical)
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        .scrollClipDisabled()
        .background(colors.background)
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
                    style: settings.continueWatchingStyle,
                    onSelect: { router.openDetail($0.preview) }
                )
            }
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
                        backdropExpandEnabled: false,
                        action: { router.openDetail(item) }
                    )
                }
            }
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
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
    @Environment(AddonStore.self) private var addons
    @Environment(Router.self) private var router

    let request: CatalogRequest

    @State private var items: [MetaPreview] = []
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var error: String?

    private let columns = Array(
        repeating: GridItem(.fixed(NuvioTheme.components.posterCard.width), spacing: NuvioTheme.components.row.itemSpacing),
        count: 7
    )

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                Text(request.title)
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

                if items.isEmpty && isLoading {
                    PosterSkeletonRow(showsTitle: false)
                } else if items.isEmpty {
                    EmptyStateView(
                        systemImage: "rectangle.on.rectangle",
                        title: "Empty catalog",
                        message: error ?? "This catalog returned no items."
                    )
                    .frame(height: dp(340))
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                        ForEach(Array(items.enumerated()), id: \.element.rowKey) { index, item in
                            ContentCard(
                                item: item,
                                backdropExpandEnabled: false,
                                onFocus: { _ in
                                    if index >= items.count - 14 { Task { await loadMore() } }
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
