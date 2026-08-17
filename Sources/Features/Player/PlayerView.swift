import SwiftUI
import AVKit
import AVFoundation
import Combine

/// Playback surface.
///
/// The Android app ships a bespoke overlay on top of ExoPlayer/libmpv. On tvOS the system
/// player is the better host: it owns the Siri Remote gestures, scrubbing preview, audio and
/// subtitle pickers, and Now Playing integration that users expect — reimplementing those in
/// SwiftUI would be strictly worse. Nuvio's own behaviour is layered on top: resume position,
/// progress persistence, custom metadata, and per-stream request headers.
struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let request: PlaybackRequest

    @State private var didScrobbleStart = false
    @State private var lastScrobbleProgress: Double = 0
    @State private var didSimklCheckin = false
    @State private var subtitles = SubtitleTrackController()

    /// MKV and friends have no AVFoundation demuxer, so those files are routed to MPV even when
    /// the viewer left the engine on Default — an unplayable file is worse than a slower decode.
    private var resolvedEngine: InternalPlayerEngine {
        guard MPVEngineSupport.isAvailable else { return .exoplayer }
        if settings.player.internalPlayerEngine == .mpv { return .mpv }
        return MPVEngineSupport.requiresMPV(url: request.streamURL) ? .mpv : .exoplayer
    }

    var body: some View {
        Group {
            if resolvedEngine == .mpv {
                mpvPlayer
            } else {
                avPlayer
            }
        }
        .ignoresSafeArea()
        .task { await loadSubtitles() }
    }

    @ViewBuilder
    private var mpvPlayer: some View {
        #if canImport(Libmpv)
        MPVPlayerView(
            request: request,
            resumeAt: resumePosition,
            verboseLogging: settings.player.verboseLoggingEnabled,
            subtitleStyle: settings.subtitleStyle,
            onProgress: { position, duration, completed in
                persist(position: position, duration: duration, completed: completed)
                scrobble(position: position, duration: duration)
                simklCheckin()
                advanceIfDue(position: position, duration: duration)
            },
            onFinished: {
                persist(position: 0, duration: 0, completed: true)
                scrobbleStop()
                advanceToNextEpisode()
                dismiss()
            }
        )
        #else
        avPlayer
        #endif
    }

    private var avPlayer: some View {
        ZStack {
            AVPlayerContainer(
                request: request,
                resumeAt: resumePosition,
                subtitleStyleRules: settings.subtitleStyle.textStyleRules,
                subtitleTracks: subtitles.available,
                selectedSubtitle: subtitles.selected,
                onSelectSubtitle: { subtitles.select($0) },
                onTick: { subtitles.currentTime = $0 },
                onProgress: { position, duration, completed in
                    persist(position: position, duration: duration, completed: completed)
                    scrobble(position: position, duration: duration)
                    simklCheckin()
                    advanceIfDue(position: position, duration: duration)
                },
                onFinished: {
                    persist(position: 0, duration: 0, completed: true)
                    scrobbleStop()
                    advanceToNextEpisode()
                    dismiss()
                }
            )

            SubtitleOverlay(cue: subtitles.activeCue, style: settings.subtitleStyle)
        }
    }

    // MARK: External subtitles

    /// Addon-supplied tracks. The picker lives in the transport bar; a preferred language is
    /// switched on straight away so the viewer does not have to open it every episode.
    private func loadSubtitles() async {
        let ordered = SubtitleSelector.order(
            request.subtitles,
            preferred: settings.player.subtitlePreferredLanguage,
            secondary: settings.player.subtitleSecondaryLanguage,
            onlyPreferred: settings.player.subtitleShowOnlyPreferredLanguages
        )
        subtitles.available = ordered

        if subtitles.selected == nil,
           let automatic = SubtitleSelector.autoSelection(
               ordered, preferred: settings.player.subtitlePreferredLanguage
           ) {
            subtitles.select(automatic)
        }
    }

    // MARK: Trakt

    private var traktCredentials: (clientId: String, token: String)? {
        let tracking = settings.tracking
        guard tracking.traktScrobbleEnabled, tracking.isTraktAuthenticated,
              !tracking.traktClientId.isEmpty else { return nil }
        return (tracking.traktClientId, tracking.traktAccessToken)
    }

    private func scrobble(position: Double, duration: Double) {
        guard let credentials = traktCredentials, let imdbId = request.imdbId,
              duration > 0 else { return }
        let percent = min(max(position / duration * 100, 0), 100)
        // One `start`, then periodic updates only when the needle has actually moved.
        let action: TraktClient.ScrobbleAction = didScrobbleStart ? .pause : .start
        guard !didScrobbleStart || percent - lastScrobbleProgress >= 5 else { return }
        didScrobbleStart = true
        lastScrobbleProgress = percent

        Task {
            await TraktClient.shared.scrobble(
                action: action, imdbId: imdbId, type: ContentType.from(request.contentType),
                season: request.season, episode: request.episode,
                progressPercent: percent,
                clientId: credentials.clientId, token: credentials.token
            )
        }
    }

    private func scrobbleStop() {
        guard let imdbId = request.imdbId else { return }
        if let credentials = traktCredentials {
            Task {
                await TraktClient.shared.scrobble(
                    action: .stop, imdbId: imdbId, type: ContentType.from(request.contentType),
                    season: request.season, episode: request.episode,
                    progressPercent: 100,
                    clientId: credentials.clientId, token: credentials.token
                )
            }
        }
        if let credentials = simklCredentials {
            Task {
                await SimklClient.shared.markWatched(
                    imdbId: imdbId, type: ContentType.from(request.contentType),
                    season: request.season, episode: request.episode,
                    clientId: credentials.clientId, token: credentials.token
                )
            }
        }
    }

    // MARK: Simkl

    private var simklCredentials: (clientId: String, token: String)? {
        let tracking = settings.tracking
        guard tracking.simklScrobbleEnabled, tracking.isSimklAuthenticated,
              !tracking.simklClientId.isEmpty else { return nil }
        return (tracking.simklClientId, tracking.simklAccessToken)
    }

    /// Simkl has no progress endpoint — one check-in at the start is the whole story until the
    /// history write on completion.
    private func simklCheckin() {
        guard didSimklCheckin == false, let credentials = simklCredentials,
              let imdbId = request.imdbId else { return }
        didSimklCheckin = true
        Task {
            await SimklClient.shared.checkin(
                imdbId: imdbId, type: ContentType.from(request.contentType),
                season: request.season, episode: request.episode,
                clientId: credentials.clientId, token: credentials.token
            )
        }
    }

    // MARK: Next episode

    /// Honours the percent / minutes-before-end threshold from Playback settings.
    private func advanceIfDue(position: Double, duration: Double) {
        guard settings.player.autoPlayNextEpisodeEnabled, request.nextUp != nil,
              settings.player.shouldAdvanceToNextEpisode(position: position, duration: duration)
        else { return }
        scrobbleStop()
        advanceToNextEpisode()
        dismiss()
    }

    private func advanceToNextEpisode() {
        guard settings.player.autoPlayNextEpisodeEnabled, let next = request.nextUp else { return }
        router.openStreams(next)
    }

    private var resumePosition: Double {
        guard !request.startFromBeginning,
              let progress = library.progress(forVideoId: request.videoId),
              !progress.isFinished(threshold: settings.watchedThreshold)
        else { return 0 }
        return progress.positionSeconds
    }

    private func persist(position: Double, duration: Double, completed: Bool) {
        guard duration > 0 || completed else { return }
        if completed {
            guard let existing = library.progress(forVideoId: request.videoId) else { return }
            library.markWatched(
                contentId: request.contentId,
                contentType: request.contentType,
                videoId: request.videoId,
                season: request.season,
                episode: request.episode,
                duration: existing.durationSeconds
            )
            return
        }
        library.record(
            contentId: request.contentId,
            contentType: request.contentType,
            videoId: request.videoId,
            season: request.season,
            episode: request.episode,
            position: position,
            duration: duration,
            preview: request.preview
        )
    }
}

