import Foundation
import Observation
import os

/// Persisted addon record — the manifest is cached so the home screen can render
/// catalogs on the very first frame instead of waiting on the network.
struct InstalledAddon: Codable, Hashable, Identifiable {
    var baseUrl: String
    var enabled: Bool = true
    var manifest: Addon?
    var fetchedAt: Date?
    var id: String { baseUrl }

    init(baseUrl: String, enabled: Bool = true, manifest: Addon? = nil, fetchedAt: Date? = nil) {
        self.baseUrl = baseUrl
        self.enabled = enabled
        self.manifest = manifest
        self.fetchedAt = fetchedAt
    }

    /// Tolerant of documents written before a field existed — see `NuvioServerConfiguration`.
    /// A stale cached manifest is dropped rather than taking the addon with it; the next refresh
    /// re-fetches it anyway.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseUrl = try container.decode(String.self, forKey: .baseUrl)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        manifest = try? container.decodeIfPresent(Addon.self, forKey: .manifest)
        fetchedAt = try? container.decodeIfPresent(Date.self, forKey: .fetchedAt)
    }
}

/// Ordering entry for the "Catalog Order" screen — mirrors `CatalogOrderViewModel`.
/// One row of the home order, which is a catalogue *or* a collection.
///
/// Upstream keeps a single list of keys where the two kinds are equals, so a collection can sit
/// between two catalogues rather than only at one end. `collectionId` is what makes this entry
/// the second kind; an older `catalog-order.json` decodes with it absent, which is correct.
struct CatalogOrderEntry: Codable, Hashable, Identifiable {
    var addonBaseUrl: String
    var catalogKey: String
    var enabled: Bool = true
    var collectionId: String?

    var id: String {
        collectionId.map { "collection_\($0)" } ?? "\(addonBaseUrl)#\(catalogKey)"
    }

    var rowKey: HomeRowKey {
        collectionId.map(HomeRowKey.collection) ?? .catalog("\(addonBaseUrl)#\(catalogKey)")
    }

    init(addonBaseUrl: String, catalogKey: String, enabled: Bool = true, collectionId: String? = nil) {
        self.addonBaseUrl = addonBaseUrl
        self.catalogKey = catalogKey
        self.enabled = enabled
        self.collectionId = collectionId
    }

    init(collectionId: String, enabled: Bool = true) {
        self.init(addonBaseUrl: "", catalogKey: "", enabled: enabled, collectionId: collectionId)
    }
}

