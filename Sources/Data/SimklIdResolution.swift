import Foundation

/// Resolving an anime's MyAnimeList id, and its real TVDB season and episode, through Simkl.
///
/// Ported from upstream 0.8.12, which replaced the ARM service for this. The bug ARM caused is
/// worth stating, because our port carries the same one: ARM returns a flat per-season array of
/// MAL ids, so a season is looked up by its index. Anime seasons do not number the way IMDb and
/// TVDB number them — a two-cour show is one MAL entry and two TVDB seasons, a season of specials
/// shifts everything after it — so the index lands on the wrong entry and AniSkip returns skip
/// marks for a different episode entirely. See `AniSkipClient.malId(fromSeasonEntries:season:)`,
/// which is exactly that flat lookup.
///
/// Simkl answers the mapping directly: one redirect to find the title, one call for its ids, one
/// for its episode list with each episode's TVDB season and number.
enum SimklIdResolution {
    struct Redirect: Equatable {
        var type: String
        var simklId: Int
    }

    /// A single episode's place in both numbering schemes.
    struct EpisodeMapping: Equatable {
        var animeEpisode: Int
        var tvdbSeason: Int
        var tvdbEpisode: Int
    }

    /// Simkl answers the redirect with a `Location` rather than a body, so the id has to be read
    /// out of the URL. The type segment is found by name rather than by position, because the
    /// path has carried a locale prefix before now.
    static func parseRedirect(location: String) -> Redirect? {
        let path = location.split(separator: "?", maxSplits: 1).first.map(String.init) ?? location
        let segments = path.split(separator: "/").map(String.init)
        guard let index = segments.lastIndex(where: { ["anime", "tv", "movies"].contains($0) }),
              segments.indices.contains(index + 1),
              let id = Int(segments[index + 1])
        else { return nil }
        return Redirect(type: segments[index], simklId: id)
    }

    /// Keeps only entries where both numbering schemes are present and positive. A zero or a
    /// missing TVDB block is Simkl saying it does not know, and a zero season would send
    /// AniSkip looking at specials.
    static func mappings(from episodes: [(episode: Int?, tvdbSeason: Int?, tvdbEpisode: Int?)]) -> [EpisodeMapping] {
        episodes.compactMap { entry in
            guard let episode = entry.episode, episode > 0,
                  let season = entry.tvdbSeason, season > 0,
                  let number = entry.tvdbEpisode, number > 0
            else { return nil }
            return EpisodeMapping(animeEpisode: episode, tvdbSeason: season, tvdbEpisode: number)
        }
    }

    /// The TVDB pair for one anime episode number.
    static func tvdb(for animeEpisode: Int, in mappings: [EpisodeMapping]) -> (season: Int, episode: Int)? {
        guard let hit = mappings.first(where: { $0.animeEpisode == animeEpisode }) else { return nil }
        return (hit.tvdbSeason, hit.tvdbEpisode)
    }

    /// The reverse: the viewer is watching S02E03 by TVDB numbering and AniSkip wants the anime's
    /// own episode number. This is the direction that matters for skip marks, and the one the
    /// flat ARM index got wrong.
    static func animeEpisode(forTvdbSeason season: Int, episode: Int, in mappings: [EpisodeMapping]) -> Int? {
        mappings.first { $0.tvdbSeason == season && $0.tvdbEpisode == episode }?.animeEpisode
    }
}
