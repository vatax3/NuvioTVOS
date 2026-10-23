#if canImport(PlayerEngineKit)
import AVFoundation
import SwiftUI
import PlayerEngineKit

/// AetherEngine's playback view: the engine, the surface it binds to, and the shared chrome.
///
/// The exact counterpart of `MPVPlayerView`, and deliberately shaped the same way — everything a
/// viewer sees and presses is `PlayerChrome`, which is generic over the engine. What is here is
/// what is genuinely this engine's: the `LoadOptions` the session is opened with, the view the
/// engine binds its layer to, and the subtitle overlay, because on this path the host draws the
/// cues rather than the engine.
struct AetherPlayerView: View {
    @Environment(AppSettings.self) private var settings

    let request: PlaybackRequest
    let resumeAt: Double
    let subtitleStyle: SubtitleStyle
    let audioLanguages: [String]
    let subtitleLanguages: [String]
    let frameRateMatchingMode: FrameRateMatchingMode
    var addonCues: [SubtitleCue] = []
    var addonCueClock: Double = 0
    var onSubtitleDelayChange: ((Double) -> Void)?
    let seekTarget: Double?
    let onSeekApplied: () -> Void
    let pauseRequest: PlaybackTransportRequest?
    let onPauseApplied: () -> Void
    var partyRate: Double?
    let revealControlsRequest: Int
    let onChooseEpisode: ((StreamRequest) -> Void)?
    let onPlayNextEpisode: (() -> Void)?
    let onSwitchEngine: (() -> Void)?
    var isPartyActive = false
    var onViewerSpeedChange: ((Double) -> Void)?
    var onShowParty: (() -> Void)?
    let showsPauseOverlay: Bool
    let hasOpenPrompt: Bool
    let onDismissPrompt: () -> Void
    let hasFocusableOverlay: Bool
    let onChromeChange: (PlayerChromeState) -> Void
    let onPlaybackTime: (Double, Double) -> Void
    let onPlaybackState: (Bool, Bool) -> Void
    /// Carries whether another engine is worth trying, which only this engine can answer: it reads
    /// the origin's HTTP status, so it can tell a refusal from a file mpv would open.
    let onPlaybackFailure: (String, Bool) -> Void
    let onProgress: (Double, Double, Bool) -> Void
    let onFinished: () -> Void

    @State private var adapter = AetherEngineAdapter()

    var body: some View {
        if let adapter {
            PlayerChrome(
                request: request,
                addonCues: addonCues,
                addonCueClock: addonCueClock,
                onSubtitleDelayChange: onSubtitleDelayChange,
                seekTarget: seekTarget,
                onSeekApplied: onSeekApplied,
                pauseRequest: pauseRequest,
                onPauseApplied: onPauseApplied,
                partyRate: partyRate,
                revealControlsRequest: revealControlsRequest,
                onChooseEpisode: onChooseEpisode,
                onPlayNextEpisode: onPlayNextEpisode,
                onSwitchEngine: onSwitchEngine,
                isPartyActive: isPartyActive,
                onViewerSpeedChange: onViewerSpeedChange,
                onShowParty: onShowParty,
                showsPauseOverlay: showsPauseOverlay,
                hasOpenPrompt: hasOpenPrompt,
                onDismissPrompt: onDismissPrompt,
                hasFocusableOverlay: hasFocusableOverlay,
                onChromeChange: onChromeChange,
                onPlaybackTime: onPlaybackTime,
                onPlaybackState: onPlaybackState,
                onPlaybackFailure: { message in
                    onPlaybackFailure(message, adapter.failureInvitesAnotherEngine)
                },
                onProgress: onProgress,
                onFinished: onFinished,
                engine: adapter
            ) { context in
                surface(adapter, context: context)
            }
        } else {
            // The engine's `init` throws, and a host that cannot build one has nothing to draw.
            // Reported as a failure another engine should be offered, because it is.
            Color.black
                .ignoresSafeArea()
                .task {
                    onPlaybackFailure(
                        L10n.text("player.engine_unavailable", fallback: "The playback engine could not start."),
                        true
                    )
                }
        }
    }

    @ViewBuilder
    private func surface(_ adapter: AetherEngineAdapter, context: PlayerSurfaceContext) -> some View {
        ZStack {
            AetherPlayerSurface(engine: adapter.engine)

            // The engine hands out cues and leaves the drawing to the host, which is why this
            // overlay is here rather than in the chrome: it is this engine's half of subtitles.
            // The same view draws the AVFoundation path's, with the same style and the same
            // placement rules.
            SubtitleOverlay(
                cues: adapter.cues.filter { $0.contains(adapter.position - adapter.subtitleDelay) },
                style: adapter.subtitleStyle,
                obstructions: context.subtitleObstructions
            )
        }
        .onAppear {
            guard let url else {
                // AetherEngine takes a parsed `URL` where mpv takes the string as it stands, so an
                // addon link nobody escaped plays on one engine and not the other. Named rather
                // than left as a black screen, and worth handing to mpv — see `AVPlayerContainer`.
                onPlaybackFailure(L10n.text("player.error_unplayable_url"), true)
                return
            }
            adapter.start(
                url: url,
                headers: request.headers,
                startAt: resumeAt,
                audioLanguages: audioLanguages,
                subtitleLanguages: subtitleLanguages,
                externalSubtitles: externalSubtitles,
                matchesContent: frameRateMatchingMode != .off,
                initialAspectMode: PlayerAspectMode(resizeMode: settings.player.resizeMode),
                subtitleStyle: presentedSubtitleStyle(adapter)
            )
        }
        .onChange(of: context.playbackSpeed) { _, speed in
            adapter.setPlaybackSpeed(speed)
        }
        .onChange(of: context.subtitleObstructions) { _, obstructions in
            adapter.applySubtitleStyle(presentedSubtitleStyle(adapter), obstructions: obstructions)
        }
        // The picture's colorimetry is only known once the engine has opened the file, so the HDR
        // colour cannot be resolved where the style is composed. Re-applied when it resolves.
        .onChange(of: adapter.isHDRVideo) { _, _ in
            adapter.applySubtitleStyle(presentedSubtitleStyle(adapter), obstructions: context.subtitleObstructions)
        }
    }

    /// The viewer's style, with the HDR colour and brightness applied when this picture is HDR.
    private func presentedSubtitleStyle(_ adapter: AetherEngineAdapter) -> SubtitleStyle {
        subtitleStyle.forVideo(isHDR: adapter.isHDRVideo)
    }

    /// AetherEngine takes a parsed `URL`; mpv takes the string as it stands. An addon link that has
    /// not been escaped therefore plays on one engine and not the other, which is why the failure
    /// is named rather than left as a black screen — see `AVPlayerContainer` for the same case.
    private var url: URL? { URL(string: request.streamURL) }

    /// The addon tracks, declared at load so they also become native renditions and survive PiP,
    /// AirPlay and a wired external display. Eight is the chrome's own limit, kept here.
    private var externalSubtitles: [ExternalSubtitleTrack] {
        request.subtitles.prefix(8).compactMap { subtitle in
            URL(string: subtitle.url).map {
                ExternalSubtitleTrack(url: $0, name: subtitle.displayLanguage, language: subtitle.lang)
            }
        }
    }
}
#endif