// MARK: - AVPlayerViewController bridge

private struct AVPlayerContainer: UIViewControllerRepresentable {
    let request: PlaybackRequest
    let resumeAt: Double
    /// Applied to tracks the container itself carries; addon tracks are drawn by the overlay.
    let subtitleStyleRules: [AVTextStyleRule]
    let subtitleTracks: [Subtitle]
    let selectedSubtitle: Subtitle?
    let onSelectSubtitle: (Subtitle?) -> Void
    let onTick: (Double) -> Void
    let onProgress: (Double, Double, Bool) -> Void
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onFinished: onFinished, onTick: onTick)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false

        guard let url = URL(string: request.streamURL) else { return controller }

        // Addons hand back `behaviorHints.proxyHeaders.request` for sources that need auth
        // or a specific referer; AVURLAsset can only take those at construction time.
        let options: [String: Any] = request.headers.isEmpty
            ? [:]
            : ["AVURLAssetHTTPHeaderFieldsKey": request.headers]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = metadata()
        item.textStyleRules = subtitleStyleRules

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        controller.player = player

        context.coordinator.attach(player: player, item: item, resumeAt: resumeAt)
        configureAudioSession()
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player?.currentItem?.textStyleRules = subtitleStyleRules
        controller.transportBarCustomMenuItems = subtitleTracks.isEmpty ? [] : [subtitleMenu()]
    }

    /// tvOS has no API to add a track to the system subtitle picker, so addon tracks get their
    /// own transport-bar menu next to it.
    private func subtitleMenu() -> UIMenu {
        let off = UIAction(title: "Off", state: selectedSubtitle == nil ? .on : .off) { _ in
            onSelectSubtitle(nil)
        }

        let groups = SubtitleSelector.group(subtitleTracks, mode: .byLanguage)
        let children: [UIMenuElement] = groups.map { group in
            let actions = group.items.map { subtitle in
                UIAction(
                    title: subtitle.addonName ?? subtitle.displayLanguage,
                    state: subtitle.id == selectedSubtitle?.id ? .on : .off
                ) { _ in
                    onSelectSubtitle(subtitle)
                }
            }
            return UIMenu(title: group.title, options: .displayInline, children: actions)
        }

        return UIMenu(
            title: "Addon Subtitles",
            image: UIImage(systemName: "captions.bubble"),
            children: [off] + children
        )
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detach()
        controller.player?.pause()
        controller.player = nil
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Drives the tvOS Info panel and Now Playing screen.
    private func metadata() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func add(_ identifier: AVMetadataIdentifier, _ value: String?) {
            guard let value = value?.nilIfBlank else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            items.append(item)
        }

        add(.commonIdentifierTitle, request.title)
        add(.iTunesMetadataTrackSubTitle, request.subtitleLine)
        add(.commonIdentifierDescription, request.streamName)

        if let artworkURL = request.poster ?? request.backdrop,
           let url = URL(string: artworkURL),
           let data = try? Data(contentsOf: url) {
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .commonIdentifierArtwork
            artwork.value = data as NSData
            artwork.dataType = kCMMetadataBaseDataType_PNG as String
            items.append(artwork)
        }

        return items
    }

    final class Coordinator {
        private let onProgress: (Double, Double, Bool) -> Void
        private let onFinished: () -> Void
        private let onTick: (Double) -> Void
        private var timeObserver: Any?
        private var cueObserver: Any?
        private weak var player: AVPlayer?
        private var endObserver: NSObjectProtocol?

        init(
            onProgress: @escaping (Double, Double, Bool) -> Void,
            onFinished: @escaping () -> Void,
            onTick: @escaping (Double) -> Void
        ) {
            self.onProgress = onProgress
            self.onFinished = onFinished
            self.onTick = onTick
        }

        func attach(player: AVPlayer, item: AVPlayerItem, resumeAt: Double) {
            self.player = player

            if resumeAt > 1 {
                let target = CMTime(seconds: resumeAt, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }

            // Persist every 5s — often enough to survive a hard power-off, rare enough
            // to keep disk writes off the playback path.
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 5, preferredTimescale: 1),
                queue: .main
            ) { [weak self] time in
                guard let self, let duration = player.currentItem?.duration.seconds,
                      duration.isFinite, duration > 0 else { return }
                self.onProgress(time.seconds, duration, false)
            }

            // Cue changes need a much finer clock than the persistence tick — a quarter second
            // keeps subtitles in sync without the cost of a per-frame observer.
            cueObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                self?.onTick(time.seconds)
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.onFinished()
            }
        }

        func detach() {
            if let player {
                if let timeObserver { player.removeTimeObserver(timeObserver) }
                if let cueObserver { player.removeTimeObserver(cueObserver) }
            }
            timeObserver = nil
            cueObserver = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
        }

        deinit { detach() }
    }
}
