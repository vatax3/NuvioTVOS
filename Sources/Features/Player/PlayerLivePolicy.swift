import Foundation

/// Whether what is playing is a live stream, which has no position worth coming back to.
///
/// Port of upstream's `LivePlaybackUiPolicy`. A resume point on a live channel seeks, next time,
/// past the end of a window that has long since moved; a scrobble reports a "film" whose length
/// is however much the player happened to have loaded. Both were written here for every live
/// stream played through mpv or AetherEngine. AVPlayer was spared only because its live items
/// report an indefinite duration, which the progress path already refuses.
enum PlayerLivePolicy {
    /// Growth past the first reading that marks a live stream. A VOD's duration settles by a
    /// little while the demuxer refines it; a live window grows by a segment every few seconds.
    static let growthThreshold: Double = 10

    /// Stremio's live catalogue type. Not `tv`, which in this app is a synonym for series.
    static func isLiveContentType(_ type: String) -> Bool {
        type.caseInsensitiveCompare("channel") == .orderedSame
    }

    /// mpv can seek inside the cache of a live HLS stream, so it calls it seekable. What gives it
    /// away is the duration: it is what has been loaded so far, and it keeps growing.
    struct DurationGrowth: Equatable {
        private(set) var firstDuration: Double = 0
        private(set) var grew = false

        mutating func observe(_ duration: Double) {
            guard duration.isFinite, duration > 0, !grew else { return }
            if firstDuration == 0 {
                firstDuration = duration
            } else if duration > firstDuration + PlayerLivePolicy.growthThreshold {
                grew = true
            }
        }
    }
}
