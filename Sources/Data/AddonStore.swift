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
}

/// Ordering entry for the "Catalog Order" screen — mirrors `CatalogOrderViewModel`.
struct CatalogOrderEntry: Codable, Hashable, Identifiable {
    var addonBaseUrl: String
    var catalogKey: String
    var enabled: Bool = true
    var id: String { "\(addonBaseUrl)#\(catalogKey)" }
}

@Observable
@MainActor
final class AddonStore {
    private(set) var installed: [InstalledAddon] = []
    private(set) var catalogOrder: [CatalogOrderEntry] = []
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    private let addonsFile = JSONFileStore<[InstalledAddon]>(filename: "addons.json")
    private let orderFile = JSONFileStore<[CatalogOrderEntry]>(filename: "catalog-order.json")
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

    /// All home-eligible catalogs across enabled addons, honouring the saved ordering.
    var orderedHomeCatalogs: [(addon: Addon, catalog: CatalogDescriptor)] {
        let available = enabledAddons.flatMap { addon in
            addon.catalogs.map { (addon: addon, catalog: $0) }
        }
        guard !catalogOrder.isEmpty else {
            return available.filter { $0.catalog.showInHome }
        }

        var byKey: [String: (addon: Addon, catalog: CatalogDescriptor)] = [:]
        for entry in available {
            byKey["\(entry.addon.baseUrl)#\(entry.catalog.descriptorKey)"] = entry
        }

        var ordered: [(addon: Addon, catalog: CatalogDescriptor)] = []
        var consumed = Set<String>()
        for entry in catalogOrder where entry.enabled {
            let key = "\(StremioURL.canonicalize(entry.addonBaseUrl))#\(entry.catalogKey)"
            if let match = byKey[key] {
                ordered.append(match)
                consumed.insert(key)
            }
        }
        // Newly discovered catalogs land at the end rather than disappearing.
        let disabled = Set(catalogOrder.filter { !$0.enabled }.map {
            "\(StremioURL.canonicalize($0.addonBaseUrl))#\($0.catalogKey)"
        })
        for entry in available {
            let key = "\(entry.addon.baseUrl)#\(entry.catalog.descriptorKey)"
            guard !consumed.contains(key), !disabled.contains(key), entry.catalog.showInHome else { continue }
            ordered.append(entry)
        }
        return ordered
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

    func setCatalogEnabled(_ enabled: Bool, addonBaseUrl: String, catalogKey: String) {
        if let index = catalogOrder.firstIndex(where: {
            $0.addonBaseUrl == addonBaseUrl && $0.catalogKey == catalogKey
        }) {
            catalogOrder[index].enabled = enabled
        } else {
            catalogOrder.append(CatalogOrderEntry(
                addonBaseUrl: addonBaseUrl, catalogKey: catalogKey, enabled: enabled
            ))
        }
        persistOrder()
    }

    func moveCatalog(addonBaseUrl: String, catalogKey: String, by offset: Int) {
        syncCatalogOrder()
        guard let index = catalogOrder.firstIndex(where: {
            $0.addonBaseUrl == addonBaseUrl && $0.catalogKey == catalogKey
        }) else { return }
        let target = index + offset
        guard catalogOrder.indices.contains(target) else { return }
        catalogOrder.swapAt(index, target)
        persistOrder()
    }

    func isCatalogEnabled(addonBaseUrl: String, catalogKey: String) -> Bool {
        catalogOrder.first {
            $0.addonBaseUrl == addonBaseUrl && $0.catalogKey == catalogKey
        }?.enabled ?? true
    }

    /// Keeps the persisted ordering in step with whatever the manifests currently expose.
    private func syncCatalogOrder() {
        let available = allCatalogs.map {
            CatalogOrderEntry(
                addonBaseUrl: $0.addon.baseUrl,
                catalogKey: $0.catalog.descriptorKey,
                enabled: $0.catalog.showInHome
            )
        }
        let existingKeys = Set(catalogOrder.map(\.id))
        let additions = available.filter { !existingKeys.contains($0.id) }
        let availableKeys = Set(available.map(\.id))
        catalogOrder = catalogOrder.filter { availableKeys.contains($0.id) } + additions
        persistOrder()
    }

    private func persistAddons() { addonsFile.save(installed) }
    private func persistOrder() { orderFile.save(catalogOrder) }
}
