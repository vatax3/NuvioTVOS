#if canImport(Libmpv)
import AVFoundation
import SwiftUI
import UIKit

/// mpv's playback view: the engine, the Metal surface it draws into, and the shared chrome.
///
/// Everything a viewer sees and presses lives in `PlayerChrome`, which is generic over the engine
/// so the next one reuses it rather than growing a second copy. What is left here is what is
/// genuinely mpv's: the twelve decode options, the `CAMetalLayer` mpv takes as a constructor
/// argument, and therefore `start` itself.
struct MPVPlayerView: View {
    @Environment(AppSettings.self) private var settings

    /// The viewer's stored picture shape, handed to mpv before it loads the file. `resize_mode`
    /// had been stored and synced since the port began and applied nowhere, so every playback
    /// started in Fit whatever they had chosen.
    private var initialAspectMode: MPVEngine.AspectMode {
        MPVEngine.AspectMode(resizeMode: settings.player.resizeMode)
    }

    let request: PlaybackRequest
    let resumeAt: Double
    let verboseLogging: Bool
    let hardwareDecoding: MpvHardwareDecodeMode
    let audioOutput: MpvAudioOutput
    let audioChannels: AudioOutputChannels
    let audioMix: PlayerAudioMix.Options
    let audioLanguages: [String]
    let subtitleLanguages: [String]
    let prefersForcedSubtitles: Bool
    /// `hdr-compute-peak`. Threaded rather than read here because the engine is also built by
    /// the recovery path, and a retry must use the same options as the attempt it replaces.
    let hdrPeakDetection: HDRPeakDetection
    let subtitleStyle: SubtitleStyle
    /// The addon subtitle track the host is drawing, if any, plus where it is being read.
    ///
    /// Handed in rather than owned because `SubtitleTrackController` belongs to the host: it
    /// draws for both engines, and mpv's own delay reaches only the tracks mpv renders.
    var addonCues: [SubtitleCue] = []
    var addonCueClock: Double = 0
    /// Reports the delay after any change, so the host can move the cues it draws itself by the
    /// same amount. Called for the stepper and the reset as well as for a synced line.
    var onSubtitleDelayChange: ((Double) -> Void)?
    let seekTarget: Double?
    let onSeekApplied: () -> Void
    let pauseRequest: PlaybackTransportRequest?
    let onPauseApplied: () -> Void
    /// A playback rate a watch party is asking for, or nil to leave the viewer's own speed
    /// alone. Carried like the seek and pause requests above rather than read from the store, so
    /// every change to playback has one owner.
    var partyRate: Double?
    /// Bumped when a layer the host drew over playback has handed the remote back and the
    /// transport should come up in its place. Upstream's skip card moves focus onto the control
    /// row on Down; ours cannot, because the row leaves the focus graph entirely while a card
    /// owns the remote — so the card asks for it back instead.
    let revealControlsRequest: Int
    let onChooseEpisode: ((StreamRequest) -> Void)?
    /// Present only when the episode after this one has aired — Android hides the button
    /// rather than showing one that cannot do anything.
    let onPlayNextEpisode: (() -> Void)?
    /// Hands the same source to AVFoundation.  Android's control row carries the mirror of
    /// this, and it is the escape hatch when a file decodes badly on one engine.
    let onSwitchEngine: (() -> Void)?
    /// Whether a party is running, which decides whether its control is an occasional tool or
    /// part of the row proper.
    var isPartyActive = false
    /// Reports the speed the viewer chose, so a party can publish it.
    var onViewerSpeedChange: ((Double) -> Void)?
    /// Opens the watch-party panel. Absent when the feature is unavailable, which also takes the
    /// control out of the transport rather than offering one that explains itself away.
    var onShowParty: (() -> Void)?
    /// The host's pause card owns the bottom-left of the screen while it is up, so the
    /// transport steps aside rather than drawing the same title behind it.
    let showsPauseOverlay: Bool
    /// Whether the host is drawing a prompt over the picture — the next-episode card or the
    /// still-watching check — and how to dismiss it.  Menu is owned here for the whole session,
    /// so those layers have to be offered the press before the transport is.
    let hasOpenPrompt: Bool
    let onDismissPrompt: () -> Void
    /// Whether one of those layers is focusable in its own right — the skip-intro card, the
    /// next-episode countdown, the still-watching check.  Each owns the remote while it is up,
    /// so the player must neither claim focus back nor read presses that were meant for it.
    let hasFocusableOverlay: Bool
    /// What this engine is currently drawing over the picture.  The host's own layers are
    /// placed against it: the pause card must not rise behind an open track panel, and the skip
    /// card must not take the remote out of a transport the viewer is already using.
    let onChromeChange: (PlayerChromeState) -> Void
    let onPlaybackTime: (Double, Double) -> Void
    let onPlaybackState: (Bool, Bool) -> Void
    let onPlaybackFailure: (String) -> Void
    let onProgress: (Double, Double, Bool) -> Void
    let onFinished: () -> Void

