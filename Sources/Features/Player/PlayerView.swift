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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let request: PlaybackRequest

    @State private var didScrobbleStart = false
    @State private var lastScrobbleProgress: Double = 0
    @State private var didSimklCheckin = false
    @State private var subtitles = SubtitleTrackController()
    /// AniSkip intervals are deliberately owned by the player rather than the detail screen:
    /// an episode can be started from Continue Watching, a deep link, or the stream picker.
    @State private var skipSegments: [SkipSegment] = []
    @State private var skipLookupKey: String?
    @State private var dismissedSkipSegments: Set<String> = []
    @State private var playbackPosition: Double = 0
    /// Both player backends consume this one-shot seek request and acknowledge it by clearing it.
    @State private var requestedSeek: Double?
    /// A one-shot pause command shared by AVPlayer and MPV. The still-watching prompt must
    /// freeze the episode; otherwise it can expire underneath the viewer while they decide.
    @State private var requestedPause: PlaybackTransportRequest?
    @State private var nextEpisodeCountdown: Int?
    @State private var didDeclineNextEpisode = false
    @State private var postPlayTask: Task<Void, Never>?
    @State private var isLoading = true
    /// The loading overlay covers the whole picture, so it belongs to the moment before the
    /// first frame and to nothing after it. Changing an audio or subtitle track makes mpv go
    /// briefly idle while it re-reads the stream; showing "Preparing stream" over that reads
    /// as the player having thrown the film away and started again.
    @State private var hasStartedPlayback = false
    /// The pause card is not simply "paused is true". Android raises it a few seconds after a
    /// deliberate pause and hides the transport underneath it, because the two draw the same
    /// title in almost the same place — shown together they read as one title rendered twice,
    /// a few pixels apart.
    @State private var showsPauseOverlay = false
    @State private var pauseOverlayTask: Task<Void, Never>?
    @State private var isPaused = false
    @State private var parentalWarnings: [ParentalWarning] = []
    @State private var showsParentalGuide = false
    @State private var parentalGuideTask: Task<Void, Never>?
    @State private var consecutiveAutoAdvances = 0
    @State private var showsStillWatchingPrompt = false
    @State private var handledStillWatchingPrompt = false
    /// AVPlayer's transport menu can request a source change.  Keep the picker above the player
    /// instead of navigating back to the Sources route, just like the Android/iOS side panel.
    @State private var showsSourcePanel = false

    /// When the audio route last changed under playback, and the observer that reports it.
    /// A pause that lands right after a route change was the route change's doing, not the
    /// viewer's — see `observePlaybackState`.
    @State private var routeChangedAt: Date?
    @State private var routeObserver: NSObjectProtocol?

    /// MKV and friends have no AVFoundation demuxer, so those files are routed to MPV even when
    /// the viewer left the engine on Default — an unplayable file is worse than a slower decode.
    private var resolvedEngine: InternalPlayerEngine {
        guard MPVEngineSupport.isAvailable else { return .exoplayer }
        // Android's in-player engine switch is a one-session override, not a settings change:
        // the viewer is fixing this file, not changing their default.
        if let engineOverride { return engineOverride }
        if settings.player.internalPlayerEngine == .mpv { return .mpv }
        // AVFoundation already refused this source once — see `avPlayer`'s `onFailed`.
        if didFallBackToMPV { return .mpv }
        return MPVEngineSupport.requiresMPV(
            url: request.streamURL, filename: request.filename ?? request.streamName
        ) ? .mpv : .exoplayer
    }

    /// Set when AVFoundation reports it cannot open the source. Port of Android's
    /// `auto_switch_internal_player_on_error`: a debrid link usually carries no extension, so
    /// container sniffing alone cannot tell an MKV from an MP4 and the refusal is the only
    /// reliable signal. Without this the viewer just gets AVPlayer's blank "no entry" screen.
    @State private var didFallBackToMPV = false
    /// Set by the in-player engine button, and cleared only by leaving playback.
    @State private var engineOverride: InternalPlayerEngine?
    /// AVFoundation's refusal, once there is nowhere left to hand the stream to.
    @State private var avPlaybackError: String?

    var body: some View {
        Group {
            if resolvedEngine == .mpv {
                mpvPlayer
            } else {
                avPlayer
            }
        }
        .ignoresSafeArea()
        .task {
            consecutiveAutoAdvances = PlaybackSessionStore.shared.consumeAutoAdvance(for: request.videoId)
            // Set before the track loads, so cues are never drawn unfiltered for a frame first.
            subtitles.stripsSDH = settings.subtitleStyle.stripsSDH
            await loadSubtitles()
            await loadParentalGuide()
        }
        // Changing the setting mid-film re-filters what is loaded rather than refetching it.
        .onChange(of: settings.subtitleStyle.stripsSDH) { _, strips in
            subtitles.stripsSDH = strips
        }
        // Held for the whole presentation. tvOS keeps itself awake for a system video
        // controller, but the MPV surface is a Metal layer it knows nothing about: without
        // this, Settings -> General -> Sleep After applies during a film exactly as it would to
        // a menu left on screen, and the television sleeps mid-episode.
        .onAppear {
            PlaybackWakeLock.acquire()
            routeObserver = PlaybackAudioSession.observeRouteChanges { routeChangedAt = Date() }
        }
        .onDisappear {
            if let routeObserver { PlaybackAudioSession.endObserving(routeObserver) }
            routeObserver = nil
            PlaybackWakeLock.release()
            postPlayTask?.cancel()
            parentalGuideTask?.cancel()
            pauseOverlayTask?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the background can clear the flag underneath us.
            if phase == .active { PlaybackWakeLock.reassert() }
        }
    }

    /// The layers the host draws over playback that hold focus themselves. The player has to
    /// know: while one is up it must not claim the remote back, or the viewer cannot reach the
    /// Skip button, and the countdown card cannot be answered.
    private var hasFocusableOverlay: Bool {
        activeSkipSegment != nil || nextEpisodeCountdown != nil
            || showsStillWatchingPrompt || showsSourcePanel
    }

    @ViewBuilder
    private var mpvPlayer: some View {
        #if canImport(Libmpv)
        ZStack {
            MPVPlayerView(
                request: request,
                resumeAt: resumePosition,
                verboseLogging: settings.player.verboseLoggingEnabled,
                hardwareDecoding: settings.player.mpvHardwareDecodeMode,
                audioOutput: settings.player.mpvAudioOutput,
                audioChannels: settings.player.audioOutputChannels,
                audioLanguages: settings.audioTrackLanguages,
                subtitleLanguages: settings.subtitleTrackLanguages,
                subtitleStyle: settings.subtitleStyle,
                seekTarget: requestedSeek,
                onSeekApplied: { requestedSeek = nil },
                pauseRequest: requestedPause,
                onPauseApplied: { requestedPause = nil },
                onChooseEpisode: request.contentType == "series" ? chooseEpisode : nil,
                onPlayNextEpisode: request.nextUp == nil ? nil : playNextEpisodeNow,
                onSwitchEngine: { engineOverride = .exoplayer },
                showsPauseOverlay: showsPauseOverlay,
                hasOpenPrompt: showsPauseOverlay || nextEpisodeCountdown != nil || showsStillWatchingPrompt,
                onDismissPrompt: dismissTransientPrompt,
                hasFocusableOverlay: hasFocusableOverlay,
                onPlaybackTime: observePlaybackTime,
                onPlaybackState: { paused, loading in
                    observePlaybackState(paused: paused, loading: loading)
                },
                onProgress: { position, duration, completed in
                    observePlaybackTime(position, duration)
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

            if let segment = activeSkipSegment {
                SkipSegmentButton(segment: segment, action: { skip(segment) })
                    .padding(.leading, NuvioTheme.layout.tvSafeHorizontal)
                    .padding(.bottom, dp(116))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
            }

            postPlayOverlay
            stillWatchingOverlay
            playerStatusOverlay

            if showsSourcePanel {
                InPlayerSourcesPanel(request: request) { showsSourcePanel = false }
            }
        }
        .animation(NuvioMotion.quickTween, value: activeSkipSegment?.id)
        #else
        avPlayer
        #endif
    }

    private var avPlayer: some View {
        ZStack {
            AVPlayerContainer(
                request: request,
                resumeAt: resumePosition,
                subtitleStyle: settings.subtitleStyle,
                subtitleTracks: subtitles.available,
                selectedSubtitle: subtitles.selected,
                onSelectSubtitle: { subtitles.select($0) },
                seekTarget: requestedSeek,
                onSeekApplied: { requestedSeek = nil },
                pauseRequest: requestedPause,
                onPauseApplied: { requestedPause = nil },
                onChooseSource: request.sourceRequest == nil ? nil : { showsSourcePanel = true },
                onSwitchEngine: MPVEngineSupport.isAvailable ? { engineOverride = .mpv } : nil,
                frameRateMatchingMode: settings.player.frameRateMatchingMode,
                audioLanguages: settings.audioTrackLanguages,
                onPlaybackState: { paused, loading in
                    observePlaybackState(paused: paused, loading: loading)
                },
                onTick: { position, duration in
                    subtitles.currentTime = position
                    observePlaybackTime(position, duration)
                },
                onProgress: { position, duration, completed in
                    observePlaybackTime(position, duration)
                    persist(position: position, duration: duration, completed: completed)
                    scrobble(position: position, duration: duration)
                    simklCheckin()
                    advanceIfDue(position: position, duration: duration)
                },
                onFailed: handleAVFoundationFailure,
                onFinished: {
                    persist(position: 0, duration: 0, completed: true)
                    scrobbleStop()
                    advanceToNextEpisode()
                    dismiss()
                }
            )

            SubtitleOverlay(cues: subtitles.activeCues, style: settings.subtitleStyle)

            if let segment = activeSkipSegment {
                SkipSegmentButton(segment: segment, action: { skip(segment) })
                    .padding(.leading, NuvioTheme.layout.tvSafeHorizontal)
                    // Clear AVPlayerViewController's transport bar while remaining reachable
                    // with the Siri Remote when the system controls are hidden.
                    .padding(.bottom, dp(116))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
            }

            postPlayOverlay
            stillWatchingOverlay
            playerStatusOverlay

            if let avPlaybackError {
                ErrorStateView(message: avPlaybackError) { retryOnMPV() }
                    .background(.black.opacity(0.85))
            }
        }
        .animation(NuvioMotion.quickTween, value: activeSkipSegment?.id)
    }

    /// Android's `auto_switch_internal_player_on_error`: a debrid link usually carries no
    /// extension, so container sniffing cannot tell an MKV from an MP4 and AVFoundation's
    /// refusal is the only reliable signal. The silent hand-off applies to a stream that landed
    /// here by that guess — when the viewer pressed the engine button themselves, switching back
    /// without a word would read as the button doing nothing, so the failure is named instead.
    private func handleAVFoundationFailure(_ reason: String?) {
        guard avPlaybackError == nil else { return }
        if MPVEngineSupport.isAvailable, settings.player.autoSwitchInternalPlayerOnError,
           !didFallBackToMPV, engineOverride == nil {
            didFallBackToMPV = true
            return
        }
        avPlaybackError = reason?.nilIfBlank ?? L10n.text("player.error_playback_failed")
    }

    private func retryOnMPV() {
        avPlaybackError = nil
        guard MPVEngineSupport.isAvailable else {
            dismiss()
            return
        }
        engineOverride = .mpv
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

    // MARK: - Intro / outro skipping

    private var activeSkipSegment: SkipSegment? {
        guard settings.player.skipIntroEnabled else { return nil }
        return skipSegments.first { segment in
            playbackPosition >= segment.start && playbackPosition < segment.end
                && !dismissedSkipSegments.contains(segment.id)
        }
    }

    @ViewBuilder
    private var playerStatusOverlay: some View {
        if isLoading, !hasStartedPlayback, settings.player.loadingOverlayEnabled {
            PlayerLoadingOverlay(request: request, showsDetail: settings.player.showPlayerLoadingStatus)
                .transition(.opacity)
        } else if showsPauseOverlay {
            PlayerPauseOverlay(request: request, showsClock: settings.player.osdClockEnabled)
                .transition(.opacity)
        }

        if showsParentalGuide {
            ParentalGuideOverlay(warnings: parentalWarnings)
                .transition(.opacity)
        }
    }

    private func observePlaybackState(paused: Bool, loading: Bool) {
        let wasPaused = isPaused
        isPaused = paused
        isLoading = loading
        if !loading {
            hasStartedPlayback = true
            showParentalGuideIfReady()
        }
        if paused != wasPaused { schedulePauseOverlay(paused: paused) }
        if paused, !wasPaused, isRouteChangePause { resumeAfterRouteChange() }
    }

    /// AirPods connecting or disconnecting deactivates the audio session, and the engine stops
    /// with it. On an Apple TV that is never the viewer asking to stop — the sound has simply
    /// moved back to the television — so playback is taken up again.
    ///
    /// The window is what keeps this off a deliberate pause: a route change stops playback
    /// within a frame or two of the notification, and nothing else does. A pause that arrives
    /// later than this is the viewer's, and is left alone.
    private var isRouteChangePause: Bool {
        guard let routeChangedAt else { return false }
        return Date().timeIntervalSince(routeChangedAt) < 2
    }

    private func resumeAfterRouteChange() {
        routeChangedAt = nil
        // Not while something is deliberately holding playback stopped and waiting on an answer.
        guard !showsStillWatchingPrompt, nextEpisodeCountdown == nil else { return }
        requestedPause = PlaybackTransportRequest(paused: false)
    }

    /// Android's five seconds: long enough that pausing to read a subtitle or answer the door
    /// never swaps the screen out from under the viewer, short enough to settle into the card
    /// when the pause is a real interruption.
    private func schedulePauseOverlay(paused: Bool) {
        pauseOverlayTask?.cancel()
        pauseOverlayTask = nil
        guard paused, settings.player.pauseOverlayEnabled, hasStartedPlayback else {
            withAnimation(NuvioMotion.quickTween) { showsPauseOverlay = false }
            return
        }
        pauseOverlayTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, isPaused,
                  nextEpisodeCountdown == nil, !showsStillWatchingPrompt
            else { return }
            withAnimation(NuvioMotion.quickTween) { showsPauseOverlay = true }
        }
    }

    private func dismissPauseOverlay() {
        pauseOverlayTask?.cancel()
        pauseOverlayTask = nil
        withAnimation(NuvioMotion.quickTween) { showsPauseOverlay = false }
    }

    private func loadParentalGuide() async {
        guard settings.player.parentalGuideEnabled, let imdbId = request.imdbId else { return }
        parentalWarnings = await ParentalGuideClient.shared.warnings(imdbId: imdbId)
        showParentalGuideIfReady()
    }

    private func showParentalGuideIfReady() {
        guard !isLoading, !showsParentalGuide, !parentalWarnings.isEmpty else { return }
        showsParentalGuide = true
        parentalGuideTask?.cancel()
        parentalGuideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            showsParentalGuide = false
        }
    }

    /// The fine-grained player clock also drives the skip button. Persisting progress on this
    /// cadence would be wasteful, but using only the five-second persistence tick makes a short
    /// recap interval impossible to catch.
    private func observePlaybackTime(_ position: Double, _ duration: Double) {
        playbackPosition = position
        if duration.isFinite, duration > 0 {
            loadSkipSegmentsIfNeeded(duration: duration)
        }
    }

    private func loadSkipSegmentsIfNeeded(duration: Double) {
        guard settings.player.skipIntroEnabled,
              request.episode != nil,
              duration > 0,
              skipLookupKey == nil
        else { return }

        let ids = [request.videoId, request.contentId, request.imdbId ?? ""]
        let directMAL = ids.lazy.compactMap(Self.malEpisode(from:)).first
        let key: String
        if let directMAL {
            key = "mal:\(directMAL.id):\(directMAL.episode)"
        } else if let imdbId = ids.lazy.first(where: { $0.hasPrefix("tt") }),
                  let episode = request.episode {
            key = "imdb:\(imdbId.split(separator: ":")[0]):\(episode)"
        } else {
            return
        }
        skipLookupKey = key

        let introDbUrl = settings.skipIntro.introDbApiUrl
        Task {
            // IntroDB first: it is the only provider that knows about ordinary series, and its
            // answer is keyed by the IMDb id directly rather than through an anime id mapping.
            if !introDbUrl.isEmpty,
               let imdbId = ids.lazy.first(where: { $0.hasPrefix("tt") }),
               let season = request.season, let episode = request.episode {
                let found = await SkipIntroClient.shared.introDbSegments(
                    baseURL: introDbUrl,
                    imdbId: String(imdbId.split(separator: ":")[0]),
                    season: season,
                    episode: episode
                )
                if !found.isEmpty {
                    guard skipLookupKey == key else { return }
                    skipSegments = found
                    return
                }
            }

            let segments: [SkipSegment]
            if let directMAL {
                segments = await SkipIntroClient.shared.segments(
                    malId: directMAL.id, episode: directMAL.episode, episodeLength: duration
                )
            } else if let imdbId = ids.lazy.first(where: { $0.hasPrefix("tt") }),
                      let episode = request.episode,
                      let malId = await SkipIntroClient.shared.malId(
                        imdbId: String(imdbId.split(separator: ":")[0]), tvdbId: nil
                      ) {
                segments = await SkipIntroClient.shared.segments(
                    malId: malId, episode: episode, episodeLength: duration
                )
            } else {
                segments = []
            }
            guard skipLookupKey == key else { return }
            skipSegments = segments
        }
    }

    private func skip(_ segment: SkipSegment) {
        dismissedSkipSegments.insert(segment.id)
        requestedSeek = segment.end
    }

    /// Android's in-player Episodes panel opens the stream picker for the selected episode.
    /// Keeping the same transition on tvOS means the current player is dismissed before the
    /// next source is resolved, avoiding two full-screen playback covers fighting for focus.
    private func chooseEpisode(_ episode: StreamRequest) {
        router.playback = nil
        router.openStreams(episode)
    }

    private static func malEpisode(from id: String) -> (id: Int, episode: Int)? {
        let parts = id.split(separator: ":")
        guard parts.count >= 3, parts[0].lowercased() == "mal",
              let malId = Int(parts[1]), let episode = Int(parts[2])
        else { return nil }
        return (malId, episode)
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
              !didDeclineNextEpisode, nextEpisodeCountdown == nil, !showsStillWatchingPrompt,
              settings.player.shouldAdvanceToNextEpisode(position: position, duration: duration)
        else { return }
        if settings.player.stillWatchingEnabled,
           consecutiveAutoAdvances >= settings.player.stillWatchingEpisodeThreshold,
           !handledStillWatchingPrompt {
            handledStillWatchingPrompt = true
            showsStillWatchingPrompt = true
            requestedPause = PlaybackTransportRequest(paused: true)
            return
        }
        beginPostPlayCountdown()
    }

    @ViewBuilder
    private var stillWatchingOverlay: some View {
        if showsStillWatchingPrompt {
            StillWatchingOverlay(
                continuePlayback: continueAfterStillWatchingPrompt,
                stopAutoPlay: stopAutoPlayAfterStillWatchingPrompt
            )
            .padding(.trailing, NuvioTheme.layout.tvSafeHorizontal)
            .padding(.bottom, dp(110))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
        }
    }

    private func continueAfterStillWatchingPrompt() {
        showsStillWatchingPrompt = false
        PlaybackSessionStore.shared.resetAutoAdvanceCount()
        consecutiveAutoAdvances = 0
        beginPostPlayCountdown()
    }

    private func stopAutoPlayAfterStillWatchingPrompt() {
        showsStillWatchingPrompt = false
        didDeclineNextEpisode = true
        PlaybackSessionStore.shared.resetAutoAdvanceCount()
    }

    @ViewBuilder
    private var postPlayOverlay: some View {
        if let countdown = nextEpisodeCountdown, let next = request.nextUp {
            PostPlayOverlay(
                next: next,
                countdown: countdown,
                continuePlayback: continueToNextEpisode,
                cancel: declineNextEpisode
            )
            .padding(.trailing, NuvioTheme.layout.tvSafeHorizontal)
            .padding(.bottom, dp(110))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
        }
    }

    private func beginPostPlayCountdown() {
        guard postPlayTask == nil else { return }
        nextEpisodeCountdown = 8
        postPlayTask = Task { @MainActor in
            for remaining in stride(from: 8, through: 1, by: -1) {
                nextEpisodeCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            continueToNextEpisode()
        }
    }

    /// Menu's first claim once the panels are closed, matching Android's chain: a prompt over
    /// the picture is dismissed before the transport is, and long before playback ends.
    private func dismissTransientPrompt() {
        if showsPauseOverlay {
            dismissPauseOverlay()
        } else if nextEpisodeCountdown != nil {
            declineNextEpisode()
        } else if showsStillWatchingPrompt {
            stopAutoPlayAfterStillWatchingPrompt()
        }
    }

    /// The transport's next-episode button: no countdown, no consent prompt — the viewer has
    /// already decided by pressing it.
    private func playNextEpisodeNow() {
        postPlayTask?.cancel()
        postPlayTask = nil
        nextEpisodeCountdown = nil
        didDeclineNextEpisode = false
        scrobbleStop()
        guard let next = request.nextUp else { return }
        PlaybackSessionStore.shared.markAutoAdvance(to: next.videoId)
        router.openStreams(next)
        dismiss()
    }

    private func continueToNextEpisode() {
        postPlayTask?.cancel()
        postPlayTask = nil
        nextEpisodeCountdown = nil
        scrobbleStop()
        advanceToNextEpisode()
        dismiss()
    }

    private func declineNextEpisode() {
        postPlayTask?.cancel()
        postPlayTask = nil
        nextEpisodeCountdown = nil
        didDeclineNextEpisode = true
    }

    private func advanceToNextEpisode() {
        guard settings.player.autoPlayNextEpisodeEnabled, !didDeclineNextEpisode,
              let next = request.nextUp else { return }
        PlaybackSessionStore.shared.markAutoAdvance(to: next.videoId)
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
    let subtitleStyle: SubtitleStyle
    let subtitleTracks: [Subtitle]
    let selectedSubtitle: Subtitle?
    let onSelectSubtitle: (Subtitle?) -> Void
    let seekTarget: Double?
    let onSeekApplied: () -> Void
    let pauseRequest: PlaybackTransportRequest?
    let onPauseApplied: () -> Void
    let onChooseSource: (() -> Void)?
    /// Mirrors the MPV transport's engine button so the switch works in both directions.
    let onSwitchEngine: (() -> Void)?
    let frameRateMatchingMode: FrameRateMatchingMode
    let audioLanguages: [String]
    let onPlaybackState: (Bool, Bool) -> Void
    let onTick: (Double, Double) -> Void
    let onProgress: (Double, Double, Bool) -> Void
    /// Called when AVFoundation cannot open the source, with its own account of why, so the
    /// caller can hand the stream to MPV or — when the viewer chose this engine deliberately —
    /// say what happened instead of leaving a black screen.
    let onFailed: (String?) -> Void
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onProgress: onProgress, onFinished: onFinished, onTick: onTick, onFailed: onFailed,
            onPlaybackState: onPlaybackState
        )
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false
        // The system player will match the panel to the asset, but only when asked — the
        // property defaults to off.  AVKit restores the previous mode itself when full-screen
        // playback ends, so `start` and `startStop` behave alike on this engine.
        controller.appliesPreferredDisplayCriteriaAutomatically = frameRateMatchingMode != .off

        guard let url = Self.playbackURL(request.streamURL) else {
            // AVFoundation needs a parsed `URL`; MPV takes the string as it stands, which is
            // why a link the addon has not escaped plays on one engine and shows a black
            // screen with no message on the other.
            Task { @MainActor in onFailed(L10n.text("player.error_unplayable_url")) }
            return controller
        }

        // Addons hand back `behaviorHints.proxyHeaders.request` for sources that need auth
        // or a specific referer; AVURLAsset can only take those at construction time.
        let options: [String: Any] = request.headers.isEmpty
            ? [:]
            : ["AVURLAssetHTTPHeaderFieldsKey": request.headers]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = metadata()
        loadArtwork(into: item)
        item.textStyleRules = subtitleStyle.textStyleRules

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        // The same preference the MPV engine gets through `alang`/`slang`. AVFoundation takes it
        // as selection criteria and applies it to every item, including the next episode.
        if !audioLanguages.isEmpty {
            player.setMediaSelectionCriteria(
                AVPlayerMediaSelectionCriteria(preferredLanguages: audioLanguages, preferredMediaCharacteristics: nil),
                forMediaCharacteristic: .audible
            )
        }
        controller.player = player

        context.coordinator.appliedSubtitleStyle = subtitleStyle
        context.coordinator.attach(player: player, item: item, resumeAt: resumeAt)
        PlaybackAudioSession.activateMoviePlayback()
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if context.coordinator.appliedSubtitleStyle != subtitleStyle {
            controller.player?.currentItem?.textStyleRules = subtitleStyle.textStyleRules
            context.coordinator.appliedSubtitleStyle = subtitleStyle
        }

        let menuSignature = subtitleTracks.map(\.id).joined(separator: "|")
            + "#\(selectedSubtitle?.id ?? "off")#\(onChooseSource != nil)#\(onSwitchEngine != nil)"
        if context.coordinator.appliedMenuSignature != menuSignature {
            var menuItems: [UIMenuElement] = []
            if !subtitleTracks.isEmpty { menuItems.append(subtitleMenu()) }
            if let onChooseSource {
                menuItems.append(UIAction(
                    title: L10n.text("player.sources"), image: UIImage(systemName: "list.bullet")
                ) { _ in onChooseSource() })
            }
            if let onSwitchEngine {
                menuItems.append(UIAction(
                    title: L10n.text("player.switch_engine"),
                    image: UIImage(systemName: "arrow.triangle.2.circlepath")
                ) { _ in onSwitchEngine() })
            }
            controller.transportBarCustomMenuItems = menuItems
            context.coordinator.appliedMenuSignature = menuSignature
        }
        if let seekTarget, context.coordinator.applySeek(seekTarget) {
            onSeekApplied()
        }
        if let pauseRequest, context.coordinator.applyPause(pauseRequest) {
            onPauseApplied()
        }
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

    /// Addons hand back links they have not always escaped — a space or a bracket in a
    /// filename is enough — and `URL(string:)` refuses those outright. Escaping what is left
    /// after the first attempt recovers the common case without touching links that were
    /// already valid.
    static func playbackURL(_ string: String) -> URL? {
        if let url = URL(string: string) { return url }
        return string
            .addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
            .flatMap(URL.init(string:))
    }

    /// Artwork used to be fetched with `Data(contentsOf:)` while the view was being built: a
    /// synchronous download on the main thread, holding the whole interface — and the start of
    /// playback — for as long as the poster host took to answer.
    private func loadArtwork(into item: AVPlayerItem) {
        guard let artworkURL = (request.poster ?? request.backdrop).flatMap(URL.init(string:))
        else { return }
        // Awaited from the main actor rather than handed to a detached task: the request
        // suspends instead of blocking, and the player item is only ever touched here.
        Task { @MainActor in
            guard let (data, _) = try? await URLSession.shared.data(from: artworkURL),
                  !data.isEmpty else { return }
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .commonIdentifierArtwork
            artwork.value = data as NSData
            artwork.dataType = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
                ? kCMMetadataBaseDataType_PNG as String
                : kCMMetadataBaseDataType_JPEG as String
            item.externalMetadata += [artwork]
        }
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

        return items
    }

    final class Coordinator {
        private let onProgress: (Double, Double, Bool) -> Void
        private let onFinished: () -> Void
        private let onTick: (Double, Double) -> Void
        private let onFailed: (String?) -> Void
        private let onPlaybackState: (Bool, Bool) -> Void
        private var statusObserver: NSKeyValueObservation?
        private var timeObserver: Any?
        private var cueObserver: Any?
        private weak var player: AVPlayer?
        private var endObserver: NSObjectProtocol?
        private var failureObserver: NSObjectProtocol?
        private var timeControlObserver: NSKeyValueObservation?
        private var lastPauseRequest: PlaybackTransportRequest?
        var appliedSubtitleStyle: SubtitleStyle?
        var appliedMenuSignature: String?

        init(
            onProgress: @escaping (Double, Double, Bool) -> Void,
            onFinished: @escaping () -> Void,
            onTick: @escaping (Double, Double) -> Void,
            onFailed: @escaping (String?) -> Void,
            onPlaybackState: @escaping (Bool, Bool) -> Void
        ) {
            self.onProgress = onProgress
            self.onFinished = onFinished
            self.onTick = onTick
            self.onFailed = onFailed
            self.onPlaybackState = onPlaybackState
        }

        func attach(player: AVPlayer, item: AVPlayerItem, resumeAt: Double) {
            self.player = player

            // A container AVFoundation has no demuxer for fails here rather than at
            // construction, so this is the only place the refusal can be caught.
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let reason = (item.error as NSError?)?.localizedDescription
                Task { @MainActor in self?.onFailed(reason) }
            }

            // A container that opens and then stops part-way through never reaches `.failed`;
            // this is the only notice of it, and without it the picture simply freezes.
            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                self?.onFailed(error?.localizedDescription)
            }
            timeControlObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let state: (paused: Bool, loading: Bool)
                switch player.timeControlStatus {
                case .playing: state = (false, false)
                case .waitingToPlayAtSpecifiedRate: state = (false, true)
                case .paused: state = (true, false)
                @unknown default: state = (false, false)
                }
                Task { @MainActor in self?.onPlaybackState(state.paused, state.loading) }
            }

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
                let duration = self?.player?.currentItem?.duration.seconds ?? 0
                self?.onTick(time.seconds, duration)
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.onFinished()
            }
        }

        /// Returns false for the duplicate SwiftUI update emitted while the seek is in flight.
        func applySeek(_ seconds: Double) -> Bool {
            guard seconds.isFinite, seconds >= 0 else { return false }
            player?.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            return player != nil
        }

        func applyPause(_ request: PlaybackTransportRequest) -> Bool {
            guard lastPauseRequest != request else { return false }
            lastPauseRequest = request
            if request.paused { player?.pause() } else { player?.play() }
            return player != nil
        }

        func detach() {
            if let player {
                if let timeObserver { player.removeTimeObserver(timeObserver) }
                if let cueObserver { player.removeTimeObserver(cueObserver) }
            }
            timeObserver = nil
            cueObserver = nil
            statusObserver?.invalidate()
            statusObserver = nil
            timeControlObserver?.invalidate()
            timeControlObserver = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
            if let failureObserver {
                NotificationCenter.default.removeObserver(failureObserver)
            }
            failureObserver = nil
        }

        deinit { detach() }
    }
}
