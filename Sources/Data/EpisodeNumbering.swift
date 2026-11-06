import Foundation

/// Episode numbers as Trakt and MDBList want them, and back. See `EpisodeRemap` for the why.
///
/// The rules are upstream's, each kept for the case it was written for:
/// - **Writes to Trakt** (scrobble, history) remap when the addon's season structure differs
///   from Trakt's.
/// - **Reads from Trakt** remap only an episode the addon does not have (1.1.0-beta.11, f07acf60).
///   Remapping every episode of a long show whose counts differ in one early season shifted
///   every later episode — The Daily Show's recent episodes moved 26 places.
/// - **MDBList**, which numbers as TMDB does, keeps a show's numbers when both sides have the
///   same seasons, so a merged two-parter cannot shift whole seasons (1.1.0-beta.10, facf25ec).
///
/// Lists and mappings are cached for the session; a failure caches nothing, so the next
/// request tries again and in the meantime numbers go through unchanged.
@MainActor
final class EpisodeNumbering {
    static let shared = EpisodeNumbering()

    /// Where the addon's own list comes from: the series' content id and the stores that can
    /// fetch it.
    struct Source {
        var contentId: String
        var library: LibraryStore
        var addons: AddonStore
    }

    private var addonLists: [String: [EpisodeRemap.Entry]] = [:]
    private var traktLists: [String: [EpisodeRemap.Entry]] = [:]
    /// TMDB numbering per content id; an empty list means "same seasons, keep the numbers".
    private var tmdbLists: [String: [EpisodeRemap.Entry]] = [:]

    // MARK: Trakt

    /// The (season, episode) to send Trakt for the addon's episode.
    func traktNumbers(
        season: Int, episode: Int, videoId: String?, title: String? = nil,
        imdbId: String, source: Source, clientId: String, token: String
    ) async -> (season: Int, episode: Int) {
        let addon = await addonEpisodes(source)
        guard !addon.isEmpty else { return (season, episode) }
        let trakt = await traktEpisodes(imdbId: imdbId, clientId: clientId, token: token)
        guard !trakt.isEmpty, !EpisodeRemap.hasSameSeasonStructure(addon, trakt),
              let mapped = EpisodeRemap.remap(
                  season: season, episode: episode, videoId: videoId, title: title,
                  from: addon, to: trakt
              )
        else { return (season, episode) }
        return (mapped.season, mapped.episode)
    }

    /// The addon's episode for one Trakt reports, or nil when the addon has that exact episode
    /// (or nothing can be matched) and the number stands.
    func addonEpisode(
        forTraktSeason season: Int, episode: Int, title: String? = nil,
        imdbId: String, source: Source, clientId: String, token: String
    ) async -> EpisodeRemap.Entry? {
        let addon = await addonEpisodes(source)
        guard !addon.isEmpty,
              !addon.contains(where: { $0.season == season && $0.episode == episode })
        else { return nil }
        let trakt = await traktEpisodes(imdbId: imdbId, clientId: clientId, token: token)
        return EpisodeRemap.remap(season: season, episode: episode, title: title, from: trakt, to: addon)
    }

    // MARK: MDBList

    /// The (season, episode) to send MDBList — TMDB's numbering — for the addon's episode.
    func mdbListNumbers(
        season: Int, episode: Int, videoId: String?, title: String? = nil,
        source: Source, imdbId: String?, tmdbApiKey: String
    ) async -> (season: Int, episode: Int) {
        let addon = await addonEpisodes(source)
        let tmdb = await tmdbEpisodes(source: source, addon: addon, imdbId: imdbId, apiKey: tmdbApiKey)
        guard !tmdb.isEmpty,
              let mapped = EpisodeRemap.remap(
                  season: season, episode: episode, videoId: videoId, title: title,
                  from: addon, to: tmdb
              )
        else { return (season, episode) }
        return (mapped.season, mapped.episode)
    }

    /// The addon's episode for one MDBList reports, or nil when the show keeps its numbers.
    func addonEpisode(
        forMDBListSeason season: Int, episode: Int, title: String? = nil,
        source: Source, imdbId: String?, tmdbApiKey: String
    ) async -> EpisodeRemap.Entry? {
        let addon = await addonEpisodes(source)
        let tmdb = await tmdbEpisodes(source: source, addon: addon, imdbId: imdbId, apiKey: tmdbApiKey)
        guard !tmdb.isEmpty else { return nil }
        return EpisodeRemap.remap(season: season, episode: episode, title: title, from: tmdb, to: addon)
    }