    @State private var engine = MPVEngine()

    var body: some View {
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
            onPlaybackFailure: onPlaybackFailure,
            onProgress: onProgress,
            onFinished: onFinished,
            engine: engine
        ) { context in
            MPVMetalSurface(
                engine: engine, request: request, resumeAt: resumeAt,
                verboseLogging: verboseLogging, hardwareDecoding: hardwareDecoding,
                audioOutput: audioOutput, audioChannels: audioChannels,
                audioMix: audioMix,
                audioLanguages: audioLanguages, subtitleLanguages: subtitleLanguages,
                prefersForcedSubtitles: prefersForcedSubtitles,
                hdrPeakDetection: hdrPeakDetection,
                subtitleStyle: subtitleStyle,
                subtitleObstructions: context.subtitleObstructions,
                playbackSpeed: context.playbackSpeed,
                initialAspectMode: initialAspectMode
            )
        }
    }
}

// MARK: - Metal surface

/// Hosts the `CAMetalLayer` mpv draws into, and starts mpv once that layer exists.
///
/// The order matters and is why starting mpv lives here rather than in the SwiftUI view: the
/// surface is a constructor argument to mpv, not something attached afterwards.
private struct MPVMetalSurface: UIViewControllerRepresentable {
    let engine: MPVEngine
    let request: PlaybackRequest
    let resumeAt: Double
    let verboseLogging: Bool
    let hardwareDecoding: MpvHardwareDecodeMode
    let audioOutput: MpvAudioOutput
    let audioChannels: AudioOutputChannels
    let audioMix: PlayerAudioMix.Options
    let audioLanguages: [String]
    let subtitleLanguages: [String]
    let prefersForcedSubtitles: Bool
    let hdrPeakDetection: HDRPeakDetection
    let subtitleStyle: SubtitleStyle
    /// Whether this engine's transport is on screen, so mpv can lift its own subtitles clear of
    /// it for as long as it is there. See `SubtitlePlacement`.
    let subtitleObstructions: SubtitlePlacement.Obstructions
    /// The rate to run at: a party correction's, or the viewer's own. Applied here rather than
    /// through another `onChange` because this view's body is at the type-checker's limit and
    /// this surface already exists to funnel engine updates.
    let playbackSpeed: Double
    let initialAspectMode: MPVEngine.AspectMode

    func makeUIViewController(context: Context) -> MPVMetalViewController {
        MPVMetalViewController(
            engine: engine, request: request, resumeAt: resumeAt,
            verboseLogging: verboseLogging, hardwareDecoding: hardwareDecoding,
            audioOutput: audioOutput, audioChannels: audioChannels, audioMix: audioMix,
            audioLanguages: audioLanguages, subtitleLanguages: subtitleLanguages,
            prefersForcedSubtitles: prefersForcedSubtitles,
            hdrPeakDetection: hdrPeakDetection,
            subtitleStyle: subtitleStyle, initialAspectMode: initialAspectMode
        )
    }

    func updateUIViewController(_ controller: MPVMetalViewController, context: Context) {
        // `isHDRVideo` only answers once mpv has decoded enough to know the transfer function, so
        // the HDR colour arrives on a later update than the first — which is what this method is
        // for. `applySubtitleStyle` dedups, so the repeat costs nothing.
        controller.applySubtitleStyle(
            subtitleStyle.forVideo(isHDR: engine.isHDRVideo), obstructions: subtitleObstructions
        )
        controller.applyPlaybackSpeed(playbackSpeed)
    }
}

final class MPVMetalViewController: UIViewController {
    private let engine: MPVEngine
    private let request: PlaybackRequest
    private let resumeAt: Double
    private let verboseLogging: Bool
    private let hardwareDecoding: MpvHardwareDecodeMode
    private let audioOutput: MpvAudioOutput
    private let audioChannels: AudioOutputChannels
    private let audioMix: PlayerAudioMix.Options
    private let audioLanguages: [String]
    private let subtitleLanguages: [String]
    private let prefersForcedSubtitles: Bool
    private let hdrPeakDetection: HDRPeakDetection
    private let subtitleStyle: SubtitleStyle
    private let initialAspectMode: MPVEngine.AspectMode

