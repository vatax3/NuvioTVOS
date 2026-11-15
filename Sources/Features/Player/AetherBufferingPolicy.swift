import Foundation

/// When AetherEngine's picture has really stopped for want of data.
///
/// `playbackPhase` is the one signal that tracks motion: `state` turns `.playing` the moment the
/// engine called `play()`, which on a slow start is seconds before the picture moves.
///
/// Except `.stalled`, which is about the source rather than the picture. It outranks `.rebuffering`
/// and is raised the moment the reader reconnects — while AVPlayer is still playing the tens of
/// seconds already produced ahead. Read as a stall, it put the spinner over a film that never
/// stopped, and reported `loading` to the host, whose recovery watchdog could then reload it. Only
/// the transport's own starvation says the picture has stopped.
///
/// The phase is restated here because the test bundle does not link the engine.
enum AetherBufferingPolicy {
    enum Phase: Equatable {
        case loading
        case rebuffering
        case sourceStalled
        case other
    }

    static func showsBuffering(_ phase: Phase, transportStarved: Bool) -> Bool {
        switch phase {
        case .loading, .rebuffering: return true
        case .sourceStalled: return transportStarved
        case .other: return false
        }
    }
}

#if canImport(PlayerEngineKit)
import PlayerEngineKit

extension AetherBufferingPolicy.Phase {
    init(_ phase: PlaybackPhase) {
        switch phase {
        case .loading: self = .loading
        case .rebuffering: self = .rebuffering
        case .stalled: self = .sourceStalled
        default: self = .other
        }
    }
}
#endif
