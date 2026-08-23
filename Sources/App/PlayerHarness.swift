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

    /// Set `NUVIO_HARNESS_SKIP` to stage the skip card over the harness stream.
    ///
    /// The cards drawn over playback are reachable no other way: they need a real interval from
    /// AniSkip or IntroDB, an episode to look one up for, and a stream that actually decodes.
    /// Their focus treatment is the part that gets reported — the platform lays its own plate
    /// over a `Button` regardless of what the view asked for — and that is a question only a
    /// screenshot answers.
    static func skipSegments() -> [SkipSegment]? {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument),
              ProcessInfo.processInfo.environment["NUVIO_HARNESS_SKIP"]?.nilIfBlank != nil
        else { return nil }
        return [SkipSegment(kind: .intro, start: 0, end: 90)]
    }

    /// Set `NUVIO_HARNESS_UPNEXT` to stage the end-of-episode card. Same reason as the skip
    /// card above: it is otherwise reachable only from the last seconds of a real episode that
    /// has a real next one.
    static var stagesUpNext: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
            && ProcessInfo.processInfo.environment["NUVIO_HARNESS_UPNEXT"]?.nilIfBlank != nil
    }

    static func nextUp() -> StreamRequest {
        StreamRequest(
            videoId: "harness:1:2",
            contentType: "series",
            title: "Harness",
            contentId: "harness",
            season: 1,
            episode: 2,
            episodeName: "The one after this one"
        )
    }

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
            preview: nil,
            nextUp: stagesUpNext ? nextUp() : nil
        )
    }
}
#endif
