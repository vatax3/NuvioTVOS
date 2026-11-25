import Foundation

/// Where Simkl counts a playback as watched — upstream's `SimklRewatchMode.kt` and
/// `PlayerContentEndPolicy.kt` (1.2.0-beta.4), the completion half.
///
/// The viewer picks a threshold from 80% (Simkl's own bar: it marks a title watched there, so the
/// slider cannot start lower) to 100%. It rides on every scrobble call as `min_progress`, so the
/// account and this device judge a stop by the same number. An IntroDB credits marker, read five
/// seconds early, takes its place when there is one: a playback that reached the credits has
/// finished, whatever the viewer's floor.
enum SimklCompletion {
    /// `SIMKL_REWATCH_MIN_PROGRESS_PERCENT`.
    static let simklBarPercent: Double = 80
    static let thresholdRange = 80...100
    static let defaultThresholdPercent = 80
    /// What Simkl accepts for `min_progress`; it floors and clamps to this itself.
    static let minProgressRange = 50...100
    /// `CONTENT_END_TOLERANCE_SECONDS`: a fixed margin, not a share of the runtime.
    static let contentEndToleranceSeconds: Double = 5

    static func coercedThreshold(_ percent: Int) -> Int {
        min(thresholdRange.upperBound, max(thresholdRange.lowerBound, percent))
    }

    /// `resolvedSimklCompletionPercent`: the marker when there is one at or above Simkl's bar,
    /// the viewer's threshold otherwise.
    static func resolvedPercent(userThreshold: Double, contentEnd: Double?) -> Double {
        let user = userThreshold.isFinite ? max(userThreshold, simklBarPercent) : simklBarPercent
        guard let marker = contentEnd, marker.isFinite, marker >= simklBarPercent else { return user }
        return marker
    }

    /// `simklMinProgressPercent`: floored and clamped once, then used both in the query and here.
    static func minProgress(_ percent: Double) -> Int {
        guard percent.isFinite else { return Int(simklBarPercent) }
        return min(minProgressRange.upperBound, max(minProgressRange.lowerBound, Int(percent)))
    }

    /// `simklCompletionThresholdPercent`.
    static func thresholdPercent(userThreshold: Int, contentEnd: Double?) -> Double {
        Double(minProgress(resolvedPercent(userThreshold: Double(userThreshold), contentEnd: contentEnd)))
    }

    /// `contentEndPercent` with `contentEndWithTolerance`: the earliest outro or film-credits
    /// marker, as a percentage of the duration, read five seconds early. Nil when there is none or
    /// it makes no sense, so the viewer's threshold decides.
    static func contentEndPercent(segments: [SkipSegment], duration: Double) -> Double? {
        guard duration > 0 else { return nil }
        guard let start = segments.filter({ $0.kind == .outro || $0.kind == .movieCredits }).map(\.start).min(),
              start.isFinite, start > 0, start < duration
        else { return nil }
        let percent = start / duration * 100
        return max(0, percent - contentEndToleranceSeconds / duration * 100)
    }

    /// `localCompletionThresholdFor`: while Simkl is the progress source, a row this device saves
    /// is finished where Simkl would count it. It only ever raises the bar.
    static func localThreshold(base: Double, simklPercent: Double?) -> Double {
        guard let simklPercent, simklPercent.isFinite else { return base }
        return max(base, min(1, simklPercent / 100))
    }
}
