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
    /// The other films in this one's franchise, when TMDB places it in one.
    private(set) var collection: (name: String, items: [MetaPreview])?
    private(set) var ratings: MDBListRatings?
    private(set) var enrichment: TMDBClient.Enrichment?

    var selectedSeason: Int = 1

    /// Seasons already filled in from TMDB, so switching back and forth does not refetch.
    private var episodeEnrichedSeasons: Set<Int> = []

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
    /// Which episode the Play button resumes on.
    ///
    /// `fromFurthest` is the `next_up_from_furthest_episode` preference: on, Next Up follows
    /// the deepest episode the viewer has touched (so a rewatch of an early episode does not
    /// drag the series backwards); off, it is simply the first unwatched one in order.
    func nextUpEpisode(
        library: LibraryStore,
        threshold: Double,
        fromFurthest: Bool = true,
        includeUnaired: Bool = false
    ) -> Video? {
        guard let meta, meta.type == .series else { return nil }
        let watchable = meta.watchableEpisodes(includeUnaired: includeUnaired)
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        guard !watchable.isEmpty else { return nil }

        func isWatched(_ video: Video) -> Bool {
            library.isWatched(videoId: video.id, threshold: threshold)
        }

        if fromFurthest {
            // Anchor on the last episode with any recorded progress, then take what follows.
            let touched = watchable.lastIndex { library.progress(forVideoId: $0.id) != nil }
            if let touched {
                if !isWatched(watchable[touched]) { return watchable[touched] }
                let next = watchable.index(after: touched)
                return next < watchable.count ? watchable[next] : watchable[touched]
            }
        }
        return watchable.first { !isWatched($0) } ?? watchable.first
    }

    func load(request: DetailRequest, addonStore: AddonStore, settings: AppSettings) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        // Rows sourced from TMDB (recommendations, cast credits, network browse) carry a
        // `tmdb:<id>` id, which no Stremio addon can answer. Trade it for the IMDb id first.
        var request = request
        if let tmdbId = request.tmdbId {
            guard let imdbId = await TMDBClient.shared.imdbId(
                tmdbId: tmdbId,
                type: ContentType.from(request.itemType),
                apiKey: settings.tmdb.apiKey
            ) else {
                error = settings.tmdb.apiKey.isEmpty
                    ? L10n.text("detail.needs_tmdb", fallback: "This title came from TMDB — add a TMDB API key in Metadata settings to open it.")
                    : "TMDB has no IMDb id for this title, so no addon can describe it."
                return
            }
            request.itemId = imdbId
            request.addonBaseUrl = nil
        }

        // Prefer the addon the item came from, then any other addon advertising `meta`
        // for this id — this is what makes third-party catalogs resolve through Cinemeta.
        //
        // `prefer_external_meta_addon_detail` inverts that: a dedicated metadata addon is
        // asked first, and the catalog's own addon becomes the fallback. Viewers use this when
        // their catalog addon returns thinner metadata than Cinemeta does.
        let sourceAddon = request.addonBaseUrl.flatMap { addonStore.addon(withBaseUrl: $0) }
        let others = addonStore.addonsProviding(
            resource: "meta", type: request.itemType, id: request.itemId
        ).filter { $0.baseUrl != sourceAddon?.baseUrl }

        var candidates: [Addon] = []
        if settings.layout.preferExternalMetaAddonDetail {
            candidates = others
            if let sourceAddon { candidates.append(sourceAddon) }
        } else {
            if let sourceAddon { candidates.append(sourceAddon) }
            candidates.append(contentsOf: others)
        }

        guard !candidates.isEmpty else {
            error = L10n.text("detail.no_addon", fallback: "No installed addon can describe this title.")
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
                        await self.loadMoreLikeThis(
                            addonStore: addonStore, meta: resolved, settings: settings
                        )
                    }
                    group.addTask { @MainActor in await self.enrich(meta: resolved, settings: settings) }
                    group.addTask { @MainActor in await self.loadRatings(meta: resolved, settings: settings) }
                }
                return
            }
        }
        error = L10n.text("detail.load_failed", fallback: "Could not load details for this title.")
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

        // TMDB recommendations fill the row when it is the chosen source, and otherwise only
        // when the chosen source came back with nothing.
        if settings.tmdb.useMoreLikeThis, moreLikeThis.isEmpty {
            moreLikeThis = result.recommendations
        }

        await loadCollection(result.collection, meta: merged, settings: settings)

        await enrichEpisodes(season: selectedSeason, settings: settings)
    }

    /// Fills episode names, overviews and stills from TMDB — the reader for `tmdb_use_episodes`,
    /// which had a switch in Integrations and no effect anywhere.
    ///
    /// Only blanks are filled. An addon that already returned a title and a still keeps both:
    /// it knows which cut of the episode it is serving and TMDB does not.
    func enrichEpisodes(season: Int, settings: AppSettings) async {
        guard settings.tmdb.useEpisodes, settings.tmdb.isUsable,
              let tmdbId = enrichment?.tmdbId,
              let current = meta, current.type == .series,
              !episodeEnrichedSeasons.contains(season)
        else { return }
        episodeEnrichedSeasons.insert(season)

        let details = await TMDBClient.shared.seasonEpisodes(
            tmdbId: tmdbId,
            season: season,
            apiKey: settings.tmdb.apiKey,
            language: settings.tmdb.language
        )
        guard !details.isEmpty, var updated = meta else { return }
        updated.videos = Self.merging(details, into: updated.videos, season: season)
        meta = updated
    }

    /// Pure so the merge rule — fill blanks, never overwrite — is testable on its own.
    nonisolated static func merging(
        _ details: [TMDBClient.EpisodeDetail],
        into videos: [Video],
        season: Int
    ) -> [Video] {
        let byNumber = Dictionary(
            details.map { ($0.episode, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return videos.map { video in
            guard video.season == season,
                  let number = video.episode,
                  let detail = byNumber[number]
            else { return video }
            var merged = video
            if merged.name?.nilIfBlank == nil, merged.title?.nilIfBlank == nil { merged.name = detail.name }
            if merged.overview?.nilIfBlank == nil, merged.description?.nilIfBlank == nil {
                merged.overview = detail.overview
            }
            if merged.thumbnail?.nilIfBlank == nil { merged.thumbnail = detail.still }
            if merged.released?.nilIfBlank == nil { merged.released = detail.airDate }
            if merged.runtime?.nilIfBlank == nil, let minutes = detail.runtimeMinutes {
                merged.runtime = "\(minutes) min"
            }
            if merged.tmdbRating == nil { merged.tmdbRating = detail.rating }
            return merged
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

    /// Port of `MoreLikeThisSection`, now honouring `more_like_this_source`.
    ///
    /// The preference had a picker in Tracking settings and no reader: every viewer got the
    /// addon-catalog behaviour whichever of the three they chose. TMDB and Trakt fall back to
    /// the catalog rather than leaving the row empty, because an empty row reads as "nothing is
    /// like this" rather than "that account is not connected".
    private func loadMoreLikeThis(addonStore: AddonStore, meta: Meta, settings: AppSettings) async {
        switch settings.tracking.moreLikeThisSource {
        case .tmdb:
            // Filled from the TMDB enrichment that runs alongside this one, so there is nothing
            // to fetch twice — unless TMDB is not configured, in which case fall through.
            guard !settings.tmdb.isUsable else { return }
            await loadMoreLikeThisFromCatalog(addonStore: addonStore, meta: meta)
        case .trakt:
            let clientId = settings.tracking.traktClientId
            if !clientId.isEmpty, let imdbId = meta.imdbId ?? idIfImdb(meta.id) {
                let items = await TraktClient.shared.related(
                    imdbId: imdbId, type: meta.type, clientId: clientId
                )
                if !items.isEmpty {
                    moreLikeThis = items.filter { $0.id != meta.id }
                    return
                }
            }
            await loadMoreLikeThisFromCatalog(addonStore: addonStore, meta: meta)
        case .addonCatalog:
            await loadMoreLikeThisFromCatalog(addonStore: addonStore, meta: meta)
        }
    }

    /// The franchise row. The two rules that shape it are in `FranchiseCollectionRow`.
    private func loadCollection(
        _ reference: TMDBClient.Collection?,
        meta: Meta,
        settings: AppSettings
    ) async {
        guard meta.type == .movie, let reference, settings.tmdb.isUsable else {
            collection = nil
            return
        }
        let parts = await TMDBClient.shared.collectionItems(
            kind: .collection,
            tmdbId: reference.id,
            type: .movie,
            sortBy: "",
            page: 1,
            apiKey: settings.tmdb.apiKey,
            language: settings.tmdb.language
        )
        let others = FranchiseCollectionRow.others(in: parts, excluding: meta)
        collection = FranchiseCollectionRow.isWorthShowing(others) ? (reference.name, others) : nil
    }

    /// Genre-matched items from the first catalog that supports a genre filter for this type.
    private func loadMoreLikeThisFromCatalog(addonStore: AddonStore, meta: Meta) async {
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
