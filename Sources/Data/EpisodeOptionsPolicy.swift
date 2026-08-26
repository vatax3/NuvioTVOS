import Foundation

/// What a long press on an episode offers.
///
/// The gap this closes is smaller than it sounds and worse than it sounds: there was no way to
/// mark a single episode watched anywhere in the app. Playing it past the threshold, or marking
/// the whole series — nothing in between. Somebody who watched an episode elsewhere had no
/// recourse, and Continue Watching went on offering it.
enum EpisodeOptionsPolicy {
    enum Action: String, Identifiable, Hashable, CaseIterable {
        case play
        case startFromBeginning
        case markWatched
        case markUnwatched
        case markSeasonWatched
        case markSeasonUnwatched
        case markPreviousWatched
        case openComments

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .play: return "play.fill"
            case .startFromBeginning: return "backward.end.fill"
            case .markWatched: return "eye.fill"
            case .markUnwatched: return "eye.slash"
            case .markSeasonWatched: return "eye.circle.fill"
            case .markSeasonUnwatched: return "eye.slash.circle"
            case .markPreviousWatched: return "text.line.first.and.arrowtriangle.forward"
            case .openComments: return "bubble.left.and.bubble.right"
            }
        }

        /// Undoing something the viewer built up. Marked so an irreversible row is not one
        /// indistinguishable line among seven.
        var isDestructive: Bool {
            self == .markUnwatched || self == .markSeasonUnwatched
        }
    }

    struct Context: Equatable {
        var isWatched: Bool
        /// Whether a resume point exists for this episode.
        var hasProgress: Bool
        /// Whether every aired episode of this season is watched, which decides which way the
        /// season row points.
        var isSeasonWatched: Bool
        /// Whether anything precedes this episode in the season. "Mark previous watched" on the
        /// first episode of a season would be a row that does nothing.
        var hasPreviousEpisodes: Bool
        /// Trakt comments need a client id and the setting on, same as the title's own button.
        var canOpenComments: Bool = false
    }

    /// The rows, in the order they are drawn.
    ///
    /// Play leads because it is what the card does anyway — the overlay must not make the common
    /// case harder to reach than the rare one.
    static func actions(for context: Context) -> [Action] {
        var actions: [Action] = [.play]

        if context.hasProgress {
            actions.append(.startFromBeginning)
        }
        actions.append(context.isWatched ? .markUnwatched : .markWatched)
        actions.append(context.isSeasonWatched ? .markSeasonUnwatched : .markSeasonWatched)
        if context.hasPreviousEpisodes {
            actions.append(.markPreviousWatched)
        }
        if context.canOpenComments {
            actions.append(.openComments)
        }
        return actions
    }
}

/// Which episodes a season-level or catch-up action touches.
///
/// Shares its two exclusions with `SeriesWatchedWalk` and for the same reasons: season zero is
/// not part of the run, and marking an unaired episode watched keeps it out of Next Up on the day
/// it finally airs.
enum EpisodeWatchedSpan {
    /// Every aired episode of one season.
    static func season(
        _ season: Int,
        in episodes: [SeriesEpisodeRef],
        now: Date = Date()
    ) -> [SeriesEpisodeRef] {
        guard season > 0 else { return [] }
        return episodes
            .filter { $0.season == season && NextUpProjection.hasAired($0, now: now) }
            .sorted { $0.order < $1.order }
    }

    /// Everything before a given episode, across earlier seasons too.
    ///
    /// Across seasons because that is what the row means. Somebody starting a series at season
    /// three episode one and marking everything before it watched means the two seasons before
    /// it, not the nothing that precedes it within its own.
    static func precedingAndIncluding(
        _ target: SeriesEpisodeRef,
        in episodes: [SeriesEpisodeRef],
        now: Date = Date()
    ) -> [SeriesEpisodeRef] {
        episodes
            .filter { $0.season > 0 && $0.order <= target.order && NextUpProjection.hasAired($0, now: now) }
            .sorted { $0.order < $1.order }
    }

    /// Whether every aired episode of a season is watched.
    ///
    /// A season with nothing aired yet is not "watched" — it is a season nobody could have
    /// watched, and answering yes would offer to un-watch it.
    static func isSeasonWatched(
        _ season: Int,
        in episodes: [SeriesEpisodeRef],
        isWatched: (String) -> Bool,
        now: Date = Date()
    ) -> Bool {
        let aired = self.season(season, in: episodes, now: now)
        guard !aired.isEmpty else { return false }
        return aired.allSatisfy { isWatched($0.videoId) }
    }
}
