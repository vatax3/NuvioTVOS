import Foundation

/// Short-lived state that survives the transition Player → Streams → Player when auto-play
/// chains episodes. It is intentionally not persisted: an app relaunch is a new viewing session.
@MainActor
final class PlaybackSessionStore {
    static let shared = PlaybackSessionStore()

    private var pendingAutoAdvanceVideoId: String?
    private var consecutiveAutoAdvances = 0
    /// The source that was playing when the chain started, so the next episode can be served by
    /// the same release instead of reopening the choice. The filename is carried beside the
    /// `bingeGroup` because most addons publish no `bingeGroup` and nearly all of them do name
    /// their files — see `NextEpisodeSourceMatch`.
    private var pendingRelease: NextEpisodeSourceMatch.Release?

    private init() {}

    func markAutoAdvance(to videoId: String, release: NextEpisodeSourceMatch.Release? = nil) {
        pendingAutoAdvanceVideoId = videoId
        pendingRelease = release.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Read once, by the stream screen the chain lands on. Leaving it set would make a source
    /// picked by hand three episodes later look like part of the same automatic run.
    func consumeRelease(for videoId: String) -> NextEpisodeSourceMatch.Release? {
        guard pendingAutoAdvanceVideoId == videoId else { return nil }
        defer { pendingRelease = nil }
        return pendingRelease
    }

    func consumeAutoAdvance(for videoId: String) -> Int {
        defer { pendingAutoAdvanceVideoId = nil }
        guard pendingAutoAdvanceVideoId == videoId else {
            consecutiveAutoAdvances = 0
            return 0
        }
        consecutiveAutoAdvances += 1
        return consecutiveAutoAdvances
    }

    func resetAutoAdvanceCount() {
        consecutiveAutoAdvances = 0
        pendingAutoAdvanceVideoId = nil
        pendingRelease = nil
    }
}
