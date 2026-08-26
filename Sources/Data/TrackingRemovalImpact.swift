import Foundation

/// What removing a title from a tracking account actually destroys there.
///
/// Upstream warns generically about "watched history and rating". This is narrower on purpose,
/// because it is checked against our own writes rather than ported wording: the two providers do
/// genuinely different things, and a warning that fires where nothing is lost teaches people to
/// dismiss the one that matters.
///
/// - **Simkl** removes with `sync/history/remove` — the same call "mark unwatched" makes. The
///   list state and the watched history are one record there, so taking a title out of the
///   library erases every episode you had marked. Irreversible.
/// - **Trakt** removes with `sync/watchlist` remove, which touches the watchlist and nothing
///   else. History and ratings stay. Nothing to warn about.
enum TrackingRemovalImpact {
    enum Loss: Equatable {
        case watchedHistory
    }

    /// What is lost by removing this title from that provider, or nothing.
    static func losses(removingFrom provider: TrackingProviderId?) -> [Loss] {
        switch provider {
        case .simkl: return [.watchedHistory]
        case .trakt, nil: return []
        }
    }

    static func requiresConfirmation(removingFrom provider: TrackingProviderId?) -> Bool {
        !losses(removingFrom: provider).isEmpty
    }

    /// The question, naming the provider and the title so it cannot be read as being about the
    /// local library.
    static func prompt(title: String, provider: TrackingProviderId) -> String {
        "Remove \(title) from \(provider.displayName)?"
    }

    /// The consequence, in the words of the thing that goes.
    static func caution(provider: TrackingProviderId) -> String? {
        guard losses(removingFrom: provider).contains(.watchedHistory) else { return nil }
        return """
        \(provider.displayName) stores a title's list state and its watched history as one \
        record, so this also clears every episode you had marked watched there. It cannot be \
        undone from here.
        """
    }
}
