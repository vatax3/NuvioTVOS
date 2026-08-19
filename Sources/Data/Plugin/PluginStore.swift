import Foundation
import Observation
import os

// MARK: - Wire types
//
// Field names match `PluginManifest` / `ScraperManifestInfo` in the Android app, because these
// decode the same `manifest.json` files.

struct PluginManifest: Decodable, Sendable {
    var name: String
    var version: String?
    var description: String?
    var author: String?
    var scrapers: [ScraperManifestInfo]
}

struct ScraperManifestInfo: Decodable, Sendable {
    var id: String
    var name: String
    var description: String?
    var version: String?
    var filename: String
    var supportedTypes: [String]?
    var enabled: Bool?
    var logo: String?
    var contentLanguage: [String]?
    var supportedPlatforms: [String]?
    var disabledPlatforms: [String]?
    var formats: [String]?
    var supportsExternalPlayer: Bool?
    var limited: Bool?
}

// MARK: - Stored models

struct PluginRepository: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Canonical manifest URL, always ending in `/manifest.json`.
    var manifestUrl: String
    var description: String?
    var author: String?
    var version: String?
    var enabled: Bool = true
    var lastUpdated: Date?
    var scraperCount: Int = 0
}

struct InstalledScraper: Codable, Hashable, Identifiable {
    var id: String
    var repositoryId: String
    var name: String
    var description: String?
    var version: String?
    var logo: String?
    var supportedTypes: [String]
    var contentLanguage: [String]
    /// The viewer's switch. `manifestEnabled` is the repository author's default.
    var enabled: Bool
    var manifestEnabled: Bool
    /// The scraper source, cached so playback does not wait on a download.
    var code: String

    var isRunnable: Bool { enabled && manifestEnabled && !code.isEmpty }

    /// Mirrors `ScraperInfo.supportsType`: Stremio says `series`, manifests say `tv`.
    func supports(type: String) -> Bool {
        let targets: Set<String>
        switch type.lowercased() {
        case "series": targets = ["series", "tv", "anime"]
        case "other": targets = ["other", "tv"]
        default: targets = [type.lowercased()]
        }
        return supportedTypes.contains { targets.contains($0.lowercased()) }
    }
}

// MARK: - Store

@Observable
@MainActor
final class PluginStore {
    private(set) var repositories: [PluginRepository] = []
    private(set) var scrapers: [InstalledScraper] = []
    private(set) var isBusy = false
    private(set) var lastError: String?

