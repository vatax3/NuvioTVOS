import SwiftUI
import Observation

/// One rendered rail — an addon catalog plus its paging state.
/// Port of `CatalogRow` + the pipeline in `HomeViewModelCatalogPipeline`.
@Observable
final class CatalogRowState: Identifiable {
    let addon: Addon
    let descriptor: CatalogDescriptor
    /// Everything the addon returned. `items` is what survives the presentation filter, so
    /// toggling "hide unreleased" does not require refetching the catalog.
    var rawItems: [MetaPreview] = []
    var items: [MetaPreview] = []
    var isLoading = false
    var isLoadingMore = false
    var reachedEnd = false
    var error: String?

    /// Catalog naming preferences, so a renamed rail keeps its name across reloads.
    var presentation: CatalogPresentation = .default

    var id: String { "\(addon.baseUrl)#\(descriptor.descriptorKey)" }

    /// Catalog names already read like "Popular"; the addon name disambiguates duplicates.
    var title: String { presentation.title(addon: addon, descriptor: descriptor) }
    var subtitle: String? { presentation.subtitle(addon: addon) }

    init(addon: Addon, descriptor: CatalogDescriptor, presentation: CatalogPresentation = .default) {
        self.addon = addon
        self.descriptor = descriptor
        self.presentation = presentation
    }

    var request: CatalogRequest {
        CatalogRequest(
            addonBaseUrl: addon.baseUrl,
            catalogId: descriptor.id,
            type: descriptor.apiType,
            title: title
        )
    }

    /// Single place the filter is applied, so `rawItems` and `items` cannot drift apart.
    func setItems(_ newItems: [MetaPreview]) {
        rawItems = newItems
        items = presentation.filter(newItems)
    }

    func appendItems(_ additions: [MetaPreview]) {
        rawItems.append(contentsOf: additions)
        items = presentation.filter(rawItems)
    }
}

@Observable
@MainActor
final class HomeViewModel {
    private(set) var rows: [CatalogRowState] = []
    private(set) var isInitialLoading = true
    private(set) var loadError: String?
    /// Drives the hero: the last poster the user focused, falling back to the first row item.
    var focusedItem: MetaPreview?

    private let client: StremioClient
    private var loadedSignature: String?
    private var pageSize = 50
    private var presentation: CatalogPresentation = .default

    init(client: StremioClient = .shared) {
        self.client = client
    }

    /// Applied without refetching — renaming a rail or hiding unreleased titles is a display
    /// change, not a reload.
    func apply(presentation: CatalogPresentation) {
        guard presentation != self.presentation else { return }
        let hiddenChanged = presentation.hidesUnreleased != self.presentation.hidesUnreleased
        self.presentation = presentation
        for row in rows {
            row.presentation = presentation
            if hiddenChanged { row.setItems(row.rawItems) }
        }
    }

    /// `hero_catalog_keys`: when the viewer nominated specific catalogs, only those seed the
    /// hero. Empty means the first rail with content, which is the Android default.
    var heroCatalogKeys: Set<String> = []

    private var heroRows: [CatalogRowState] {
        guard !heroCatalogKeys.isEmpty else { return rows }
        let preferred = rows.filter { heroCatalogKeys.contains($0.id) }
        return preferred.isEmpty ? rows : preferred
    }

    var heroItem: MetaPreview? {
        focusedItem ?? heroRows.first(where: { !$0.items.isEmpty })?.items.first
    }

    /// Catalogs backing the Modern hero carousel when nothing is focused yet.
    var heroCandidates: [MetaPreview] {
        Array((heroRows.first(where: { !$0.items.isEmpty })?.items ?? []).prefix(10))
    }

    func load(
        addonStore: AddonStore,
        presentation: CatalogPresentation = .default,
        force: Bool = false
    ) async {
        self.presentation = presentation
        let catalogs = addonStore.orderedHomeCatalogs
        let signature = catalogs.map { "\($0.addon.baseUrl)#\($0.catalog.descriptorKey)" }.joined(separator: ",")

        if !force, signature == loadedSignature, !rows.isEmpty {
            return
        }
        loadedSignature = signature

        guard !catalogs.isEmpty else {
            rows = []
            isInitialLoading = false
            loadError = addonStore.enabledAddons.isEmpty
                ? "No addons installed yet."
                : "None of your addons expose a home catalog."
            return
        }

        loadError = nil
        rows = catalogs.map {
            CatalogRowState(addon: $0.addon, descriptor: $0.catalog, presentation: presentation)
        }
        isInitialLoading = true

        // Load the first screenful eagerly, then the rest — the top rails must appear fast.
        let visibleCount = min(4, rows.count)
        await withTaskGroup(of: Void.self) { group in
            for row in rows.prefix(visibleCount) {
                group.addTask { @MainActor in await self.loadFirstPage(row) }
            }
        }
        isInitialLoading = false

        await withTaskGroup(of: Void.self) { group in
            for row in rows.dropFirst(visibleCount) {
                group.addTask { @MainActor in await self.loadFirstPage(row) }
            }
        }
    }

    private func loadFirstPage(_ row: CatalogRowState) async {
        guard row.rawItems.isEmpty, !row.isLoading else { return }
        row.isLoading = true
        defer { row.isLoading = false }

        // Some catalogs refuse to answer without a genre; seed the first offered option.
        var extras: [(String, String)] = []
        if row.descriptor.requiresGenre, let genre = row.descriptor.genreOptions.first {
            extras.append(("genre", genre))
        }

        do {
            let items = try await client.fetchCatalog(
                addon: row.addon,
                type: row.descriptor.apiType,
                catalogId: row.descriptor.id,
                skip: 0,
                extraArgs: extras
            )
            row.setItems(dedupe(items))
            row.reachedEnd = items.count < (row.descriptor.pageSize ?? pageSize)
            row.error = nil
        } catch {
            row.error = error.localizedDescription
            row.reachedEnd = true
        }
    }

    func loadMore(_ row: CatalogRowState) async {
        guard row.descriptor.supportsSkip, !row.reachedEnd, !row.isLoadingMore, !row.isLoading else { return }
        row.isLoadingMore = true
        defer { row.isLoadingMore = false }

        do {
            let items = try await client.fetchCatalog(
                addon: row.addon,
                type: row.descriptor.apiType,
                catalogId: row.descriptor.id,
                // Paging is against what the addon returned, not what survived the filter.
                skip: row.rawItems.count
            )
            guard !items.isEmpty else {
                row.reachedEnd = true
                return
            }
            let existing = Set(row.rawItems.map(\.rowKey))
            let additions = items.filter { !existing.contains($0.rowKey) }
            row.appendItems(additions)
            row.reachedEnd = additions.isEmpty
        } catch {
            row.reachedEnd = true
        }
    }

    private func dedupe(_ items: [MetaPreview]) -> [MetaPreview] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.rowKey).inserted }
    }
}
