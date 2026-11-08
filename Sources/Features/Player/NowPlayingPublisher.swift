import MediaPlayer
import UIKit
import os

/// The system Now Playing card and the remote commands behind it, for the engines whose picture
/// AVKit does not host.
///
/// Port of upstream's player `MediaSession` (`PlayerMediaSessionMetadata.kt`,
/// `MpvMediaSessionPlayer.kt`). Before this, AetherEngine was told it owned the session
/// (`AetherEngineAdapter.start`) and nothing ever filled it, and mpv published nothing: the card
/// was empty and the iPhone Remote, Control Center and Bluetooth controllers did nothing.
///
/// Two places to publish to. AetherEngine's native path owns an `MPNowPlayingSession` that merges
/// elapsed time, rate and duration from its own player, so only identity and commands go there.
/// mpv, and AetherEngine's software path, have no session: they use the shared centres, and this
/// writes the clock itself whenever it jumps. AVPlayer is not served here — `AVPlayerViewController`
/// publishes its own card, and a second session would fight it.
@MainActor
final class NowPlayingPublisher {
    /// Which commands are offered. Upstream's rule: nothing that seeks on a live stream.
    struct Commands: Equatable {
        var playPause: Bool
        var seek: Bool
        var nextEpisode: Bool

        nonisolated static func policy(isLive: Bool, hasNextEpisode: Bool) -> Commands {
            Commands(playPause: true, seek: !isLive, nextEpisode: hasNextEpisode)
        }
    }

    /// The step the transport uses for left and right, offered to the remote as the same skip.
    static let skipInterval: Double = 10

    /// Title and subtitle line as upstream builds them: the show or film, then "S01E01 · Episode"
    /// (`subtitleLine` already carries that). **No asset URL, no stream name and no media id**:
    /// upstream keeps stream URLs out of the session, and an id here would be one more place one
    /// could leak.
    nonisolated static func identity(title: String, subtitleLine: String?, isLive: Bool) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: isLive
        ]
        if let line = subtitleLine?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
            info[MPMediaItemPropertyArtist] = line
        }
        return info
    }

    private static let log = Logger(subsystem: "com.nuvio.tvos", category: "NowPlaying")

    private var commandCenter: MPRemoteCommandCenter?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var usesSharedCentres = false
    private var identity: [String: Any] = [:]
    private var artworkTask: Task<Void, Never>?
    private var stageIdentity: (([String: Any]) -> Void)?

    /// Publishes for this engine and request, or moves to the engine's own session once it exists.
    func bind<Engine: PlayerEngineSurface>(
        engine: Engine, request: PlaybackRequest, onNextEpisode: (() -> Void)?
    ) {
        let session = engine.nowPlayingSession
        // Already bound where it belongs: a session, or the shared centres while there is none.
        if commandCenter != nil, (session == nil) == usesSharedCentres { return }
        unbind()

        identity = Self.identity(title: request.title, subtitleLine: request.subtitleLine, isLive: engine.isLive)
        if let session {
            usesSharedCentres = false
            commandCenter = session.remoteCommandCenter
            stageIdentity = { [weak engine] info in engine?.stageNowPlayingIdentity(info) }
        } else {
            usesSharedCentres = true
            commandCenter = MPRemoteCommandCenter.shared()
            stageIdentity = nil
        }
        publish(engine: engine)
        register(engine: engine, onNextEpisode: onNextEpisode)
        Self.log.info("bound to \(session == nil ? "shared centres" : "engine session", privacy: .public); commands: \(self.targets.count, privacy: .public)")
        loadArtwork(for: request, engine: engine)
    }

    /// The clock, for the shared centres only: the system extrapolates from elapsed time and rate,
    /// so this is called when either jumps (pause, seek, speed), not on every tick.
    func update<Engine: PlayerEngineSurface>(engine: Engine) {
        guard usesSharedCentres else { return }
        publish(engine: engine)
    }

    func unbind() {
        artworkTask?.cancel()
        artworkTask = nil
        for (command, token) in targets {
            command.removeTarget(token)
            command.isEnabled = false
        }
        targets = []
        if usesSharedCentres {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        commandCenter = nil
        usesSharedCentres = false
        stageIdentity = nil
    }

    // MARK: Publishing

    private func publish<Engine: PlayerEngineSurface>(engine: Engine) {
        if let stageIdentity {
            stageIdentity(identity)
            return
        }
        var info = identity
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.position
        if engine.duration > 0, !engine.isLive {
            info[MPMediaItemPropertyPlaybackDuration] = engine.duration
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.isPaused ? 0.0 : engine.playbackSpeed
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Poster, else backdrop, as upstream. Decoded before it is wrapped: AetherEngine asks for an
    /// artwork that is already decoded and safe to hand across threads.
    private func loadArtwork<Engine: PlayerEngineSurface>(for request: PlaybackRequest, engine: Engine) {
        guard let raw = request.poster?.nilIfBlank ?? request.backdrop?.nilIfBlank,
              let url = URL(string: raw) else { return }
        artworkTask = Task { [weak self, weak engine] in
            guard let image = await ImageLoader.shared.image(for: url),
                  let decoded = await image.byPreparingForDisplay(),
                  !Task.isCancelled, let self, let engine else { return }
            let artwork = MPMediaItemArtwork(boundsSize: decoded.size) { _ in decoded }
            self.identity[MPMediaItemPropertyArtwork] = artwork
            self.publish(engine: engine)
            Self.log.info("artwork published")
        }
    }

    // MARK: Commands

    private func register<Engine: PlayerEngineSurface>(engine: Engine, onNextEpisode: (() -> Void)?) {
        guard let center = commandCenter else { return }
        let policy = Commands.policy(isLive: engine.isLive, hasNextEpisode: onNextEpisode != nil)

        // Straight to the engine, not through a watch party's correction wrapper: a press on the
        // remote is the viewer's own action, and the party publishes it (or refuses it for a
        // guest without control) by the same paths as a press in the transport.
        func add(_ command: MPRemoteCommand, enabled: Bool, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Bool) {
            command.isEnabled = enabled
            guard enabled else { return }
            let token = command.addTarget { event in
                MainActor.assumeIsolated { action(event) } ? .success : .commandFailed
            }
            targets.append((command, token))
        }

        add(center.playCommand, enabled: policy.playPause) { [weak engine] _ in
            engine?.setPaused(false); return engine != nil
        }
        add(center.pauseCommand, enabled: policy.playPause) { [weak engine] _ in
            engine?.setPaused(true); return engine != nil
        }
        add(center.togglePlayPauseCommand, enabled: policy.playPause) { [weak engine] _ in
            engine?.togglePause(); return engine != nil
        }
        add(center.changePlaybackPositionCommand, enabled: policy.seek) { [weak engine] event in
            guard let engine, let event = event as? MPChangePlaybackPositionCommandEvent else { return false }
            engine.seek(to: event.positionTime)
            return true
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        add(center.skipForwardCommand, enabled: policy.seek) { [weak engine] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            engine?.seek(by: interval); return engine != nil
        }
        add(center.skipBackwardCommand, enabled: policy.seek) { [weak engine] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            engine?.seek(by: -interval); return engine != nil
        }
        add(center.nextTrackCommand, enabled: policy.nextEpisode) { _ in
            onNextEpisode?(); return onNextEpisode != nil
        }
    }
}
