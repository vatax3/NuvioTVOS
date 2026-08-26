import Foundation

/// One episode of a series, reduced to what Continue Watching needs to offer it.
///
/// Stored rather than re-fetched: the rail is drawn on the first frame of Home, and an addon
/// round trip per series would mean the rail arrives after the viewer has already moved past it.
struct SeriesEpisodeRef: Codable, Hashable, Sendable {
    var videoId: String
    var season: Int
    var episode: Int
    var title: String?
    var thumbnail: String?
    /// The air date, when the addon published one.
    var released: Date?

    /// Ordered by season then episode, which is the order a viewer watches in and not
    /// necessarily the order the addon listed them.
    var order: Int { season * 10_000 + episode }
}

/// Which episode of a series to offer once the last one has been finished.
///
/// Without this the rail is only ever "half-watched episodes": finishing one removes the series
/// from Home entirely, and the viewer has to go and find the next episode themselves. That is
/// the difference between Continue Watching and a list of things you abandoned partway.
enum NextUpProjection {
    /// Whether an episode can be offered yet.
    ///
    /// An addon lists a whole season the day the first episode airs, so "the next episode
    /// exists" is not the same as "the next episode exists yet". Without the date check, every
    /// currently-airing series sits in the rail pointing at an episode that will not play.
    static func hasAired(_ episode: SeriesEpisodeRef, now: Date = Date()) -> Bool {
        guard let released = episode.released else {
            // No date published. Offering it is the better failure: a viewer who presses it
            // sees an empty source list, where hiding it loses an episode that did air.
            return true
        }
        return released <= now
    }

    /// The next episode to offer, or `nil` when there is nothing to offer.
    ///
    /// - Parameters:
    ///   - episodes: every episode the series is known to have.
    ///   - isWatched: whether a given episode's video id has been finished.
    ///   - after: the furthest point reached, when one is known.
    ///   - allowsUnaired: `show_unaired_next_up`. Off by default, as upstream has it.
    static func next(
        in episodes: [SeriesEpisodeRef],
        isWatched: (String) -> Bool,
        after furthest: (season: Int, episode: Int)?,
        allowsUnaired: Bool = false,
        now: Date = Date()
    ) -> SeriesEpisodeRef? {
        let ordered = episodes.sorted { $0.order < $1.order }
        let floor = furthest.map { $0.season * 10_000 + $0.episode } ?? -1

        return ordered.first { candidate in
            candidate.order > floor
                && !isWatched(candidate.videoId)
                && (allowsUnaired || hasAired(candidate, now: now))
        }
    }

    /// The furthest episode the viewer has reached, which is where the search starts.
    ///
    /// `next_up_from_furthest_episode`: on, the season finale you watched out of order still
    /// counts as progress; off, the *most recently watched* episode is the anchor, so going back
    /// to rewatch episode two offers episode three rather than jumping to the end again.
    static func anchor(
        watched: [(episode: SeriesEpisodeRef, watchedAt: Date)],
        fromFurthest: Bool
    ) -> (season: Int, episode: Int)? {
        guard !watched.isEmpty else { return nil }
        let chosen = fromFurthest
            ? watched.max { $0.episode.order < $1.episode.order }
            : watched.max { $0.watchedAt < $1.watchedAt }
        guard let chosen else { return nil }
        return (chosen.episode.season, chosen.episode.episode)
    }
}

/// What Continue Watching does with a series the viewer has finished every aired episode of.
///
/// Ported with its history intact, because the history is the point. Upstream dropped such a
/// series from the rail the day a new episode aired — the exact moment it becomes interesting
/// again. Never dropping is the rule; the badge is what changes.
enum CaughtUpSeries {
    enum Action: Equatable {
        /// The next episode has not aired: keep the row, keep the caught-up mark.
        case keepWithBadge
        /// It has aired, so the viewer is no longer caught up. Keep the row, drop the mark.
        case keepAndClearBadge
    }

    static func action(nextEpisodeHasAired: Bool) -> Action {
        nextEpisodeHasAired ? .keepAndClearBadge : .keepWithBadge
    }

    /// Kept as an explicit answer rather than an absence, so the regression has something to
    /// fail against if anybody reintroduces it.
    static func shouldDropFromContinueWatching(nextEpisodeHasAired: Bool) -> Bool { false }
}

/// Suggestions the viewer has waved away.
///
/// Keyed by content id alone, matching Android's display path: dismissing a series means "stop
/// offering me this show", not "stop offering me this one episode" — the latter would resurface
/// the moment the next episode aired, which is not what the gesture meant.
enum NextUpDismissal {
    static func key(contentId: String) -> String {
        contentId.trimmingCharacters(in: .whitespaces)
    }

    static func isDismissed(contentId: String, keys: [String]) -> Bool {
        keys.contains(key(contentId: contentId))
    }

    /// A dismissal is spent as soon as the viewer starts watching the series again — otherwise
    /// one wave-away silences the show for good, including seasons that have not aired yet.
    static func clearing(contentId: String, from keys: [String]) -> [String] {
        keys.filter { $0 != key(contentId: contentId) }
    }

    static func adding(contentId: String, to keys: [String]) -> [String] {
        let key = key(contentId: contentId)
        return keys.contains(key) ? keys : keys + [key]
    }
}

/// The viewer's Next Up preferences, gathered so `LibraryStore` takes one argument rather than
/// four and so a caller cannot pass three of them and forget the fourth.
struct NextUpOptions: Equatable {
    /// Off leaves Continue Watching as a list of half-watched episodes only.
    var isEnabled: Bool = true
    /// `show_unaired_next_up`.
    var allowsUnaired: Bool = false
    /// `next_up_from_furthest_episode`.
    var fromFurthestEpisode: Bool = false
    /// `dismissed_next_up_keys`.
    var dismissedKeys: [String] = []
}
