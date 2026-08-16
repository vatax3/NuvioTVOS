import SwiftUI
import Observation

/// One rendered rail — an addon catalog plus its paging state.
/// Port of `CatalogRow` + the pipeline in `HomeViewModelCatalogPipeline`.
@Observable
final class CatalogRowState: Identifiable {
    let addon: Addon
    let descriptor: CatalogDescriptor
    var items: [MetaPreview] = []
    var isLoading = false
    var isLoadingMore = false
    var reachedEnd = false
    var error: String?

    var id: String { "\(addon.baseUrl)#\(descriptor.descriptorKey)" }

    /// Catalog names already read like "Popular"; the addon name disambiguates duplicates.
    var title: String { descriptor.name }
    var subtitle: String? { addon.displayName }

    init(addon: Addon, descriptor: CatalogDescriptor) {
        self.addon = addon
        self.descriptor = descriptor
    }

    var request: CatalogRequest {
        CatalogRequest(
            addonBaseUrl: addon.baseUrl,
            catalogId: descriptor.id,
            type: descriptor.apiType,
            title: descriptor.name
        )
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

    init(client: StremioClient = .shared) {
        self.client = client
    }

    var heroItem: MetaPreview? {
        focusedItem ?? rows.first(where: { !$0.items.isEmpty })?.items.first
    }

    /// Catalogs backing the Modern hero carousel when nothing is focused yet.
    var heroCandidates: [MetaPreview] {
        Array((rows.first(where: { !$0.items.isEmpty })?.items ?? []).prefix(10))
    }

    func load(addonStore: AddonStore, force: Bool = false) async {
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
        rows = catalogs.map { CatalogRowState(addon: $0.addon, descriptor: $0.catalog) }
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
        guard row.items.isEmpty, !row.isLoading else { return }
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
            row.items = dedupe(items)
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
                skip: row.items.count
            )
            guard !items.isEmpty else {
                row.reachedEnd = true
                return
            }
            let existing = Set(row.items.map(\.rowKey))
            let additions = items.filter { !existing.contains($0.rowKey) }
            row.items.append(contentsOf: additions)
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
