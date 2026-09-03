import Foundation

/// When a film's end-of-playback recommendations appear, and which one is in front.
///
/// Upstream shows these for both films and episodes; ours has covered episodes since the first
/// port — that is `PostPlayOverlay` and the next-episode rules behind it. What was missing is the
/// film case, where playback simply ended and offered nothing.
///
/// The trailer half of upstream's overlay is not ported: it autoplays a YouTube trailer behind
/// the cards, and tvOS has no supported YouTube playback path. The recommendations themselves are
/// the feature; the trailer was decoration the platform refuses.
enum PostPlayRecommendation {
    /// Upstream's bounds, kept exactly. Below 80% a film is not ending, it is still running.
    static let thresholdRange = 80...100
    static let defaultThresholdPercent = 90

    /// How far ahead of the threshold the fetch starts, in percentage points. Recommendations
    /// come from the network, so asking at the moment they are due would show an empty overlay
    /// and fill it a second later.
    static let prefetchLeadPercent = 5

    static func clampThreshold(_ percent: Int) -> Int {
        min(thresholdRange.upperBound, max(thresholdRange.lowerBound, percent))
    }

    /// The progress fraction at which to start fetching.
    static func prefetchProgress(thresholdPercent: Int) -> Double {
        Double(clampThreshold(thresholdPercent) - prefetchLeadPercent) / 100
    }

    /// Whether the overlay is due. Films only — a series at the end of an episode is the next
    /// episode card's business, and two overlays competing for the same moment is how you get
    /// one drawn over the other.
    static func shouldShow(
        contentType: ContentType,
        positionSeconds: Double,
        durationSeconds: Double,
        thresholdPercent: Int
    ) -> Bool {
        guard contentType == .movie, durationSeconds > 0 else { return false }
        let position = min(max(0, positionSeconds), durationSeconds)
        return position / durationSeconds >= Double(clampThreshold(thresholdPercent)) / 100
    }

    // MARK: - The carousel

    /// Moves the selection without wrapping.
    ///
    /// Deliberately not a ring: on a remote, wrapping from the last card back to the first is
    /// indistinguishable from the list having jumped, because nothing on screen says a boundary
    /// was crossed. Upstream's arrows disable at the ends and so does this.
    static func step(selection: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count - 1, max(0, selection + delta))
    }

    static func canStep(selection: Int, by delta: Int, count: Int) -> Bool {
        guard count > 1 else { return false }
        return step(selection: selection, by: delta, count: count) != selection
    }

    /// What the overlay actually draws. Capped: the row is browsed with a remote, and a
    /// recommendation twenty cards deep is one nobody reaches.
    static let maximumCards = 12

    static func cards(from recommendations: [MetaPreview], excluding contentId: String) -> [MetaPreview] {
        var seen = Set<String>()
        return recommendations
            .filter { $0.id != contentId }
            .filter { seen.insert($0.rowKey).inserted }
            .prefix(maximumCards)
            .map { $0 }
    }
}
