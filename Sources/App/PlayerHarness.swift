#if DEBUG
import Foundation

/// Test-only entry straight into playback.
///
/// The player's remote handling is the one part of the app that cannot be checked by reasoning
/// about a view: whether a press reaches the transport at all depends on where tvOS has put
/// focus, which only exists at runtime. This gives `NuvioTVOSUITests` a player to point a
/// remote at without an account, an addon or a stream list in front of it.
///
/// Compiled out of release builds entirely, and inert without the launch argument.
enum PlayerHarness {
    static let launchArgument = "-nuvioPlayerHarness"
    /// Set `NUVIO_HARNESS_STREAM` to play something real. The default is deliberately a route
    /// that never answers: focus behaviour is the subject, and a stream that neither fails nor
    /// arrives keeps the player in its ordinary playing state for the length of a test.
    static let streamVariable = "NUVIO_HARNESS_STREAM"
    private static let stallingStream = "http://10.255.255.1/harness.mp4"

    static func request() -> PlaybackRequest? {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return nil }
        let url = ProcessInfo.processInfo.environment[streamVariable]?.nilIfBlank ?? stallingStream
        return PlaybackRequest(
            streamURL: url,
            title: "Harness",
            subtitleLine: "S01E01 · Remote input",
            streamName: "harness",
            filename: "harness.mp4",
            headers: [:],
            contentId: "harness",
            contentType: "movie",
            videoId: "harness",
            season: nil,
            episode: nil,
            poster: nil,
            backdrop: nil,
            logo: nil,
            startFromBeginning: true,
            preview: nil
        )
    }
}
#endif
