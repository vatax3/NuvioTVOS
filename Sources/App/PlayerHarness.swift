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

    /// Set `NUVIO_HARNESS_EPISODES` to stage a series and its episode list, so the in-player
    /// Episodes panel opens without an addon behind it.
    ///
    /// The panel is reachable no other way in a test: it fetches `meta` from installed addons, so
    /// on a machine with no network it shows its own "no addon can provide this" row and there are
    /// no episode rows to press. And pressing one is the whole question — whether a held Select on
    /// a row reaches a gesture recogniser or is swallowed by the focused `Button` is a focus-engine
    /// fact that exists only at runtime. It is the same question that left the poster dialog
    /// unreachable for thirteen releases.
    static var stagesEpisodes: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
            && ProcessInfo.processInfo.environment["NUVIO_HARNESS_EPISODES"]?.nilIfBlank != nil
    }

    /// Opens the Episodes panel as playback starts, when the episode list is staged.
    ///
    /// The subject of `InPlayerEpisodesUITests` is the held Select on a *row*; walking the
    /// transport to find the Episodes control is incidental to it, and doing that walk is exactly
    /// the fragile part — `hasFocus` on those buttons is an unreliable witness, and a counted
    /// walk races the transport's own five-second auto-hide. Same reasoning as the staged skip
    /// and up-next cards above: put the subject on screen and test the subject.
    static var opensEpisodesPanel: Bool { stagesEpisodes }

    /// Two seasons, so the season chips have something to switch between as well.
    static func episodesMeta() -> Meta? {
        guard stagesEpisodes else { return nil }
        var videos: [Video] = []
        for season: Int in 1...2 {
            for episode: Int in 1...3 {
                videos.append(Video(
                    id: "harness:\(season):\(episode)",
                    name: "Episode \(episode)",
                    released: "2020-01-0\(episode)T00:00:00.000Z",
                    season: season,
                    episode: episode,
                    overview: """
                        A description long enough to need more than the two lines the panel has \
                        room for, so the focus-driven reveal has something to reveal.
                        """
                ))
            }
        }
        return Meta(
            id: "harness", type: .series, rawType: "series", name: "Harness", videos: videos
        )
    }

    static func request() -> PlaybackRequest? {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return nil }
        let url = ProcessInfo.processInfo.environment[streamVariable]?.nilIfBlank ?? stallingStream
        let series = stagesEpisodes
        return PlaybackRequest(
            streamURL: url,
            title: "Harness",
            subtitleLine: "S01E01 · Remote input",
            streamName: "harness",
            filename: "harness.mp4",
            headers: [:],
            contentId: "harness",
            // A series only when the episode list is staged: the Episodes panel refuses a film,
            // and every other harness test wants the simpler shape.
            contentType: series ? "series" : "movie",
            videoId: series ? "harness:1:1" : "harness",
            season: series ? 1 : nil,
            episode: series ? 1 : nil,
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
