import SwiftUI
import Observation

@Observable
@MainActor
final class SearchViewModel {
    var query: String = ""
    private(set) var results: [SearchSection] = []
    private(set) var recentSearches: [String] = SearchHistoryStore.load()
    private(set) var isSearching = false
    private(set) var hasSearched = false

    private let client: StremioClient
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    struct SearchSection: Identifiable {
        let addonName: String
        let catalogName: String
        let items: [MetaPreview]
        /// Identity has to come from the catalogue itself, not from what is printed above it.
        /// Addons routinely expose the same catalogue name for more than one type — Cinemeta's
        /// search is "Search" for both movies and series — so a name-based id put two different
        /// sections under one key. A `ForEach` with duplicate ids reuses the wrong rows as a
        /// lazy stack recycles them, which is why results appeared and vanished on scroll.
        let addonBaseUrl: String
        let catalogId: String
        let contentType: String
        var id: String { "\(addonBaseUrl)#\(contentType)#\(catalogId)" }

        /// Same reason the id carries the type: two rows headed "Search" from one addon tell
        /// the viewer nothing about which is which.
        var displayTitle: String {
            let type = ContentType.from(contentType)
            guard type != .unknown else { return catalogName }
            let kind = type.displayName
            return catalogName.localizedCaseInsensitiveContains(kind)
                ? catalogName
                : "\(catalogName) · \(kind)"
        }
    }

    init(client: StremioClient = .shared) {
        self.client = client
    }

    /// Debounced so each remote keystroke does not fan out to every addon.
    func scheduleSearch(addonStore: AddonStore) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
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
            await search(addonStore: addonStore, term: trimmed, generation: generation)
        }
    }

    func search(addonStore: AddonStore, term: String) async {
        searchTask?.cancel()
        searchGeneration += 1
        await search(addonStore: addonStore, term: term, generation: searchGeneration)
    }

    private func search(addonStore: AddonStore, term: String, generation: Int) async {
        let catalogs = addonStore.searchableCatalogs()
        guard !catalogs.isEmpty else {
            if generation == searchGeneration {
                results = []
                hasSearched = true
                isSearching = false
            }
            return
        }

        isSearching = true
        hasSearched = true
        results = []
        defer {
            if generation == searchGeneration { isSearching = false }
        }

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
                        items: items,
                        addonBaseUrl: entry.addon.baseUrl,
                        catalogId: entry.catalog.id,
                        contentType: entry.catalog.apiType
                    )
                }
            }
            for await section in group {
                guard !Task.isCancelled, generation == searchGeneration else {
                    group.cancelAll()
                    return
                }
                if let section {
                    collected.append(section)
                    // Results appear as addons answer rather than waiting for the slowest one.
                    results = collected.sorted { $0.items.count > $1.items.count }
                }
            }
        }

        guard !Task.isCancelled, generation == searchGeneration else { return }
        results = collected.sorted { $0.items.count > $1.items.count }
        if !results.isEmpty {
            recentSearches = SearchHistoryStore.record(term)
        }
    }

    var suggestions: [String] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return recentSearches }
        return recentSearches.filter { $0.localizedCaseInsensitiveContains(term) }
    }

    func useSuggestion(_ value: String, addonStore: AddonStore) {
        query = value
        scheduleSearch(addonStore: addonStore)
    }

    func clearHistory() {
        SearchHistoryStore.clear()
        recentSearches = []
    }
}

enum SearchHistoryStore {
    private static let key = "search_recent_queries_v1"
    static let maximumCount = 8

    static func load(defaults: UserDefaults = .standard) -> [String] {
        Array((defaults.stringArray(forKey: key) ?? []).prefix(maximumCount))
    }

    @discardableResult
    static func record(_ raw: String, defaults: UserDefaults = .standard) -> [String] {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return load(defaults: defaults) }
        var values = load(defaults: defaults)
        values.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        values.insert(value, at: 0)
        values = Array(values.prefix(maximumCount))
        defaults.set(values, forKey: key)
        return values
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
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

                TextField(L10n.text("search.placeholder", fallback: "Search movies, series…"), text: $model.query)
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

                if !model.suggestions.isEmpty {
                    suggestions
                }

                content
            }
            .padding(.top, NuvioTheme.layout.tvSafeVertical)
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        .scrollClipDisabled()
        .background(colors.background)
    }

    private var suggestions: some View {
        ChipRow(title: model.query.isEmpty ? L10n.text("search.recent", fallback: "Recent searches") : "Suggestions") {
            ForEach(model.suggestions, id: \.self) { suggestion in
                NuvioChip(
                    label: suggestion,
                    isSelected: false,
                    action: { model.useSuggestion(suggestion, addonStore: addons) }
                )
            }
            if model.query.isEmpty {
                Button("Clear", action: model.clearHistory)
                    .buttonStyle(NuvioPillButtonStyle(emphasis: .ghost))
            }
        }
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
                title: L10n.text("search.no_results", fallback: "No results"),
                message: "No addon returned a match for “\(model.query)”."
            )
            .frame(height: dp(320))
        } else if !model.hasSearched {
            if showsDiscover {
                DiscoverBrowser()
            } else {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: L10n.text("search.prompt_title", fallback: "Search your addons"),
                    message: L10n.text("search.prompt_body", fallback: "Type at least two characters to query every catalog that supports search.")
                )
                .frame(height: dp(320))
            }
        } else {
            LazyVStack(alignment: .leading, spacing: NuvioTheme.spacing.rail.rowGap) {
                ForEach(model.results) { section in
                    CatalogRowView(
                        title: section.displayTitle,
                        subtitle: section.addonName,
                        items: section.items,
                        showsSeeAll: true,
                        onSelect: { router.openDetail($0) },
                        onSeeAll: {
                            router.push(.catalogSeeAll(CatalogRequest(
                                addonBaseUrl: section.addonBaseUrl,
                                catalogId: section.catalogId,
                                type: section.contentType,
                                title: section.displayTitle,
                                search: model.query.trimmingCharacters(in: .whitespacesAndNewlines)
                            )))
                        }
                    )
                }
            }
        }
    }
}
