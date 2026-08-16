import SwiftUI
import Observation

/// Port of `MetaDetailsViewModel` — resolves the meta across every addon that claims the id,
/// then keeps season/episode selection for the episodes section.
@Observable
@MainActor
final class MetaDetailsViewModel {
    private(set) var meta: Meta?
    private(set) var isLoading = true
    private(set) var error: String?
    private(set) var moreLikeThis: [MetaPreview] = []

    var selectedSeason: Int = 1

    private let client: StremioClient

    init(client: StremioClient = .shared) {
        self.client = client
    }

    var seasons: [Int] { meta?.seasons ?? [] }

    var episodes: [Video] {
        meta?.episodes(inSeason: selectedSeason) ?? []
    }

    /// The episode a Play button should resume, mirroring `nextUp` on Android: first
    /// unwatched aired episode, else the first episode.
    func nextUpEpisode(library: LibraryStore, threshold: Double) -> Video? {
        guard let meta, meta.type == .series else { return nil }
        let watchable = meta.watchableEpisodes()
        let firstUnwatched = watchable.first { !library.isWatched(videoId: $0.id, threshold: threshold) }
        return firstUnwatched ?? watchable.first
    }

    func load(request: DetailRequest, addonStore: AddonStore) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        // Prefer the addon the item came from, then any other addon advertising `meta`
        // for this id — this is what makes third-party catalogs resolve through Cinemeta.
        var candidates: [Addon] = []
        if let source = request.addonBaseUrl, let addon = addonStore.addon(withBaseUrl: source) {
            candidates.append(addon)
        }
        candidates.append(contentsOf: addonStore.addonsProviding(
            resource: "meta", type: request.itemType, id: request.itemId
        ).filter { candidate in !candidates.contains { $0.baseUrl == candidate.baseUrl } })

        guard !candidates.isEmpty else {
            error = "No installed addon can describe this title."
            return
        }

        for addon in candidates {
            if let resolved = try? await client.fetchMeta(
                addon: addon, type: request.itemType, id: request.itemId
            ) {
                meta = resolved
                selectedSeason = resolved.seasons.first ?? 1
                await loadMoreLikeThis(addonStore: addonStore, meta: resolved)
                return
            }
        }
        error = "Could not load details for this title."
    }

    /// Port of `MoreLikeThisSection`: genre-matched items from the first catalog that
    /// supports a genre filter for this content type.
    private func loadMoreLikeThis(addonStore: AddonStore, meta: Meta) async {
        guard let genre = meta.genres.first else { return }
        let candidates = addonStore.allCatalogs.filter {
            $0.catalog.apiType == meta.apiType && !$0.catalog.genreOptions.isEmpty
        }
        guard let entry = candidates.first(where: { $0.catalog.genreOptions.contains(genre) })
            ?? candidates.first else { return }

        let items = try? await client.fetchCatalog(
            addon: entry.addon,
            type: entry.catalog.apiType,
            catalogId: entry.catalog.id,
            extraArgs: [("genre", genre)]
        )
        moreLikeThis = (items ?? []).filter { $0.id != meta.id }
    }
}
