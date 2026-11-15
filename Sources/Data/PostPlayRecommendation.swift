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
    static func prefetchProgress(
        thresholdPercent: Int,
        durationSeconds: Double = 0,
        segments: [SkipSegment] = [],
        tailWindowSeconds: Double = 0
    ) -> Double {
        guard durationSeconds > 0 else {
            return Double(clampThreshold(thresholdPercent) - prefetchLeadPercent) / 100
        }
        let trigger = triggerPositionSeconds(
            durationSeconds: durationSeconds,
            thresholdPercent: thresholdPercent,
            segments: segments,
            tailWindowSeconds: tailWindowSeconds
        )
        return max(0, trigger / durationSeconds - Double(prefetchLeadPercent) / 100)
    }

    /// Whether the overlay is due. Films only — a series at the end of an episode is the next
    /// episode card's business, and two overlays competing for the same moment is how you get
    /// one drawn over the other.
    static func shouldShow(
        contentType: ContentType,
        positionSeconds: Double,
        durationSeconds: Double,
        thresholdPercent: Int,
        segments: [SkipSegment] = [],
        tailWindowSeconds: Double = 0
    ) -> Bool {
        guard contentType == .movie, durationSeconds > 0 else { return false }
        let position = min(max(0, positionSeconds), durationSeconds)
        return position >= triggerPositionSeconds(
            durationSeconds: durationSeconds,
            thresholdPercent: thresholdPercent,
            segments: segments,
            tailWindowSeconds: tailWindowSeconds
        )
    }

    // MARK: - When the film is actually over

    /// A submitted end that overruns this release's runtime by less than this is still the end.
    /// Different releases of one film differ by a second or two at the tail.
    static let endOfVideoEpsilon: Double = 1

    /// The moment the film is over as far as the viewer is concerned.
    ///
    /// The percentage on its own is a poor answer and was the one we shipped in 1.0.35: credits
    /// run anywhere from ninety seconds to eight minutes, so 90% lands deep inside them on a long
    /// film and before the last scene on a short one. IntroDB marks where the credits start, so
    /// when it has an answer for this film the card fires on the credits instead.
    ///
    /// Three cases, in upstream's order:
    ///
    /// - a marked post-credits scene wins outright, and the card waits for its *end* — a scene is
    ///   the one part of the credits nobody wants covered by a recommendation carousel;
    /// - no marks at all falls back to the percentage;
    /// - credits with an unexplained tail after them use the tail, not the credits, because an
    ///   unmarked scene is the usual reason a film keeps running after its credits end.
    /// How much unmarked tail after the credits counts as "there may be a scene in there".
    ///
    /// Upstream reuses the *episode* threshold here rather than the film one, and clamps it hard
    /// — 97-100%, or at most three and a half minutes. The film threshold is the wrong tool: it
    /// is a tenth of the runtime by default, and every film's credits are longer than that, so
    /// every film would look like it had an unmarked scene.
    static func tailWindowSeconds(
        mode: NextEpisodeThresholdMode,
        percent: Int,
        minutesBeforeEnd: Int,
        durationSeconds: Double
    ) -> Double {
        switch mode {
        case .percent:
            let clamped = min(100, max(97, percent))
            return (1 - Double(clamped) / 100) * durationSeconds
        case .minutesBeforeEnd:
            return min(3.5, max(0, Double(minutesBeforeEnd))) * 60
        }
    }

    static func triggerPositionSeconds(
        durationSeconds: Double,
        thresholdPercent: Int,
        segments: [SkipSegment],
        tailWindowSeconds: Double
    ) -> Double {
        guard durationSeconds > 0 else { return 0 }
        let fallback = (durationSeconds * Double(clampThreshold(thresholdPercent)) / 100).rounded(.up)

        let valid = segments.filter {
            $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.end > $0.start && $0.start < durationSeconds
        }
        let credits = valid.filter {
            isEndCredits($0, durationSeconds: durationSeconds) && $0.end <= durationSeconds + endOfVideoEpsilon
        }
        let firstCreditsStart = credits.map(\.start).min()
        let scenes = valid.filter { segment in
            guard segment.kind == .postCredits else { return false }
            guard let creditsStart = firstCreditsStart else { return true }
            return segment.start >= creditsStart
        }

        if let sceneEnd = scenes.map(\.end).max() {
            // Clamped: a submitted end can overrun this release, and a trigger past the runtime
            // would never fire at all.
            return min(sceneEnd, durationSeconds)
        }
        guard let creditsStart = firstCreditsStart,
              let creditsEnd = credits.map(\.end).max()
        else { return fallback }

        let tail = durationSeconds - creditsEnd
        guard tail > tailWindowSeconds else { return creditsStart }
        return max(durationSeconds - tailWindowSeconds, creditsEnd)
    }

    /// IntroDB reports film credits as `movieCredits`. Container chapters such as "End Credits"
    /// arrive as outros (`ChapterSkipSegments`), and those only count in the second half, so an
    /// opening "Credits" chapter is not taken for the end credits — upstream's `isMovieEndCredits`
    /// (1.2.0-beta.1). Without it a film whose only credits mark was a chapter fell back to the
    /// percentage.
    static func isEndCredits(_ segment: SkipSegment, durationSeconds: Double) -> Bool {
        switch segment.kind {
        case .movieCredits: return true
        case .outro: return segment.start >= durationSeconds / 2
        default: return false
        }
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
