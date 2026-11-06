import Foundation

/// Translating an episode between an addon's numbering and a tracking service's. Port of
/// upstream's `TraktEpisodeMapping.kt` (and its MDBList use, 1.1.0-beta.10).
///
/// Anime is the case that needs it. An addon often splits a show into seasons the way its
/// broadcast cours ran, while Trakt and TMDB (which MDBList follows) list it as one long season:
/// the addon's S2E11 is the service's S1E35. Sent unchanged, a scrobble marks the wrong episode
/// or one that does not exist, and the service's resume point lands on the wrong card here.
///
/// Matching order, as upstream: the addon's own video id, then the episode title when it is a
/// real title (one match only), then the position in the whole ordered list.
enum EpisodeRemap {
    struct Entry: Hashable, Sendable {
        var season: Int
        var episode: Int
        var title: String?
        var videoId: String?
    }

    /// `source` → `target`: the target entry for the requested source episode, or nil.
    static func remap(
        season: Int,
        episode: Int,
        videoId: String? = nil,
        title: String? = nil,
        from source: [Entry],
        to target: [Entry]
    ) -> Entry? {
        guard !source.isEmpty, !target.isEmpty else { return nil }
        let orderedSource = source.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        let orderedTarget = target.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }

        let current = videoId?.nilIfBlank.flatMap { id in orderedSource.first { $0.videoId == id } }
            ?? orderedSource.first { $0.season == season && $0.episode == episode }
        guard let current else { return nil }

        let wanted = normalisedTitle(title ?? current.title)
        if isUsefulTitle(wanted) {
            let matches = orderedTarget.filter { normalisedTitle($0.title) == wanted }
            if matches.count == 1 { return matches[0] }
        }

        guard let index = orderedSource.firstIndex(of: current), index < orderedTarget.count else {
            return nil
        }
        return orderedTarget[index]
    }

    /// Per-season episode counts, not just the season numbers: anime often uses the same season
    /// numbers on both sides with entirely different splits.
    static func hasSameSeasonStructure(_ left: [Entry], _ right: [Entry]) -> Bool {
        seasonCounts(left) == seasonCounts(right)
    }

    /// MDBList's looser rule: the same seasons, whatever their counts. One side merging a
    /// two-parter changes a count by one, and matching by position would then shift every later
    /// season. Upstream keeps such shows' numbers, and so does this.
    static func hasSameSeasons(_ left: [Entry], _ right: [Entry]) -> Bool {
        Set(seasonCounts(left).keys) == Set(seasonCounts(right).keys)
    }

    static func seasonCounts(_ entries: [Entry]) -> [Int: Int] {
        Dictionary(grouping: entries, by: \.season).mapValues(\.count)
    }

    // MARK: Titles

    static func normalisedTitle(_ title: String?) -> String {
        guard let title else { return "" }
        var out = ""
        var pendingSpace = false
        for scalar in title.lowercased().unicodeScalars {
            let isAlnum = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isAlnum {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// "Episode 12" and its abbreviations name a position, not an episode.
    static func isUsefulTitle(_ normalised: String) -> Bool {
        guard !normalised.isEmpty else { return false }
        for prefix in ["episode ", "ep ", "e "] where normalised.hasPrefix(prefix) {
            let rest = normalised.dropFirst(prefix.count)
            if !rest.isEmpty, rest.allSatisfy(\.isNumber) { return false }
        }
        return true
    }
}
