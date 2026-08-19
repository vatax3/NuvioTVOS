import SwiftUI
import Observation

@Observable
@MainActor
final class SearchViewModel {
    var query: String = ""
    private(set) var results: [SearchSection] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false

    private let client: StremioClient
    private var searchTask: Task<Void, Never>?

    struct SearchSection: Identifiable {
        let addonName: String
        let catalogName: String
        let items: [MetaPreview]
        var id: String { "\(addonName)#\(catalogName)" }
    }

    init(client: StremioClient = .shared) {
        self.client = client
    }

    /// Debounced so each remote keystroke does not fan out to every addon.
    func scheduleSearch(addonStore: AddonStore) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            hasSearched = false
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await search(addonStore: addonStore, term: trimmed)
        }
    }

    func search(addonStore: AddonStore, term: String) async {
        let catalogs = addonStore.searchableCatalogs()
        guard !catalogs.isEmpty else {
            results = []
            hasSearched = true
            return
        }

        isSearching = true
        hasSearched = true
        defer { isSearching = false }

        var collected: [SearchSection] = []
        await withTaskGroup(of: SearchSection?.self) { group in
            for entry in catalogs {
                group.addTask { [client] in
                    let items = try? await client.fetchCatalog(
                        addon: entry.addon,
                        type: entry.catalog.apiType,
                        catalogId: entry.catalog.id,
                        extraArgs: [("search", term)]
                    )
                    guard let items, !items.isEmpty else { return nil }
                    return SearchSection(
                        addonName: entry.addon.displayName,
                        catalogName: entry.catalog.name,
                        items: items
                    )
                }
            }
            for await section in group {
                if let section { collected.append(section) }
            }
        }

        guard !Task.isCancelled else { return }
        results = collected.sorted { $0.items.count > $1.items.count }
    }
}

struct SearchView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    @State private var model = SearchViewModel()

    /// `discover_location == .searchTab` folds the Discover browser in below the search box,
    /// which is where it lives on Android when it has no sidebar entry of its own.
    private var showsDiscover: Bool {
        settings.layout.discoverLocation == .searchTab && settings.layout.searchDiscoverEnabled
    }

    var body: some View {
        @Bindable var model = model

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                header

                TextField("Search movies, series…", text: $model.query)
                    .textFieldStyle(.plain)
                    .nuvioText(NuvioTextStyles.body)
                    .padding(.horizontal, NuvioTheme.spacing.xl)
                    .padding(.vertical, NuvioTheme.spacing.md)
                    .background {
                        RoundedRectangle(cornerRadius: NuvioTheme.shapes.field, style: .continuous)
                            .fill(colors.field)
                    }
                    .frame(maxWidth: dp(560))
                    .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
                    .onChange(of: model.query) { _, _ in
                        model.scheduleSearch(addonStore: addons)
                    }

                content
            }
            .padding(.top, NuvioTheme.layout.tvSafeVertical)
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        .scrollClipDisabled()
        .background(colors.background)
    }

    private var header: some View {
        Text(L10n.text("navigation.search"))
            .nuvioText(NuvioTextStyles.display)
            .foregroundStyle(colors.textPrimary)
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
    }

    @ViewBuilder
    private var content: some View {
        if model.isSearching && model.results.isEmpty {
            PosterSkeletonRow()
        } else if model.hasSearched && model.results.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "No results",
                message: "No addon returned a match for “\(model.query)”."
            )
            .frame(height: dp(320))
        } else if !model.hasSearched {
            if showsDiscover {
                DiscoverBrowser()
            } else {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "Search your addons",
                    message: "Type at least two characters to query every catalog that supports search."
                )
                .frame(height: dp(320))
            }
        } else {
            LazyVStack(alignment: .leading, spacing: NuvioTheme.spacing.rail.rowGap) {
                ForEach(model.results) { section in
                    CatalogRowView(
                        title: section.catalogName,
                        subtitle: section.addonName,
                        items: section.items,
                        showsSeeAll: false,
                        onSelect: { router.openDetail($0) }
                    )
                }
            }
        }
    }
}
