import Foundation

/// When a held wake lock should actually keep the television awake.
///
/// The lock is held for the whole presentation, and that is deliberate: releasing it whenever
/// playback is not running does not survive contact with a stream, because every buffer stall and
/// every track change passes through a non-playing state. Re-arming the idle timer on each of
/// those is what eventually sleeps the device mid-film.
///
/// But a viewer who presses Pause and walks away is not a buffer stall, and leaving the Apple TV
/// awake all night because a film is paused is the complaint this exists to answer. The two are
/// told apart by *how long* the pause lasts, not by the fact of it: a stall is seconds, a
/// deliberate pause is not.
enum PlaybackWakeLockPolicy {
    /// Comfortably longer than any stall or track change, and short enough that the television
    /// still sleeps in a reasonable time — the system's own Sleep After starts counting from
    /// here, and its shortest setting is fifteen minutes.
    static let pauseGrace: TimeInterval = 120

    struct State: Equatable {
        var holders: Int
        /// How long playback has been paused, or `nil` while it is running.
        var pausedFor: TimeInterval?
    }

    static func keepsAwake(_ state: State) -> Bool {
        guard state.holders > 0 else { return false }
        guard let pausedFor = state.pausedFor else { return true }
        return pausedFor < pauseGrace
    }

    /// Whether a pause that has just begun will eventually let the device sleep, so the caller
    /// knows to arm a timer rather than only re-checking on the next state change. Nothing else
    /// would wake the policy up: a paused player produces no events.
    static func needsGraceTimer(_ state: State) -> Bool {
        state.holders > 0 && state.pausedFor != nil && keepsAwake(state)
    }
}