    private let repositoryFile = JSONFileStore<[PluginRepository]>(
        filename: "plugin-repositories.json", scope: ProfileScope.pluginStorage
    )
    private let scraperFile = JSONFileStore<[InstalledScraper]>(
        filename: "plugin-scrapers.json", scope: ProfileScope.pluginStorage
    )
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "PluginStore")

    /// 2 MB — the Android manager applies the same ceiling per scraper file.
    private let maxScraperBytes = 2 * 1024 * 1024

    init() {
        repositories = repositoryFile.load() ?? []
        scrapers = scraperFile.load() ?? []
    }

    var enabledScrapers: [InstalledScraper] {
        let enabledRepositories = Set(repositories.filter(\.enabled).map(\.id))
        return scrapers.filter { $0.isRunnable && enabledRepositories.contains($0.repositoryId) }
    }

    func scrapers(inRepository repositoryId: String) -> [InstalledScraper] {
        scrapers.filter { $0.repositoryId == repositoryId }
    }

    // MARK: URL handling

    /// Port of `canonicalizeManifestUrl`: a bare repository URL gains `/manifest.json`, while a
    /// URL already naming a `.json` file is left alone.
    static func canonicalizeManifestUrl(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return "" }
        if !trimmed.lowercased().hasPrefix("http") {
            trimmed = "https://" + trimmed
        }
        let lastComponent = trimmed.split(separator: "/").last.map(String.init) ?? ""
        if lastComponent.lowercased().hasSuffix(".json") { return trimmed }
        return trimmed + "/manifest.json"
    }

    // MARK: Install & refresh

    @discardableResult
    func addRepository(url raw: String) async -> Bool {
        let manifestUrl = Self.canonicalizeManifestUrl(raw)
        guard !manifestUrl.isEmpty else {
            lastError = "That does not look like a URL."
            return false
        }
        if repositories.contains(where: { $0.manifestUrl.caseInsensitiveCompare(manifestUrl) == .orderedSame }) {
            lastError = "That repository is already installed."
            return false
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        guard let manifest = await fetchManifest(manifestUrl) else {
            lastError = "Could not read a plugin manifest at that URL."
            return false
        }

        let repository = PluginRepository(
            id: UUID().uuidString,
            name: manifest.name,
            manifestUrl: manifestUrl,
            description: manifest.description,
            author: manifest.author,
            version: manifest.version,
            enabled: true,
            lastUpdated: Date(),
            scraperCount: manifest.scrapers.count
        )
        repositories.append(repository)
        await downloadScrapers(manifest.scrapers, repository: repository, manifestUrl: manifestUrl)
        persist()
        return true
    }

    func refresh(_ repository: PluginRepository) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        guard let manifest = await fetchManifest(repository.manifestUrl) else {
            lastError = "Could not refresh \(repository.name)."
            return
        }
        if let index = repositories.firstIndex(where: { $0.id == repository.id }) {
            repositories[index].name = manifest.name
            repositories[index].version = manifest.version
            repositories[index].description = manifest.description
            repositories[index].author = manifest.author
            repositories[index].scraperCount = manifest.scrapers.count
            repositories[index].lastUpdated = Date()
        }
        // Drop scrapers the manifest no longer lists, then re-download the rest.
        let keep = Set(manifest.scrapers.map { "\(repository.id)|\($0.id)" })
        scrapers.removeAll { $0.repositoryId == repository.id && !keep.contains("\(repository.id)|\($0.id)") }
        await downloadScrapers(manifest.scrapers, repository: repository, manifestUrl: repository.manifestUrl)
        persist()
    }

    func remove(_ repository: PluginRepository) {
        repositories.removeAll { $0.id == repository.id }
        scrapers.removeAll { $0.repositoryId == repository.id }
        persist()
    }

    func setEnabled(_ enabled: Bool, repository: PluginRepository) {
        guard let index = repositories.firstIndex(where: { $0.id == repository.id }) else { return }
        repositories[index].enabled = enabled
        persist()
    }

    func setEnabled(_ enabled: Bool, scraper: InstalledScraper) {
        guard let index = scrapers.firstIndex(where: {
            $0.id == scraper.id && $0.repositoryId == scraper.repositoryId
        }) else { return }
        scrapers[index].enabled = enabled
        persist()
    }

    // MARK: Networking

    private func fetchManifest(_ url: String) async -> PluginManifest? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("NuvioTV/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            log.error("Manifest fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func downloadScrapers(
        _ infos: [ScraperManifestInfo],
        repository: PluginRepository,
        manifestUrl: String
    ) async {
        // Scraper files sit next to manifest.json unless the entry gives an absolute URL.
        let base = manifestUrl.split(separator: "/").dropLast().joined(separator: "/")

        for info in infos {
            // A manifest can exclude a platform outright; respect that rather than shipping a
            // scraper that cannot work here.
            if let disabled = info.disabledPlatforms,
               disabled.contains(where: { ["ios", "tvos", "apple"].contains($0.lowercased()) }) {
                continue
            }
            if let supported = info.supportedPlatforms, !supported.isEmpty,
               !supported.contains(where: { ["ios", "tvos", "apple", "all"].contains($0.lowercased()) }) {
                continue
            }

            let codeUrl = info.filename.lowercased().hasPrefix("http")
                ? info.filename
                : "\(base)/\(info.filename)"
            guard let code = await fetchCode(codeUrl) else { continue }

            let existing = scrapers.first { $0.id == info.id && $0.repositoryId == repository.id }
            let scraper = InstalledScraper(
                id: info.id,
                repositoryId: repository.id,
                name: info.name,
                description: info.description,
                version: info.version,
                logo: info.logo,
                supportedTypes: info.supportedTypes ?? ["movie", "tv"],
                contentLanguage: info.contentLanguage ?? [],
                // A refresh must not silently re-enable something the viewer switched off.
                enabled: existing?.enabled ?? (info.enabled ?? true),
                manifestEnabled: info.enabled ?? true,
                code: code
            )
            if let index = scrapers.firstIndex(where: {
                $0.id == info.id && $0.repositoryId == repository.id
            }) {
                scrapers[index] = scraper
            } else {
                scrapers.append(scraper)
            }
        }
    }

    private func fetchCode(_ url: String) async -> String? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("NuvioTV/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard data.count <= maxScraperBytes else {
                log.error("Scraper at \(url.absoluteString, privacy: .public) exceeds the size cap")
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            log.error("Scraper fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func persist() {
        repositoryFile.save(repositories)
        scraperFile.save(scrapers)
    }
}

// MARK: - Mapping to streams

extension LocalScraperResult {
    /// Presents a scraper result as a `Stream`, so plugin sources go through exactly the same
    /// filtering, badge parsing, debrid resolution and playback path as addon streams.
    func asStream(sourceName: String, occurrence: Int) -> Stream {
        // A direct URL or a magnet: `Stream.streamURL()` / `torrentMagnetURI()` already sort
        // that out, and `effectiveInfoHash` picks the hash up from the magnet when absent here.
        var detailParts: [String] = []
        if let quality = quality?.nilIfBlank { detailParts.append(quality) }
        if let size = size?.nilIfBlank { detailParts.append(size) }
        if let language = language?.nilIfBlank { detailParts.append(language) }
        if let seeders, seeders > 0 { detailParts.append("\(seeders) seeders") }

        return Stream(
            name: provider?.nilIfBlank ?? sourceName,
            title: displayTitle,
            description: detailParts.isEmpty ? nil : detailParts.joined(separator: " • "),
            url: url,
            infoHash: infoHash?.nilIfBlank,
            behaviorHints: headers.map {
                StreamBehaviorHints(proxyHeaders: ProxyHeaders(request: $0))
            },
            addonName: sourceName,
            addonLogo: nil,
            quality: quality?.nilIfBlank,
            occurrence: occurrence
        )
    }
}