@Observable
@MainActor
final class AddonStore {
    private(set) var installed: [InstalledAddon] = []
    private(set) var catalogOrder: [CatalogOrderEntry] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    // A profile set to "use the primary's addons" reads and writes the primary's list rather
    // than one of its own — the flag was stored and synced but acted on nowhere, so such a
    // profile silently started from the default two addons and never saw the account's.
    private let addonsFile = JSONFileStore<[InstalledAddon]>(
        filename: "addons.json", scope: ProfileScope.addonStorage
    )
    private let orderFile = JSONFileStore<[CatalogOrderEntry]>(
        filename: "catalog-order.json", scope: ProfileScope.addonStorage
    )
    private let client: StremioClient
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "AddonStore")

    /// Port of `AddonPreferences.getDefaultAddons()`.
    static let defaultAddonURLs = [
        "https://v3-cinemeta.strem.io",
        "https://opensubtitles-v3.strem.io"
    ]

    init(client: StremioClient = .shared) {
        self.client = client
        let stored = addonsFile.load()
        installed = stored ?? Self.defaultAddonURLs.map { InstalledAddon(baseUrl: StremioURL.canonicalize($0)) }
        catalogOrder = orderFile.load() ?? []
        if stored == nil { persistAddons() }
    }

    // MARK: - Derived state

    var addons: [Addon] {
        installed.compactMap { record in
            guard var manifest = record.manifest else { return nil }
            manifest.enabled = record.enabled
            return manifest
        }
    }

    var enabledAddons: [Addon] { addons.filter(\.enabled) }

    /// Addons that can answer a `catalog` request, in user-defined order.
    var catalogAddons: [Addon] {
        enabledAddons.filter { !$0.catalogs.isEmpty }
    }

    func addon(withBaseUrl baseUrl: String) -> Addon? {
        let canonical = StremioURL.canonicalize(baseUrl)
        return addons.first { $0.baseUrl.caseInsensitiveCompare(canonical) == .orderedSame }
    }

    /// `follow_addons_order`: when on, rails simply follow the addon list and the manual
    /// catalog ordering is ignored (disabled catalogs are still honoured). Set by `AppSettings`
    /// so the store does not have to reach into the settings graph.
    var followsAddonOrder = false

    /// All home-eligible catalogs across enabled addons, honouring the saved ordering.
    ///
    /// Derived from `orderedHomeRows` rather than ordering separately: two implementations of the
    /// same rule drift, and the one thing that must not drift is which rail comes first.
    var orderedHomeCatalogs: [(addon: Addon, catalog: CatalogDescriptor)] {
        var byKey: [String: (addon: Addon, catalog: CatalogDescriptor)] = [:]
        for addon in enabledAddons {
            for catalog in addon.catalogs where catalog.showInHome {
                byKey["\(addon.baseUrl)#\(catalog.descriptorKey)"] = (addon: addon, catalog: catalog)
            }
        }
        return orderedHomeRows(collectionIds: []).compactMap { $0.catalogKey.flatMap { byKey[$0] } }
    }

    /// Changes whenever the set of home catalogs changes — including when a manifest finishes
    /// loading and turns an installed-but-unresolved addon into real catalogs. Views key their
    /// `.task(id:)` on this so they reload once the network catches up.
    var catalogSignature: String {
        orderedHomeCatalogs
            .map { "\($0.addon.baseUrl)#\($0.catalog.descriptorKey)" }
            .joined(separator: ",")
    }

    /// Catalogs eligible for the Discover screen — every catalog, home-flagged or not.
    var allCatalogs: [(addon: Addon, catalog: CatalogDescriptor)] {
        enabledAddons.flatMap { addon in addon.catalogs.map { (addon: addon, catalog: $0) } }
    }

    func searchableCatalogs() -> [(addon: Addon, catalog: CatalogDescriptor)] {
        allCatalogs.filter { $0.catalog.supportsSearch }
    }

    func addonsProviding(resource: String, type: String, id: String) -> [Addon] {
        enabledAddons.filter { $0.handles(id: id, resource: resource, type: type) }
    }

    // MARK: - Mutations

    func refreshAll(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let ttl: TimeInterval = 6 * 60 * 60 // matches MANIFEST_CACHE_TTL_MS
        let targets = installed.filter { record in
            guard !force else { return true }
            guard let fetchedAt = record.fetchedAt, record.manifest != nil else { return true }
            return Date().timeIntervalSince(fetchedAt) > ttl
        }
        guard !targets.isEmpty else { return }

        await withTaskGroup(of: (String, Addon?).self) { group in
            for record in targets {
                group.addTask { [client] in
                    let manifest = try? await client.fetchManifest(rawUrl: record.baseUrl)
                    return (record.baseUrl, manifest)
                }
            }
            for await (baseUrl, manifest) in group {
                guard let manifest, let index = installed.firstIndex(where: { $0.baseUrl == baseUrl })
                else { continue }
                installed[index].manifest = manifest
                installed[index].fetchedAt = Date()
            }
        }
        persistAddons()
        syncCatalogOrder()
    }

    @discardableResult
    func install(url rawUrl: String) async -> Result<Addon, Error> {
        let canonical = StremioURL.canonicalize(rawUrl)
        guard !canonical.isEmpty else {
            return .failure(StremioError.invalidURL(rawUrl))
        }
        do {
            let manifest = try await client.fetchManifest(rawUrl: canonical)
            if let index = installed.firstIndex(where: {
                $0.baseUrl.caseInsensitiveCompare(canonical) == .orderedSame
            }) {
                installed[index].manifest = manifest
                installed[index].fetchedAt = Date()
                installed[index].enabled = true
            } else {
                installed.append(InstalledAddon(
                    baseUrl: canonical, enabled: true, manifest: manifest, fetchedAt: Date()
                ))
            }
            lastError = nil
            persistAddons()
            syncCatalogOrder()
            return .success(manifest)
        } catch {
            lastError = error.localizedDescription
            log.error("Install failed for \(canonical, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    func uninstall(baseUrl: String) {
        let canonical = StremioURL.canonicalize(baseUrl)
        installed.removeAll { $0.baseUrl.caseInsensitiveCompare(canonical) == .orderedSame }
        catalogOrder.removeAll { StremioURL.canonicalize($0.addonBaseUrl).caseInsensitiveCompare(canonical) == .orderedSame }
        persistAddons()
        persistOrder()
    }

    func setEnabled(_ enabled: Bool, baseUrl: String) {
        let canonical = StremioURL.canonicalize(baseUrl)
        guard let index = installed.firstIndex(where: {
            $0.baseUrl.caseInsensitiveCompare(canonical) == .orderedSame
        }) else { return }
        installed[index].enabled = enabled
        persistAddons()
    }

    func move(from source: IndexSet, to destination: Int) {
        installed.move(fromOffsets: source, toOffset: destination)
        persistAddons()
    }

    func moveAddon(baseUrl: String, by offset: Int) {
        guard let index = installed.firstIndex(where: { $0.baseUrl == baseUrl }) else { return }
        let target = index + offset
        guard installed.indices.contains(target) else { return }
        installed.swapAt(index, target)
        persistAddons()
    }

    // MARK: - Catalog ordering

    func setRowEnabled(_ enabled: Bool, key: HomeRowKey) {
        if let index = catalogOrder.firstIndex(where: { $0.rowKey == key }) {
            catalogOrder[index].enabled = enabled
        } else {
            catalogOrder.append(entry(for: key, enabled: enabled))
        }
        persistOrder()
    }

    /// Moves one home row past its neighbour, catalogue or collection alike.
    ///
    /// `collectionIds` has to be handed in because the order is a single list and this store does
    /// not own collections — without it the sync below would prune every collection row as
    /// unknown the first time a catalogue moved.
    func moveRow(_ key: HomeRowKey, by offset: Int, collectionIds: [String]) {
        syncCatalogOrder(collectionIds: collectionIds)
        guard let index = catalogOrder.firstIndex(where: { $0.rowKey == key }) else { return }
        let target = index + offset
        guard catalogOrder.indices.contains(target) else { return }
        catalogOrder.swapAt(index, target)
        persistOrder()
    }

    func isRowEnabled(_ key: HomeRowKey) -> Bool {
        catalogOrder.first { $0.rowKey == key }?.enabled ?? true
    }

    /// Brings the persisted order in step with the catalogues and collections that exist now.
    ///
    /// Called when the ordering screen appears, never from a view body: it writes to the store
    /// and to disk, and doing that while SwiftUI is evaluating a body invalidates the view that
    /// asked, which invalidates it again.
    func syncHomeOrder(collectionIds: [String]) {
        syncCatalogOrder(collectionIds: collectionIds)
    }

    /// Home's actual row order: catalogues and unpinned collections merged, honouring what the
    /// viewer arranged and the `follow_addons_order` preference.
    ///
    /// Pinned collections are excluded — they are rendered ahead of this list and would otherwise
    /// appear twice, which is how upstream does it too.
    func orderedHomeRows(collectionIds: [String]) -> [HomeRowKey] {
        let disabled = Set(catalogOrder.filter { !$0.enabled }.map(\.rowKey))
        let catalogs = enabledAddons.flatMap { addon in
            addon.catalogs
                .filter(\.showInHome)
                .map { HomeRowOrder.Catalog(key: "\(addon.baseUrl)#\($0.descriptorKey)", owner: addon.baseUrl) }
        }
        return HomeRowOrder.merge(
            saved: catalogOrder.map(\.rowKey),
            catalogs: catalogs.filter { !disabled.contains(.catalog($0.key)) },
            collections: collectionIds.filter { !disabled.contains(.collection($0)) },
            followsAddonOrder: followsAddonOrder
        )
    }

    private func entry(for key: HomeRowKey, enabled: Bool) -> CatalogOrderEntry {
        switch key {
        case .collection(let id):
            return CatalogOrderEntry(collectionId: id, enabled: enabled)
        case .catalog(let composite):
            // `#` cannot appear in a descriptor key, so the last one splits base URL from key.
            guard let separator = composite.lastIndex(of: "#") else {
                return CatalogOrderEntry(addonBaseUrl: composite, catalogKey: "", enabled: enabled)
            }
            return CatalogOrderEntry(
                addonBaseUrl: String(composite[composite.startIndex..<separator]),
                catalogKey: String(composite[composite.index(after: separator)...]),
                enabled: enabled
            )
        }
    }

    /// Keeps the persisted ordering in step with whatever the manifests and collections expose.
    ///
    /// `collectionIds` is optional and `nil` means "this caller does not know about collections":
    /// an addon refresh must not prune the collection rows out of the order simply because it has
    /// no list of them to check against. Only a caller holding the real list may drop them.
    private func syncCatalogOrder(collectionIds: [String]? = nil) {
        let availableCatalogs = allCatalogs.map {
            CatalogOrderEntry(
                addonBaseUrl: $0.addon.baseUrl,
                catalogKey: $0.catalog.descriptorKey,
                enabled: $0.catalog.showInHome
            )
        }
        let availableCollections = (collectionIds ?? []).map { CatalogOrderEntry(collectionId: $0) }
        let available = availableCatalogs + availableCollections

        let existingKeys = Set(catalogOrder.map(\.id))
        let additions = available.filter { !existingKeys.contains($0.id) }
        let availableKeys = Set(available.map(\.id))
        catalogOrder = catalogOrder.filter { entry in
            if entry.collectionId != nil, collectionIds == nil { return true }
            return availableKeys.contains(entry.id)
        } + additions
        persistOrder()
    }

    private func persistAddons() { addonsFile.save(installed) }
    private func persistOrder() { orderFile.save(catalogOrder) }
}