    // MARK: Lists

    /// A list a screen already has, so the next translation for this show needs no fetch.
    func remember(_ refs: [SeriesEpisodeRef], forContentId contentId: String) {
        let list = Self.entries(from: refs)
        guard !list.isEmpty else { return }
        addonLists[contentId] = list
    }

    func addonEpisodes(_ source: Source) async -> [EpisodeRemap.Entry] {
        let key = "addon|\(source.contentId)"
        if let cached = addonLists[source.contentId] { return cached }
        let list = await shared(key) {
            let refs = await SeriesEpisodeCatalogue.episodes(
                forContentId: source.contentId, library: source.library, addons: source.addons
            )
            return Self.entries(from: refs)
        }
        if !list.isEmpty { addonLists[source.contentId] = list }
        return list
    }

    nonisolated static func entries(from refs: [SeriesEpisodeRef]) -> [EpisodeRemap.Entry] {
        var seen = Set<String>()
        return refs
            .filter { $0.season > 0 }
            .filter { seen.insert($0.videoId.isEmpty ? "\($0.season):\($0.episode)" : $0.videoId).inserted }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
            .map { .init(season: $0.season, episode: $0.episode, title: $0.title, videoId: $0.videoId) }
    }

    private func traktEpisodes(imdbId: String, clientId: String, token: String) async -> [EpisodeRemap.Entry] {
        if let cached = traktLists[imdbId] { return cached }
        let list = await shared("trakt|\(imdbId)") {
            await TraktClient.shared.showEpisodes(id: imdbId, clientId: clientId, token: token)
        }
        if !list.isEmpty { traktLists[imdbId] = list }
        return list
    }

    /// TMDB's list, or empty when the show keeps its numbers (same seasons on both sides) or
    /// TMDB cannot be asked — no key, no id. Only a definite answer is cached.
    private func tmdbEpisodes(
        source: Source, addon: [EpisodeRemap.Entry], imdbId: String?, apiKey: String
    ) async -> [EpisodeRemap.Entry] {
        let contentId = source.contentId
        if let cached = tmdbLists[contentId] { return cached }
        guard !addon.isEmpty, !apiKey.isEmpty else { return [] }
        let answer: [EpisodeRemap.Entry]? = await shared("tmdb|\(contentId)") {
            guard let tmdbId = await Self.tmdbId(contentId: contentId, imdbId: imdbId, apiKey: apiKey) else {
                return nil
            }
            let counts = await TMDBClient.shared.seasonCounts(tmdbId: tmdbId, apiKey: apiKey)
            guard !counts.isEmpty else { return nil }
            if Set(counts.keys) == Set(EpisodeRemap.seasonCounts(addon).keys) { return [] }
            var episodes: [EpisodeRemap.Entry] = []
            for season in counts.keys.sorted() {
                let details = await TMDBClient.shared.seasonEpisodes(
                    tmdbId: tmdbId, season: season, apiKey: apiKey, language: "en-US"
                )
                guard !details.isEmpty else { return nil }
                episodes += details.filter { $0.episode > 0 }.map {
                    EpisodeRemap.Entry(season: season, episode: $0.episode, title: $0.name)
                }
            }
            return EpisodeRemap.hasSameSeasonStructure(addon, episodes) ? [] : episodes
        }
        guard let answer else { return [] }
        tmdbLists[contentId] = answer
        return answer
    }

    nonisolated private static func tmdbId(contentId: String, imdbId: String?, apiKey: String) async -> Int? {
        if contentId.hasPrefix("tmdb:"), let id = Int(contentId.dropFirst(5).split(separator: ":").first ?? "") {
            return id
        }
        let imdb = imdbId?.nilIfBlank ?? (contentId.hasPrefix("tt") ? String(contentId.split(separator: ":")[0]) : nil)
        guard let imdb else { return nil }
        return await TMDBClient.shared.tmdbId(imdbId: imdb, type: .series, apiKey: apiKey)
    }

    /// One fetch per key at a time; callers arriving while it runs share its answer.
    private var inFlightAny: [String: Any] = [:]

    private func shared<Value>(
        _ key: String, _ work: @escaping @MainActor () async -> Value
    ) async -> Value {
        if let running = inFlightAny[key] as? Task<Value, Never> { return await running.value }
        let task = Task { await work() }
        inFlightAny[key] = task
        let value = await task.value
        inFlightAny[key] = nil
        return value
    }
}
