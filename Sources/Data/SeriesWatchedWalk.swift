import Foundation

/// Which episodes "mark this series watched" actually touches.
///
/// The dialog offered this row for films only, and a pinned test said so: a row that quietly does
/// less than it says is worse than no row. The walk is what the row was waiting for, and the two
/// exclusions below are the reason it needed thinking about rather than a loop.
enum SeriesWatchedWalk {
    /// Episodes to mark watched.
    ///
    /// Two exclusions, both of which would otherwise be silently wrong:
    ///
    /// - **Specials.** Season zero is not part of the run somebody means when they say they have
    ///   watched a series, and Trakt's own "watch all" leaves them alone too.
    /// - **Unaired.** Marking a future episode watched is a lie that lasts: it would keep the
    ///   episode out of Next Up on the day it finally airs, which is exactly when it matters.
    static func episodesToMark(
        in episodes: [SeriesEpisodeRef],
        now: Date = Date()
    ) -> [SeriesEpisodeRef] {
        episodes
            .filter { $0.season > 0 && NextUpProjection.hasAired($0, now: now) }
            .sorted { $0.order < $1.order }
    }

    /// Episodes to clear when the viewer takes it back.
    ///
    /// Everything, specials included: the undo has to leave nothing behind, and clearing an
    /// episode that was never marked costs nothing.
    static func episodesToClear(in episodes: [SeriesEpisodeRef]) -> [SeriesEpisodeRef] {
        episodes.sorted { $0.order < $1.order }
    }

    /// Whether the walk can say anything truthful about this series.
    ///
    /// An empty list is not "a series with no episodes" — it is a series nobody has opened yet,
    /// and marking nothing while reporting success is the failure this guards.
    static func canWalk(_ episodes: [SeriesEpisodeRef]) -> Bool {
        episodes.contains { $0.season > 0 }
    }
}
