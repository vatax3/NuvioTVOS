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
    private(set) var ratings: MDBListRatings?
    private(set) var enrichment: TMDBClient.Enrichment?

    var selectedSeason: Int = 1

    private let client: StremioClient

    init(client: StremioClient = .shared) {
        self.client = client
    }

    var seasons: [Int] { meta?.seasons ?? [] }

    var episodes: [Video] {
        meta?.episodes(inSeason: selectedSeason) ?? []
    }

    /// The episode that follows `video` in release order, across season boundaries.
    func episodeAfter(_ video: Video) -> Video? {
        guard let meta else { return nil }
        let ordered = meta.watchableEpisodes().sorted {
            ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
        }
        guard let index = ordered.firstIndex(where: { $0.id == video.id }),
              ordered.indices.contains(index + 1) else { return nil }
        return ordered[index + 1]
    }

    /// The episode a Play button should resume, mirroring `nextUp` on Android: first
    /// unwatched aired episode, else the first episode.
    func nextUpEpisode(library: LibraryStore, threshold: Double) -> Video? {
        guard let meta, meta.type == .series else { return nil }
        let watchable = meta.watchableEpisodes()
        let firstUnwatched = watchable.first { !library.isWatched(videoId: $0.id, threshold: threshold) }
        return firstUnwatched ?? watchable.first
    }

    func load(request: DetailRequest, addonStore: AddonStore, settings: AppSettings) async {
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
                // Enrichment runs after the meta is on screen so the hero never waits on it.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in
                        await self.loadMoreLikeThis(addonStore: addonStore, meta: resolved)
                    }
                    group.addTask { @MainActor in await self.enrich(meta: resolved, settings: settings) }
                    group.addTask { @MainActor in await self.loadRatings(meta: resolved, settings: settings) }
                }
                return
            }
        }
        error = "Could not load details for this title."
    }

    /// Fills gaps in the addon's metadata from TMDB, per the Metadata settings.
    private func enrich(meta: Meta, settings: AppSettings) async {
        guard settings.tmdb.isUsable, let imdbId = meta.imdbId ?? idIfImdb(meta.id) else { return }
        let result = await TMDBClient.shared.enrich(
            imdbId: imdbId,
            type: meta.type,
            apiKey: settings.tmdb.apiKey,
            language: settings.tmdb.language,
            options: settings.tmdbOptions
        )
        guard let result else { return }
        enrichment = result

        // Only fill in what the addon left blank — the addon stays the source of truth.
        var merged = meta
        if settings.tmdb.useArtwork {
            merged.background = result.backdrop ?? merged.background
            merged.logo = result.logo ?? merged.logo
            merged.poster = merged.poster ?? result.poster
        }
        if settings.tmdb.useBasicInfo {
            merged.description = merged.description ?? result.overview
            merged.imdbRating = merged.imdbRating ?? result.rating
            if merged.genres.isEmpty { merged.genres = result.genres }
        }
        if settings.tmdb.useDetails, merged.runtime == nil, let minutes = result.runtimeMinutes {
            merged.runtime = "\(minutes) min"
        }
        if settings.tmdb.useCredits, !result.cast.isEmpty {
            // TMDB cast carries photos, which addon cast lists almost never do.
            merged.castMembers = result.cast
        }
        if settings.tmdb.useNetworks { merged.networks = result.networks }
        if settings.tmdb.useProductions { merged.productionCompanies = result.productionCompanies }
        if settings.tmdb.useReleaseDates { merged.ageRating = merged.ageRating ?? result.certification }
        if settings.tmdb.useTrailers, merged.trailerYtIds.isEmpty {
            merged.trailerYtIds = result.trailerYouTubeIds
        }
        self.meta = merged

        if settings.tmdb.useMoreLikeThis, moreLikeThis.isEmpty {
            moreLikeThis = result.recommendations
        }
    }

    private func loadRatings(meta: Meta, settings: AppSettings) async {
        guard settings.mdblist.isUsable, let imdbId = meta.imdbId ?? idIfImdb(meta.id) else { return }
        ratings = await MDBListClient.shared.ratings(imdbId: imdbId, apiKey: settings.mdblist.apiKey)
    }

    /// Cinemeta ids are IMDb ids; other addons prefix their own namespace.
    private func idIfImdb(_ id: String) -> String? {
        id.hasPrefix("tt") ? id.split(separator: ":").first.map(String.init) : nil
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
