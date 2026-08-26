import Foundation

/// Fetches a series' episode list and puts it in the cache Continue Watching reads.
///
/// Until now the cache was filled only by opening the detail screen, which left two things
/// half-working: Next Up could not project a series the viewer started from a rail and never
/// opened, and the watched walk had nothing to walk. One fetch serves both.
@MainActor
enum SeriesEpisodeCatalogue {
    /// The episodes for a series, from the cache when they are there and from the addons when
    /// they are not.
    ///
    /// - Returns: an empty array when no installed addon can answer, which callers must treat as
    ///   "unknown" rather than "none" — see `SeriesWatchedWalk.canWalk`.
    @discardableResult
    static func episodes(
        forContentId contentId: String,
        library: LibraryStore,
        addons: AddonStore,
        client: StremioClient = .shared
    ) async -> [SeriesEpisodeRef] {
        if let cached = library.seriesEpisodes[contentId], !cached.isEmpty { return cached }

        let candidates = addons.addonsProviding(resource: "meta", type: "series", id: contentId)
        for addon in candidates {
            guard let meta = try? await client.fetchMeta(addon: addon, type: "series", id: contentId),
                  meta.type == .series
            else { continue }
            let episodes = meta.episodeRefs
            guard !episodes.isEmpty else { continue }
            library.cacheEpisodes(episodes, forContentId: contentId)
            return episodes
        }
        return []
    }

    /// Fills the cache for series already in Continue Watching that have never been opened.
    ///
    /// Bounded on purpose. This runs when Home appears, and a viewer with thirty series in
    /// progress should not cause thirty addon round trips before the rail draws — the ones that
    /// matter are the ones at the front of it.
    static let seedLimit = 4

    static func seed(
        contentIds: [String],
        library: LibraryStore,
        addons: AddonStore,
        client: StremioClient = .shared
    ) async {
        let missing = contentIds
            .filter { (library.seriesEpisodes[$0] ?? []).isEmpty }
            .prefix(seedLimit)

        for contentId in missing {
            await episodes(forContentId: contentId, library: library, addons: addons, client: client)
        }
    }
}
