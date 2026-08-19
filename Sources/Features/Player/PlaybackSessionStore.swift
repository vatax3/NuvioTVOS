import Foundation

/// Short-lived state that survives the transition Player → Streams → Player when auto-play
/// chains episodes. It is intentionally not persisted: an app relaunch is a new viewing session.
@MainActor
final class PlaybackSessionStore {
    static let shared = PlaybackSessionStore()

    private var pendingAutoAdvanceVideoId: String?
    private var consecutiveAutoAdvances = 0

    private init() {}

    func markAutoAdvance(to videoId: String) {
        pendingAutoAdvanceVideoId = videoId
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
    }
}
