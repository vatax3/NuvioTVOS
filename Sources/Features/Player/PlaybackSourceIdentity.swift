import Foundation

/// The selection marker in a source picker must identify the exact stream, not merely the
/// provider-visible release label.  This is intentionally framework-free so it can be tested
/// without starting a player or a SwiftUI focus hierarchy.
enum PlaybackSourceIdentity {
    static func matches(_ stream: Stream, playback: PlaybackRequest) -> Bool {
        if let stableKey = playback.sourceStableKey?.nilIfBlank {
            return stream.stableKey == stableKey
        }
        return stream.displayName == playback.streamName
            && stream.addonName == playback.sourceAddonName
    }
}
