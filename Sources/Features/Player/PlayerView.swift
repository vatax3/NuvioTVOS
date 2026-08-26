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
    @State private var simklSessionActive = false
    @State private var didSendTrackingStop = false
    @State private var subtitles = SubtitleTrackController()
    /// AniSkip intervals are deliberately owned by the player rather than the detail screen:
    /// an episode can be started from Continue Watching, a deep link, or the stream picker.
    @State private var skipSegments: [SkipSegment] = []
    @State private var skipLookupKey: String?
    @State private var dismissedSkipSegments: Set<String> = []
    @State private var playbackPosition: Double = 0
    @State private var playbackDuration: Double = 0
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
    /// briefly idle while it re-reads the stream; showing L10n.text("player.preparing", fallback: "Preparing stream") over that reads
    /// as the player having thrown the film away and started again.
    @State private var hasStartedPlayback = false
    /// The pause card is not simply "paused is true". Android raises it a few seconds after a
    /// deliberate pause and hides the transport underneath it, because the two draw the same
    /// title in almost the same place — shown together they read as one title rendered twice,
    /// a few pixels apart.
    @State private var showsPauseOverlay = false
    @State private var pauseOverlayTask: Task<Void, Never>?
    @State private var isPaused = false
    /// What the engine underneath is drawing: its transport, and whether a panel is over the
    /// picture. Both host cards are placed against it — see `PlayerChromeState`.
    @State private var engineChrome = PlayerChromeState()
    /// The skip card's countdown has run out for the current segment. Reset when the segment
    /// changes; see `SkipSegmentVisibility`.
    @State private var skipAutoHidden = false
    /// Consecutive seeks driven from the skip card, and when the last one landed — the same
    /// reconstruction of Android's repeat count the transport's own scrubber does.
    @State private var skipCardSeekCount = 0
    @State private var skipCardSeekAt: Date = .distantPast
    @State private var skipCardSeekTarget: Double?
    /// Bumped when the skip card hands the remote back on a Up/Down press, so the transport
    /// comes up where the card was rather than leaving the viewer on bare picture.
    @State private var revealControlsRequest = 0
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
    /// Recreating only the MPV subtree gives a failed demuxer/decoder one clean retry while the
    /// full-screen player, its source request and its navigation context remain mounted.
    @State private var mpvSessionGeneration = 0
    @State private var automaticRecoveryAttempts = 0
    /// A recovery remount must resume from the live playhead, not the older library checkpoint.
    /// `requestedSeek` alone is too early for a newly-created MPV handle and can be consumed
    /// before `loadfile` completes.
    @State private var recoveryResumePosition: Double?

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
            #if DEBUG
            if let staged = PlayerHarness.skipSegments() { skipSegments = staged }
            // Straight into the real state rather than a parallel branch, so what a screenshot
            // shows is the card the viewer gets — focus handling included, which is the part
            // that only exists at runtime.
            if PlayerHarness.stagesUpNext { nextEpisodeCountdown = 5 }
            #endif
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
            scrobbleStop()
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
        // Ten seconds of the card being the only thing on screen, then it steps aside — Android's
        // `SKIP_INTRO_AUTO_HIDE_TIMEOUT_MS`. The countdown is bound to a state that stops running
        // whenever the transport is up, so time spent reading the controls never counts against
        // it, and on the MPV engine a pause does not quietly burn it down (pausing raises the
        // transport there and nothing lowers it again).
        .task(id: skipCountdownKey) {
            guard SkipSegmentVisibility.runsAutoHideCountdown(skipVisibility) else { return }
            try? await Task.sleep(for: .seconds(SkipSegmentVisibility.autoHideTimeout))
            guard !Task.isCancelled else { return }
            skipAutoHidden = true
        }
        .task(id: recoveryWatchdogKey) {
            let state = recoveryState
            guard let timeout = PlayerRecoveryPolicy.timeout(for: state) else { return }
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled,
                  PlayerRecoveryPolicy.timeout(for: recoveryState) != nil
            else { return }
            recoverPlayback(automatic: true)
        }
        // A new segment starts its own life: an outro should not arrive already spent because
        // the intro's countdown ran out an hour ago.
        .onChange(of: activeSkipSegment?.id) { _, _ in skipAutoHidden = false }
        // A panel covers the picture, so the pause card has nothing to say and nowhere to say
        // it. Reported: pausing and then opening the subtitle chooser raised "You are watching"
        // over the list a few seconds later, because the countdown only ever asked whether
        // playback was stopped.
        .onChange(of: engineChrome.panelOpen) { _, open in
            if open {
                dismissPauseOverlay()
            } else {
                schedulePauseOverlay(paused: isPaused)
            }
        }
    }

    /// The layers the host draws over playback that hold focus themselves. The player has to
    /// know: while one is up it must not claim the remote back, or the viewer cannot reach the
    /// Skip button, and the countdown card cannot be answered.
    private var hasFocusableOverlay: Bool {
        skipCardClaimsFocus || nextEpisodeCountdown != nil
            || showsStillWatchingPrompt || showsSourcePanel
    }

    @ViewBuilder
    private var mpvPlayer: some View {
        #if canImport(Libmpv)
        ZStack {
            MPVPlayerView(
                request: request,
                resumeAt: recoveryResumePosition ?? resumePosition,
                verboseLogging: settings.player.verboseLoggingEnabled,
                hardwareDecoding: settings.player.mpvHardwareDecodeMode,
                audioOutput: settings.player.mpvAudioOutput,
                audioChannels: settings.player.audioOutputChannels,
                audioMix: settings.playerAudioMix,
                audioLanguages: settings.audioTrackLanguages,
                subtitleLanguages: settings.subtitleTrackLanguages,
                subtitleStyle: settings.subtitleStyle,
                seekTarget: requestedSeek,
                onSeekApplied: { requestedSeek = nil },
                pauseRequest: requestedPause,
                onPauseApplied: { requestedPause = nil },
                revealControlsRequest: revealControlsRequest,
                onChooseEpisode: request.contentType == "series" ? chooseEpisode : nil,
                onPlayNextEpisode: request.nextUp == nil ? nil : playNextEpisodeNow,
                onSwitchEngine: { engineOverride = .exoplayer },
                showsPauseOverlay: showsPauseOverlay,
                hasOpenPrompt: showsPauseOverlay || nextEpisodeCountdown != nil || showsStillWatchingPrompt,
                onDismissPrompt: dismissTransientPrompt,
                hasFocusableOverlay: hasFocusableOverlay,
                onChromeChange: { engineChrome = $0 },
                onPlaybackTime: observePlaybackTime,
                onPlaybackState: { paused, loading in
                    observePlaybackState(paused: paused, loading: loading)
                },
                onPlaybackFailure: { _ in recoverPlayback(automatic: false) },
                onProgress: { position, duration, completed in
                    observePlaybackTime(position, duration)
                    persist(position: position, duration: duration, completed: completed)
                    scrobble(position: position, duration: duration)
                    simklScrobble(position: position, duration: duration)
                    advanceIfDue(position: position, duration: duration)
                },
                onFinished: {
                    persist(position: 0, duration: 0, completed: true)
                    scrobbleStop(progressPercent: 100)
                    advanceToNextEpisode()
                    dismiss()
                }
            )
            .id(mpvSessionGeneration)

            skipSegmentCard

            postPlayOverlay
            stillWatchingOverlay
            playerStatusOverlay

            if showsSourcePanel {
                InPlayerSourcesPanel(request: request) { showsSourcePanel = false }
            }
        }
        .animation(NuvioMotion.quickTween, value: visibleSkipSegment?.id)
        #else
        avPlayer
        #endif
    }

    private var avPlayer: some View {
        ZStack {
            AVPlayerContainer(
                request: request,
                resumeAt: recoveryResumePosition ?? resumePosition,
                subtitleStyle: settings.subtitleStyle,
                subtitleTracks: subtitles.available,
                subtitleOrganization: settings.player.subtitleOrganizationMode,
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
                    simklScrobble(position: position, duration: duration)
                    advanceIfDue(position: position, duration: duration)
                },
                onFailed: handleAVFoundationFailure,
                onChromeChange: { engineChrome = $0 },
                onFinished: {
                    persist(position: 0, duration: 0, completed: true)
                    scrobbleStop(progressPercent: 100)
                    advanceToNextEpisode()
                    dismiss()
                }
            )

            SubtitleOverlay(cues: subtitles.activeCues, style: settings.subtitleStyle)

            skipSegmentCard

            postPlayOverlay
            stillWatchingOverlay
            playerStatusOverlay

            if let avPlaybackError {
                ErrorStateView(message: avPlaybackError) { retryOnMPV() }
                    .background(.black.opacity(0.85))
            }
        }
        .animation(NuvioMotion.quickTween, value: visibleSkipSegment?.id)
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

    private var recoveryState: PlayerRecoveryPolicy.State {
        PlayerRecoveryPolicy.State(
            isLoading: isLoading,
            hasStartedPlayback: hasStartedPlayback,
            isPaused: isPaused,
            panelOpen: engineChrome.panelOpen || showsSourcePanel,
            promptOpen: nextEpisodeCountdown != nil || showsStillWatchingPrompt,
            automaticAttempts: automaticRecoveryAttempts
        )
    }

    private var recoveryWatchdogKey: String {
        [
            resolvedEngine.rawValue,
            isLoading.description,
            hasStartedPlayback.description,
            isPaused.description,
            recoveryState.panelOpen.description,
            recoveryState.promptOpen.description,
            String(automaticRecoveryAttempts),
            String(mpvSessionGeneration)
        ].joined(separator: "|")
    }

    private func recoverPlayback(automatic: Bool) {
        if automatic {
            guard automaticRecoveryAttempts < PlayerRecoveryPolicy.automaticAttemptLimit else { return }
            automaticRecoveryAttempts += 1
        }
        recoveryResumePosition = playbackPosition > 1 ? playbackPosition : nil
        avPlaybackError = nil

        if resolvedEngine == .exoplayer, MPVEngineSupport.isAvailable {
            // An explicit AVFoundation session override otherwise wins over `didFallBackToMPV`
            // in `resolvedEngine` and makes the watchdog look as if it retried while doing
            // nothing. Keep the override semantics, but point it at the recovery engine.
            if engineOverride != nil {
                engineOverride = .mpv
            } else {
                didFallBackToMPV = true
            }
        } else {
            mpvSessionGeneration += 1
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
               ordered,
               preferred: settings.player.subtitlePreferredLanguage,
               // The track mpv will pick, which is what decides whether a full subtitle track
               // would be repeating dialogue the viewer can already understand.
               audioLanguage: settings.audioTrackLanguages.first,
               useForced: settings.player.subtitleUseForcedSubtitles
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

    private var skipVisibility: SkipSegmentVisibility.State {
        SkipSegmentVisibility.State(
            hasActiveSegment: activeSkipSegment != nil,
            autoHidden: skipAutoHidden,
            controlsVisible: engineChrome.controlsVisible,
            panelOpen: engineChrome.panelOpen || showsSourcePanel,
            promptOpen: nextEpisodeCountdown != nil || showsStillWatchingPrompt
        )
    }

    /// The segment the card is actually drawn for, which is not simply the one playback is
    /// inside: it hides behind a panel, and it steps aside once its countdown has run.
    private var visibleSkipSegment: SkipSegment? {
        SkipSegmentVisibility.showsCard(skipVisibility) ? activeSkipSegment : nil
    }

    private var skipCardClaimsFocus: Bool {
        SkipSegmentVisibility.claimsFocus(skipVisibility)
    }

    /// What restarts the auto-hide countdown: a different segment, or the card becoming the only
    /// thing on screen again after the transport went down.
    ///
    /// Upstream resumes from the time that was left; this starts the ten seconds over. The
    /// difference only shows after the viewer has raised and lowered the transport mid-segment,
    /// and giving them the full countdown back is the friendlier of the two answers — it is also
    /// what the strip along the card's bottom edge draws, so the two never disagree.
    private var skipCountdownKey: String {
        let running = SkipSegmentVisibility.runsAutoHideCountdown(skipVisibility)
        return "\(activeSkipSegment?.id ?? "-")|\(running)"
    }

    @ViewBuilder
    private var skipSegmentCard: some View {
        if let segment = visibleSkipSegment {
            SkipSegmentButton(
                segment: segment,
                claimsFocus: skipCardClaimsFocus,
                showsCountdown: SkipSegmentVisibility.runsAutoHideCountdown(skipVisibility),
                action: { skip(segment) },
                onDismiss: {
                    skipAutoHidden = true
                    revealControlsRequest += 1
                },
                onSeek: seekFromSkipCard
            )
            .padding(.leading, NuvioTheme.layout.tvSafeHorizontal)
            // Clear the transport bar while remaining reachable with the Siri Remote when the
            // system controls are hidden.
            .padding(.bottom, dp(116))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
        }
    }

    /// Left and Right while the skip card holds the remote.
    ///
    /// The card is not modal — Android lets you keep steering while it is up — but on tvOS
    /// whatever holds focus is the only thing that receives a press, and a card is not a
    /// scrubber. So it forwards them here, through the same acceleration table the transport's
    /// own progress bar uses, and a held direction crosses the opening rather than nudging it.
    private func seekFromSkipCard(forward: Bool) {
        let now = Date()
        let isRepeat = now.timeIntervalSince(skipCardSeekAt) <= PlayerScrubRates.repeatWindow
        skipCardSeekCount = isRepeat ? skipCardSeekCount + 1 : 0
        skipCardSeekAt = now
        // Chained off the last target while the presses keep coming: the engine's own clock has
        // not caught up to the previous seek yet, so basing each press on it would stand still.
        let base = isRepeat ? (skipCardSeekTarget ?? playbackPosition) : playbackPosition
        let target = max(0, base + PlayerScrubRates.delta(forRepeatCount: skipCardSeekCount, forward: forward))
        skipCardSeekTarget = target
        requestedSeek = target
    }

    /// L10n.text("player.skip_automatically", fallback: "Skip automatically") for the kinds the viewer opted into — a setting that existed in the
    /// UI and was read by nothing until now.
    ///
    /// `skip(_:)` records the segment in `dismissedSkipSegments`, which is also what stops the
    /// button re-appearing, so a segment can only be auto-skipped once. Seeking backwards over an
    /// opening you have already passed therefore does not jump you forward again.
    private func autoSkipIfEnabled() {
        guard let segment = activeSkipSegment,
              settings.skipIntro.autoSkips(segment.kind)
        else { return }
        skip(segment)
    }

    /// The harness stages cards over a stream that deliberately never starts, and the loading
    /// cover is drawn over everything until the first frame — so it would sit on top of the one
    /// thing being looked at. False in any shipping build.
    private var stagesHarnessOverlays: Bool {
        #if DEBUG
        return PlayerHarness.skipSegments() != nil || PlayerHarness.stagesUpNext
        #else
        return false
        #endif
    }


    @ViewBuilder
    private var playerStatusOverlay: some View {
        if isLoading, !hasStartedPlayback, settings.player.loadingOverlayEnabled,
           !stagesHarnessOverlays {
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
        if paused != wasPaused {
            // A sustained pause lets the television sleep again; a buffer stall does not last
            // long enough to. See `PlaybackWakeLockPolicy`.
            PlaybackWakeLock.setPaused(paused)
            schedulePauseOverlay(paused: paused)
            if paused, !isRouteChangePause {
                simklPause()
            } else if !paused {
                simklScrobble(position: playbackPosition, duration: playbackDuration)
            }
        }
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

    /// What the pause card's rule sees. `paused` is passed in rather than read back, because the
    /// state this schedules from is the transition being reported, not the one already stored.
    private func pauseCardState(paused: Bool) -> PlayerPauseCardPolicy.State {
        PlayerPauseCardPolicy.State(
            isPaused: paused,
            isEnabled: settings.player.pauseOverlayEnabled,
            hasStartedPlayback: hasStartedPlayback,
            panelOpen: engineChrome.panelOpen || showsSourcePanel,
            promptOpen: nextEpisodeCountdown != nil || showsStillWatchingPrompt
        )
    }

    private func schedulePauseOverlay(paused: Bool) {
        pauseOverlayTask?.cancel()
        pauseOverlayTask = nil
        guard PlayerPauseCardPolicy.shouldRaise(pauseCardState(paused: paused)) else {
            withAnimation(NuvioMotion.quickTween) { showsPauseOverlay = false }
            return
        }
        pauseOverlayTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PlayerPauseCardPolicy.delay))
            // Asked again on the way out: five seconds is long enough for the viewer to have
            // opened a panel, and the card must not arrive on top of it.
            guard !Task.isCancelled,
                  PlayerPauseCardPolicy.shouldRaise(pauseCardState(paused: isPaused))
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
            playbackDuration = duration
            loadSkipSegmentsIfNeeded(duration: duration)
        }
        autoSkipIfEnabled()
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
        let animeSkipClientId = settings.skipIntro.animeSkipEnabled
            ? settings.skipIntro.animeSkipClientId
            : ""
        let imdbId = ids.lazy.first(where: { $0.hasPrefix("tt") })
            .map { String($0.split(separator: ":")[0]) }
        let season = request.season
        let episode = request.episode

        Task {
            // All three at once, then merged category by category. Asking them in turn and taking
            // the first non-empty answer loses segments whenever a provider is partly populated,
            // which is normal: IntroDB has an intro but no outro for some titles, and the outro
            // AniSkip holds would never have been asked for.
            async let introDb: [SkipSegment] = {
                guard let imdbId, let season, let episode else { return [] }
                // An empty setting means "use the public endpoint", not "skip this provider".
                return await SkipIntroClient.shared.introDbSegments(
                    baseURL: introDbUrl, imdbId: imdbId, season: season, episode: episode
                )
            }()

            async let anime: (aniSkip: [SkipSegment], animeSkip: [SkipSegment]) = {
                if let directMAL {
                    // A `mal:` id names the title outright, so no mapping is needed and there is
                    // no AniList id to reach Anime-Skip with.
                    let segments = await SkipIntroClient.shared.segments(
                        malId: directMAL.id, episode: directMAL.episode, episodeLength: duration
                    )
                    return (segments, [])
                }
                guard let imdbId, let episode else { return ([], []) }
                let entries = await SkipIntroClient.shared.armEntries(imdbId: imdbId)
                guard !entries.isEmpty else { return ([], []) }

                let aniSkip: [SkipSegment]
                if let malId = SkipIntroClient.malId(
                    fromSeasonEntries: entries.map(\.myanimelist), season: season ?? 1
                ) {
                    aniSkip = await SkipIntroClient.shared.segments(
                        malId: malId, episode: episode, episodeLength: duration
                    )
                } else {
                    aniSkip = []
                }

                let animeSkip = await Self.animeSkipSegments(
                    entries: entries,
                    season: season,
                    episode: episode,
                    episodeLength: duration,
                    clientId: animeSkipClientId
                )
                return (aniSkip, animeSkip)
            }()

            let (aniSkip, animeSkip) = await anime
            // Priority order, as upstream: AniSkip knows anime natively, Anime-Skip second,
            // IntroDB last because it is the broadest and the least specific.
            let merged = SkipIntroClient.merge([aniSkip, animeSkip, await introDb])

            guard skipLookupKey == key else { return }
            skipSegments = merged
        }
    }

    /// Anime-Skip is keyed by AniList id, per season. Upstream tries the season's own id first
    /// with no season filter, then falls back to the first season's id *with* one — a show whose
    /// seasons are separate AniList entries and one whose seasons live under a single entry are
    /// both common, and the two attempts cover each case.
    private static func animeSkipSegments(
        entries: [SkipIntroClient.ArmEntry],
        season: Int?,
        episode: Int,
        episodeLength: Double,
        clientId: String
    ) async -> [SkipSegment] {
        guard !clientId.isEmpty else { return [] }
        let anilistIds = entries.map(\.anilist)
        let seasonSpecific = SkipIntroClient.anilistId(
            fromSeasonEntries: anilistIds, season: season ?? 1
        )
        let first = anilistIds.compactMap { $0 }.first

        if let seasonSpecific {
            let found = await SkipIntroClient.shared.animeSkipSegments(
                anilistId: seasonSpecific, episode: episode, season: nil,
                episodeLength: episodeLength, clientId: clientId
            )
            if !found.isEmpty { return found }
        }
        guard let first, first != seasonSpecific else { return [] }
        return await SkipIntroClient.shared.animeSkipSegments(
            anilistId: first, episode: episode, season: season,
            episodeLength: episodeLength, clientId: clientId
        )
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
        guard !didSendTrackingStop, let credentials = traktCredentials, let imdbId = request.imdbId,
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

    private func scrobbleStop(progressPercent explicitPercent: Double? = nil) {
        guard !didSendTrackingStop else { return }
        let percent = explicitPercent ?? {
            guard playbackDuration > 0 else { return 0 }
            return min(100, max(0, playbackPosition / playbackDuration * 100))
        }()
        guard didScrobbleStart || simklSessionActive || percent >= 80 else { return }
        didSendTrackingStop = true
        if let credentials = traktCredentials, let imdbId = request.imdbId {
            Task {
                await TraktClient.shared.scrobble(
                    action: .stop, imdbId: imdbId, type: ContentType.from(request.contentType),
                    season: request.season, episode: request.episode,
                    progressPercent: percent,
                    clientId: credentials.clientId, token: credentials.token
                )
            }
        }
        if let credentials = simklCredentials {
            Task {
                await SimklClient.shared.scrobble(
                    action: .stop,
                    imdbId: request.imdbId, contentId: request.contentId,
                    type: ContentType.from(request.contentType),
                    season: request.season, episode: request.episode,
                    progressPercent: percent,
                    clientId: credentials.clientId, token: credentials.token
                )
            }
        }
        simklSessionActive = false
    }

    // MARK: Simkl

    private var simklCredentials: (clientId: String, token: String)? {
        let tracking = settings.tracking
        guard tracking.simklScrobbleEnabled, tracking.isSimklAuthenticated,
              !tracking.simklClientId.isEmpty else { return nil }
        return (tracking.simklClientId, tracking.simklAccessToken)
    }

    private func simklScrobble(position: Double, duration: Double) {
        guard !didSendTrackingStop, !simklSessionActive, duration > 0, let credentials = simklCredentials,
              !(request.imdbId ?? request.contentId).isEmpty else { return }
        let percent = min(100, max(0, position / duration * 100))
        // Matches Android: resuming something already beyond Simkl's completion threshold must
        // not create another history entry.
        guard percent < 80 else { return }
        simklSessionActive = true
        Task {
            await SimklClient.shared.scrobble(
                action: .start,
                imdbId: request.imdbId, contentId: request.contentId,
                type: ContentType.from(request.contentType),
                season: request.season, episode: request.episode,
                progressPercent: percent,
                clientId: credentials.clientId, token: credentials.token
            )
        }
    }

    private func simklPause() {
        guard simklSessionActive, playbackDuration > 0, let credentials = simklCredentials,
              !(request.imdbId ?? request.contentId).isEmpty else { return }
        simklSessionActive = false
        let percent = min(100, max(0, playbackPosition / playbackDuration * 100))
        Task {
            await SimklClient.shared.scrobble(
                action: .pause,
                imdbId: request.imdbId, contentId: request.contentId,
                type: ContentType.from(request.contentType),
                season: request.season, episode: request.episode,
                progressPercent: percent,
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
        PlaybackSessionStore.shared.markAutoAdvance(
            to: next.videoId,
            // Only offered when the viewer asked for it; the stream screen decides what to do
            // with it, and ignores it entirely when the preference is off.
            bingeGroup: settings.player.preferBingeGroupNextEpisode ? request.sourceBingeGroup : nil
        )
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
        PlaybackSessionStore.shared.markAutoAdvance(
            to: next.videoId,
            // Only offered when the viewer asked for it; the stream screen decides what to do
            // with it, and ignores it entirely when the preference is off.
            bingeGroup: settings.player.preferBingeGroupNextEpisode ? request.sourceBingeGroup : nil
        )
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
        // Watching it again spends the dismissal. Otherwise one wave-away silences the series
        // for good, including seasons that have not aired yet.
        let remaining = NextUpDismissal.clearing(
            contentId: request.contentId, from: settings.layout.dismissedNextUpKeys
        )
        if remaining.count != settings.layout.dismissedNextUpKeys.count {
            settings.layout.dismissedNextUpKeys = remaining
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
    /// How the addon-track menu is grouped — `subtitle_organization_mode`. The engine that
    /// groups them has existed since the port began; nothing was telling it which mode to use,
    /// so every viewer got "by language" whatever they had chosen.
    let subtitleOrganization: SubtitleOrganizationMode
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
    /// Whether the transport bar is on screen.  AVKit owns it and never volunteers the fact, so
    /// the layers the host draws on top — the skip card above all — had no way to tell bare
    /// picture from a control row the viewer was in the middle of using.
    let onChromeChange: (PlayerChromeState) -> Void
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onProgress: onProgress, onFinished: onFinished, onTick: onTick, onFailed: onFailed,
            onPlaybackState: onPlaybackState, onChromeChange: onChromeChange
        )
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
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

        let groups = SubtitleSelector.group(subtitleTracks, mode: subtitleOrganization)
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
            title: L10n.text("player.addon_subtitles", fallback: "Addon Subtitles"),
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

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private let onProgress: (Double, Double, Bool) -> Void
        private let onFinished: () -> Void
        private let onTick: (Double, Double) -> Void
        private let onFailed: (String?) -> Void
        private let onPlaybackState: (Bool, Bool) -> Void
        private let onChromeChange: (PlayerChromeState) -> Void
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
            onPlaybackState: @escaping (Bool, Bool) -> Void,
            onChromeChange: @escaping (PlayerChromeState) -> Void
        ) {
            self.onProgress = onProgress
            self.onFinished = onFinished
            self.onTick = onTick
            self.onFailed = onFailed
            self.onPlaybackState = onPlaybackState
            self.onChromeChange = onChromeChange
            super.init()
        }

        /// The one hook AVKit gives onto its transport bar.  It fires as the transition starts,
        /// which is what the layers above want: the skip card should step out of the way of a
        /// control row that is on its way in, not a frame after it has arrived.
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willTransitionToVisibilityOfTransportBar isVisible: Bool,
            with coordinator: AVPlayerViewControllerAnimationCoordinator
        ) {
            onChromeChange(PlayerChromeState(controlsVisible: isVisible, panelOpen: false))
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
