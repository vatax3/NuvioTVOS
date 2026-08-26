import Foundation

/// Which remote resume points a Continue Watching removal should take with it.
///
/// Removing a row was local only, and when watch progress comes from Trakt or Simkl the next
/// sync adopted the remote point straight back. The row reappeared, looking like the removal had
/// failed — which, from the viewer's side, it had.
///
/// Split out from the clients because the matching is the part with judgement in it, and because
/// deciding *not* to delete something on somebody's tracking account deserves a test.
enum RemoteResumePointRemoval {
    /// A resume point reduced to what the match needs.
    struct Session: Equatable {
        var sessionId: Int
        var contentId: String
        var season: Int?
        var episode: Int?
    }

    /// The sessions to delete for a removal.
    ///
    /// - Parameters:
    ///   - contentId: the title whose row was removed.
    ///   - season: named only when the removal was of one episode. Continue Watching removes the
    ///     whole title, so this is usually nil — and nil means every session for it.
    static func sessions(
        in sessions: [Session],
        contentId: String,
        season: Int? = nil,
        episode: Int? = nil
    ) -> [Int] {
        let target = contentId.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty id would match nothing under a case-insensitive compare, but an empty *list*
        // of ids is what a caller would then delete — so refuse it here rather than rely on that.
        guard !target.isEmpty else { return [] }

        return sessions
            .filter { session in
                guard session.contentId.caseInsensitiveCompare(target) == .orderedSame else {
                    return false
                }
                guard let season, let episode else { return true }
                return session.season == season && session.episode == episode
            }
            .map(\.sessionId)
    }
}