    private let metalLayer = MPVMetalLayer()
    private var lastDrawableSize: CGSize = .zero
    private var appliedSubtitleStyle: SubtitleStyle?
    /// Cached beside the style, because the placement depends on both and the dedup below has to
    /// compare everything that reaches mpv. It did not, and that was a real defect: the transport
    /// lift shipped in 1.0.46 and **never arrived on this engine**, because the style is
    /// unchanged when only the chrome moves, so the guard swallowed every such call. The stored
    /// offset still worked, which is exactly why it went unnoticed — half the feature behaved.
    private var appliedSubtitleObstructions = SubtitlePlacement.Obstructions()
    private var appliedPlaybackSpeed: Double?

    init(
        engine: MPVEngine,
        request: PlaybackRequest,
        resumeAt: Double,
        verboseLogging: Bool,
        hardwareDecoding: MpvHardwareDecodeMode,
        audioOutput: MpvAudioOutput,
        audioChannels: AudioOutputChannels,
        audioMix: PlayerAudioMix.Options,
        audioLanguages: [String],
        subtitleLanguages: [String],
        prefersForcedSubtitles: Bool,
        hdrPeakDetection: HDRPeakDetection,
        subtitleStyle: SubtitleStyle,
        initialAspectMode: MPVEngine.AspectMode
    ) {
        self.engine = engine
        self.request = request
        self.resumeAt = resumeAt
        self.verboseLogging = verboseLogging
        self.hardwareDecoding = hardwareDecoding
        self.audioOutput = audioOutput
        self.audioChannels = audioChannels
        self.audioMix = audioMix
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.prefersForcedSubtitles = prefersForcedSubtitles
        self.hdrPeakDetection = hdrPeakDetection
        self.subtitleStyle = subtitleStyle
        self.initialAspectMode = initialAspectMode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.masksToBounds = true

        metalLayer.contentsGravity = .resizeAspect
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.anchorPoint = .zero
        metalLayer.position = .zero
        view.layer.addSublayer(metalLayer)
        layoutMetalLayer()

        // AVKit activates the tvOS playback route on its own. The custom MPV surface must do
        // it explicitly, otherwise AudioUnit can repeatedly renegotiate the route and stutter.
        configureAudioSession()

        engine.start(
            url: request.streamURL,
            headers: request.headers,
            startAt: resumeAt,
            verboseLogging: verboseLogging,
            hardwareDecoding: hardwareDecoding,
            audioOutput: audioOutput,
            audioChannels: audioChannels,
            audioMix: audioMix,
            audioLanguages: audioLanguages,
            subtitleLanguages: subtitleLanguages,
            prefersForcedSubtitles: prefersForcedSubtitles,
            hdrPeakDetection: hdrPeakDetection,
            subtitleStyle: subtitleStyle,
            initialAspectMode: initialAspectMode,
            layer: metalLayer
        )
        appliedSubtitleStyle = subtitleStyle
    }

    /// Deduped, like the subtitle style above: a speed command on every body evaluation would
    /// reach mpv dozens of times a second while a correction is running.
    func applyPlaybackSpeed(_ speed: Double) {
        guard abs((appliedPlaybackSpeed ?? -1) - speed) > 0.001 else { return }
        appliedPlaybackSpeed = speed
        engine.setPlaybackSpeed(speed)
    }

    func applySubtitleStyle(
        _ style: SubtitleStyle, obstructions: SubtitlePlacement.Obstructions = .init()
    ) {
        guard appliedSubtitleStyle != style || appliedSubtitleObstructions != obstructions
        else { return }
        appliedSubtitleStyle = style
        appliedSubtitleObstructions = obstructions
        engine.applySubtitleStyle(style, obstructions: obstructions)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutMetalLayer()
    }

    private func layoutMetalLayer() {
        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        let drawable = CGSize(
            width: (size.width * scale).rounded(.toNearestOrAwayFromZero),
            height: (size.height * scale).rounded(.toNearestOrAwayFromZero)
        )

        // No implicit animation: mpv polls `drawableSize` from its own thread and a half-applied
        // resize is a torn swapchain.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.position = .zero
        metalLayer.bounds = CGRect(origin: .zero, size: size)
        if drawable != lastDrawableSize {
            metalLayer.drawableSize = drawable
            lastDrawableSize = drawable
        }
        CATransaction.commit()
    }

    private func configureAudioSession() {
        engine.activateAudioSession()
    }
}

#endif
