import Foundation

/// Per-show shuffle preferences. Two switches, stored against the content id.
struct EpisodeShuffleSettings: Codable, Hashable, Sendable {
    var isEnabled = false
    /// Offer episodes already watched. Off by default, which makes shuffle a way through a series
    /// you have not finished rather than a way around one you have.
    var includesWatched = false
}

/// Choosing a random episode without repeating itself.
///
/// Port of upstream's `RandomEpisodePicker`, with one change of shape: their picker is an object
/// that owns its own history and is handed from one instance to the next by `inheritHistoryFrom`.
/// Here the history is a value the caller holds, so the choice itself is a pure function of its
/// inputs — which is the whole of what is worth testing about it.
///
/// The rule that makes this feel like shuffle rather than a dice roll: a pick is drawn from the
/// episodes **not yet shown**, and only when those run out is the set cleared — and even then the
/// immediately previous pick is excluded, so an exhausted pool never hands you the same episode
/// twice in a row.
enum RandomEpisodePick {
    /// What has already been offered, so the next draw can avoid it.
    struct History: Equatable, Sendable {
        var shown: Set<String> = []
        var last: String?

        mutating func record(_ videoId: String) {
            shown.insert(videoId)
            last = videoId
        }
    }

    /// The episodes a shuffle may offer, out of those already judged watchable.
    ///
    /// Airing and availability are `Meta.watchableEpisodes()`'s business and callers pass its
    /// result; what is added here is the part specific to drawing lots — a real id, a real
    /// episode number, and **no duplicates**, because an addon listing one episode under two ids
    /// would otherwise weight it twice.
    static func candidates(
        in videos: [Video],
        watched: Set<String>,
        includeWatched: Bool,
        excluding current: String? = nil
    ) -> [Video] {
        var seenKeys: Set<String> = []
        var seenIds: Set<String> = []
        var pool: [Video] = []
        for video in videos {
            guard !video.id.isEmpty, let season = video.season, let episode = video.episode,
                  episode > 0, season > 0
            else { continue }
            let key = "\(season):\(episode)"
            guard !seenKeys.contains(key), !seenIds.contains(video.id) else { continue }
            seenKeys.insert(key)
            seenIds.insert(video.id)
            guard video.id != current else { continue }
            guard includeWatched || !watched.contains(video.id) else { continue }
            pool.append(video)
        }
        return pool
    }

    /// One episode, or nil when nothing is left to offer — which the caller has to say out loud
    /// rather than silently falling back to episode one. "Nothing unwatched left" is a real
    /// answer and the viewer's next move is to include watched episodes.
    static func pick<G: RandomNumberGenerator>(
        from videos: [Video],
        watched: Set<String>,
        includeWatched: Bool,
        excluding current: String? = nil,
        history: inout History,
        using generator: inout G
    ) -> Video? {
        let pool = candidates(
            in: videos, watched: watched, includeWatched: includeWatched, excluding: current
        )
        guard !pool.isEmpty else { return nil }

        let unseen = pool.filter { !history.shown.contains($0.id) }
        let draw: [Video]
        if unseen.isEmpty {
            // Every episode has been offered. Start again, but not on the one just shown.
            history.shown.subtract(pool.map(\.id))
            let withoutLast = pool.filter { $0.id != history.last }
            draw = withoutLast.isEmpty ? pool : withoutLast
        } else {
            draw = unseen
        }

        guard let chosen = draw.randomElement(using: &generator) else { return nil }
        history.record(chosen.id)
        return chosen
    }

    /// Whether a previously offered episode is still a legal offer, for the stability rule in
    /// `EpisodeShuffleStore`: a selection survives a redraw, not a change of pool.
    static func stillValid(
        _ videoId: String,
        in videos: [Video],
        watched: Set<String>,
        includeWatched: Bool,
        excluding current: String? = nil
    ) -> Video? {
        candidates(
            in: videos, watched: watched, includeWatched: includeWatched, excluding: current
        ).first { $0.id == videoId }
    }
}
