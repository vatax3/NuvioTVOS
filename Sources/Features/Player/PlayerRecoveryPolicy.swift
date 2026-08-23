import Foundation

/// A single recovery budget for startup and sustained stalls. It deliberately never retries
/// while a chooser or prompt owns the screen, nor while the viewer paused playback.
enum PlayerRecoveryPolicy {
    static let firstFrameTimeout: TimeInterval = 25
    static let stallTimeout: TimeInterval = 30
    static let automaticAttemptLimit = 1

    struct State: Equatable {
        var isLoading: Bool
        var hasStartedPlayback: Bool
        var isPaused: Bool
        var panelOpen: Bool
        var promptOpen: Bool
        var automaticAttempts: Int
    }

    static func timeout(for state: State) -> TimeInterval? {
        guard state.isLoading,
              !state.isPaused,
              !state.panelOpen,
              !state.promptOpen,
              state.automaticAttempts < automaticAttemptLimit
        else { return nil }
        return state.hasStartedPlayback ? stallTimeout : firstFrameTimeout
    }
}
