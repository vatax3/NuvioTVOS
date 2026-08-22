import Foundation

/// Short-lived state that survives the transition Player → Streams → Player when auto-play
/// chains episodes. It is intentionally not persisted: an app relaunch is a new viewing session.
@MainActor
final class PlaybackSessionStore {
    static let shared = PlaybackSessionStore()

    private var pendingAutoAdvanceVideoId: String?
    private var consecutiveAutoAdvances = 0
    /// The `bingeGroup` of the source that was playing when the chain started, so the next
    /// episode can be served by the same release instead of reopening the choice.
    private var pendingBingeGroup: String?

    private init() {}

    func markAutoAdvance(to videoId: String, bingeGroup: String? = nil) {
        pendingAutoAdvanceVideoId = videoId
        pendingBingeGroup = bingeGroup?.nilIfBlank
    }

    /// Read once, by the stream screen the chain lands on. Leaving it set would make a source
    /// picked by hand three episodes later look like part of the same automatic run.
    func consumeBingeGroup(for videoId: String) -> String? {
        guard pendingAutoAdvanceVideoId == videoId else { return nil }
        defer { pendingBingeGroup = nil }
        return pendingBingeGroup
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
        pendingBingeGroup = nil
    }
}
