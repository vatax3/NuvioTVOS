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

    var body: some View {
        AVPlayerContainer(
            request: request,
            resumeAt: resumePosition,
            onProgress: { position, duration, completed in
                persist(position: position, duration: duration, completed: completed)
                scrobble(position: position, duration: duration)
                advanceIfDue(position: position, duration: duration)
            },
            onFinished: {
                persist(position: 0, duration: 0, completed: true)
                scrobbleStop()
                advanceToNextEpisode()
                dismiss()
            }
        )
        .ignoresSafeArea()
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
        guard let credentials = traktCredentials, let imdbId = request.imdbId else { return }
        Task {
            await TraktClient.shared.scrobble(
                action: .stop, imdbId: imdbId, type: ContentType.from(request.contentType),
                season: request.season, episode: request.episode,
                progressPercent: 100,
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
    let onProgress: (Double, Double, Bool) -> Void
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onFinished: onFinished)
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

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        controller.player = player

        context.coordinator.attach(player: player, item: item, resumeAt: resumeAt)
        configureAudioSession()
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

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
        private var timeObserver: Any?
        private weak var player: AVPlayer?
        private var endObserver: NSObjectProtocol?

        init(onProgress: @escaping (Double, Double, Bool) -> Void, onFinished: @escaping () -> Void) {
            self.onProgress = onProgress
            self.onFinished = onFinished
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

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.onFinished()
            }
        }

        func detach() {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
        }

        deinit { detach() }
    }
}
