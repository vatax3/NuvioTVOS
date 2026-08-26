import Foundation

/// Which id identifies an anime on Simkl.
///
/// Anime is the one place where "the same show" is genuinely ambiguous. A franchise carries one
/// IMDb id across every season, while MAL and Kitsu give each season its own entry. Grouping is
/// right for someone who thinks of *Attack on Titan* as one show and wrong for someone tracking
/// each season separately, so it is the viewer's call and not ours.
enum SimklAnimeIdPreference: String, SettingsOption {
    /// Groups every season of a franchise under the one IMDb id. Upstream's default.
    case imdb = "IMDB"
    /// Each MyAnimeList entry is its own title.
    case mal = "MAL"
    /// Each Kitsu entry is its own title.
    case kitsu = "KITSU"

    var displayName: String {
        switch self {
        case .imdb: return "Group seasons together"
        case .mal: return "Separate, by MyAnimeList"
        case .kitsu: return "Separate, by Kitsu"
        }
    }

    var summary: String {
        switch self {
        case .imdb: return "Every season of a franchise appears as one title"
        case .mal: return "Each MyAnimeList entry gets its own row in the library"
        case .kitsu: return "Each Kitsu entry gets its own row in the library"
        }
    }

    /// The id keys to try, in order, before the general fallback.
    var preferredKeys: [String] {
        switch self {
        case .imdb: return ["imdb"]
        case .mal: return ["mal", "imdb"]
        case .kitsu: return ["kitsu", "imdb"]
        }
    }
}

/// How an anime episode is addressed when it is written to Simkl.
///
/// Simkl accepts two shapes and they cannot be mixed. Sending both a franchise IMDb id and a
/// per-season MAL id is not "more information" — it is a contradiction, and Simkl resolves it by
/// matching whichever it recognises first, which is how a watched episode lands on the wrong
/// season of the wrong entry.
enum SimklAnimeAddressing {
    /// The two shapes.
    enum Form: Equatable {
        /// The addon numbered the episode within a season. Keep the franchise ids, drop the
        /// per-season anime ids, and tell Simkl the coordinates are TVDB-style.
        case seasoned(season: Int, episode: Int)
        /// The video id names a specific anime entry and an absolute episode within it —
        /// `mal:42203:7` is episode 7 *of that entry*, whatever the interface calls it.
        case flat(episode: Int)
    }

    struct Resolution: Equatable {
        var ids: [String: String]
        var form: Form

        var season: Int? {
            if case .seasoned(let season, _) = form { return season }
            return nil
        }

        var episode: Int {
            switch form {
            case .seasoned(_, let episode): return episode
            case .flat(let episode): return episode
            }
        }

        /// `use_tvdb_anime_seasons`, which is how Simkl is told the numbers are per-season
        /// rather than absolute.
        var usesTvdbSeasons: Bool {
            if case .seasoned = form { return true }
            return false
        }
    }

    /// The anime id namespaces, in the order Simkl prefers them.
    static let animeKeys = ["mal", "anidb", "anilist", "kitsu"]

    /// Reads `mal:42203:7` and friends: a namespace, an entry, and an absolute episode.
    ///
    /// Returns `nil` for anything else, including a bare `mal:42203` with no episode — that
    /// addresses the series, not an episode of it.
    static func parseVideoId(_ videoId: String) -> (key: String, id: String, episode: Int)? {
        let parts = videoId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let key = parts[0].lowercased()
        guard animeKeys.contains(key), !parts[1].isEmpty, let episode = Int(parts[2]) else {
            return nil
        }
        return (key, parts[1], episode)
    }

    /// Resolves how one episode should be addressed.
    ///
    /// - Parameters:
    ///   - videoId: the addon's own id for the episode.
    ///   - ids: every id known for the title.
    ///   - season: the season the interface is showing, when it has one.
    ///   - episode: the episode number the interface is showing.
    static func resolve(
        videoId: String?,
        ids: [String: String],
        season: Int?,
        episode: Int?
    ) -> Resolution {
        // A video id that names an anime entry and an absolute episode wins outright: it is the
        // most specific thing anybody knows, and it is what Simkl's anime catalogue is keyed on.
        if let videoId, let parsed = parseVideoId(videoId) {
            return Resolution(ids: [parsed.key: parsed.id], form: .flat(episode: parsed.episode))
        }

        // Season coordinates: the franchise ids are the right ones, and the per-season anime
        // ids have to go or Simkl will prefer one of them and land on the wrong entry.
        if let season, season > 0, let episode {
            return Resolution(
                ids: ids.filter { !animeKeys.contains($0.key) },
                form: .seasoned(season: season, episode: episode)
            )
        }

        // Neither: a film, or a series the addon numbered flatly. Episode one is Simkl's own
        // fallback for an anime film, which has exactly one.
        return Resolution(ids: ids, form: .flat(episode: episode ?? 1))
    }
}
