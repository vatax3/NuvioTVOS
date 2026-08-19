#if canImport(Libmpv)
import SwiftUI
import UIKit

/// The MPV playback surface plus its transport overlay.
///
/// AVPlayerViewController can only host an AVPlayer, so this engine needs its own chrome. The
/// controls are deliberately the ones a remote can reach without a menu: play/pause on select,
/// ±10s on left/right, a scrubber, and track pickers for what the file carries.
struct MPVPlayerView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.dismiss) private var dismiss

    let request: PlaybackRequest
    let resumeAt: Double
    let verboseLogging: Bool
    let hardwareDecoding: MpvHardwareDecodeMode
    let subtitleStyle: SubtitleStyle
    let onProgress: (Double, Double, Bool) -> Void
    let onFinished: () -> Void

    @State private var engine = MPVEngine()
    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var lastPersistedPosition: Double = 0
    @State private var picker: TrackPicker?
    /// Focus lands on Pause once and stays in the transport for the whole session.
    @FocusState private var transportFocused: Bool

    private enum TrackPicker: String, Identifiable {
        case audio, subtitles
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MPVMetalSurface(engine: engine, request: request, resumeAt: resumeAt,
                            verboseLogging: verboseLogging, hardwareDecoding: hardwareDecoding)
                .ignoresSafeArea()

            if engine.isBuffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.8)
            }

            // A running clock with nothing drawn is the black-screen case. Saying so beats a
            // blank screen, and mpv's own log is the only thing that explains why.
            if engine.position > 3, !engine.hasRenderedFrame {
                renderDiagnostic
            }

            if let error = engine.errorMessage {
                ErrorStateView(message: error) { dismiss() }
                    .background(.black.opacity(0.75))
            }

            // Always mounted, only faded. Swapping the transport in and out — or giving it a
            // focusable full-screen ancestor — means focus has to jump between subtrees every
            // time the bar hides, and tvOS drops it on the way: the remote stops responding, or
            // moving right off Pause lands nowhere. Keeping one set of buttons permanently in
            // the hierarchy means focus never has to move at all.
            controls
                .opacity(showsControls ? 1 : 0)
                .animation(NuvioMotion.quickTween, value: showsControls)
        }
        .onExitCommand { dismiss() }
        .sheet(item: $picker) { which in
            trackSheet(which)
        }
        .task { start() }
        .onDisappear {
            hideTask?.cancel()
            persist(completed: false)
            engine.destroy()
        }
        .onChange(of: engine.position) { _, position in
            // Same 5s cadence as the AVFoundation path.
            guard position - lastPersistedPosition >= 5 || lastPersistedPosition == 0 else { return }
            lastPersistedPosition = position
            onProgress(position, engine.duration, false)
        }
        .onChange(of: engine.didEnd) { _, ended in
            if ended { onFinished() }
        }
        .onChange(of: engine.isPaused) { _, paused in
            if paused { wakeControls() } else { scheduleHide() }
        }
        .onAppear {
            // One hop's grace so the buttons are in the focus system before it is aimed at them.
            Task { @MainActor in transportFocused = true }
        }
    }

    private var renderDiagnostic: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
            Text("Audio is playing but no picture is being drawn")
                .nuvioText(NuvioTextStyles.headline)
                .foregroundStyle(.white)
            Text(
                """
                No video frames were produced. Try Settings → Playback → MPV hardware \
                decoding → Disabled (software).
                """
            )
            .nuvioText(NuvioTextStyles.bodyCompact)
            .foregroundStyle(.white.opacity(0.75))

            if !engine.logTail.isEmpty {
                Text(engine.logTail.suffix(8).joined(separator: "\n"))
                    .font(.system(size: sp(13), design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(8)
            }
        }
        .padding(NuvioTheme.spacing.xl)
        .frame(maxWidth: dp(600), alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous)
                .fill(.black.opacity(0.72))
        }
    }

    /// mpv is started by `MPVMetalSurface`, which owns the layer it has to be handed. All that
    /// is left here is the addon subtitle tracks and the auto-hide timer.
    private func start() {
        for subtitle in request.subtitles.prefix(8) {
            engine.addSubtitle(url: subtitle.url, title: subtitle.displayLanguage)
        }
        scheduleHide()
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            Spacer()

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                Text(request.title)
                    .nuvioText(NuvioTextStyles.headline)
                    .foregroundStyle(.white)
                if let line = request.subtitleLine {
                    Text(line)
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            scrubber

            HStack(spacing: NuvioTheme.spacing.md) {
                controlButton(
                    engine.isPaused ? "play.fill" : "pause.fill",
                    label: engine.isPaused ? "Play" : "Pause"
                ) { engine.togglePause() }
                .focused($transportFocused)

                controlButton("gobackward.10", label: "Back 10s") { engine.seek(by: -10) }
                controlButton("goforward.10", label: "Forward 10s") { engine.seek(by: 10) }

                if !engine.audioTracks.isEmpty {
                    controlButton("waveform", label: "Audio") { picker = .audio }
                }
                if !engine.subtitleTracks.isEmpty {
                    controlButton("captions.bubble", label: "Subtitles") { picker = .subtitles }
                }

                Spacer()

                Text("MPV")
                    .nuvioText(NuvioTypography.labelSmall)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)
        .padding(.bottom, NuvioTheme.layout.tvSafeVertical)
        .background {
            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .center,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .focusSection()
        .onMoveCommand { _ in wakeControls() }
        .onPlayPauseCommand {
            engine.togglePause()
            wakeControls()
        }
    }

    private var scrubber: some View {
        VStack(spacing: NuvioTheme.spacing.xs) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule()
                        .fill(colors.secondary)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: NuvioTheme.strokes.progress)

            HStack {
                Text(timecode(engine.position))
                Spacer()
                Text(timecode(max(0, engine.duration - engine.position)).prepending("-"))
            }
            .nuvioText(NuvioTextStyles.metadata)
            .foregroundStyle(.white.opacity(0.75))
            .monospacedDigit()
        }
    }

    private var fraction: Double {
        guard engine.duration > 0 else { return 0 }
        return min(1, max(0, engine.position / engine.duration))
    }

    private func controlButton(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            wakeControls()
            action()
        }) {
            Image(systemName: systemImage)
                .font(.system(size: NuvioTheme.sizes.icons.md))
                .foregroundStyle(.white)
                .frame(width: dp(64), height: dp(48))
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.md))
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func trackSheet(_ which: TrackPicker) -> some View {
        let tracks = which == .audio ? engine.audioTracks : engine.subtitleTracks
        NuvioScreenBackground {
            VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                Text(which == .audio ? "Audio track" : "Subtitles")
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)

                SettingsCard(title: "Tracks in this file") {
                    if which == .subtitles {
                        SettingsRow(title: "Off", systemImage: "captions.bubble", action: {
                            engine.selectSubtitleTrack(nil)
                            picker = nil
                        })
                    }
                    ForEach(tracks) { track in
                        SettingsRow(
                            title: track.displayName,
                            systemImage: track.isSelected ? "checkmark.circle.fill" : "circle",
                            action: {
                                if which == .audio {
                                    engine.selectAudioTrack(track.id)
                                } else {
                                    engine.selectSubtitleTrack(track.id)
                                }
                                picker = nil
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: Overlay timing

    private func toggleControls() {
        if showsControls {
            withAnimation(NuvioMotion.quickTween) { showsControls = false }
            hideTask?.cancel()
        } else {
            wakeControls()
        }
    }

    private func wakeControls() {
        withAnimation(NuvioMotion.quickTween) { showsControls = true }
        scheduleHide()
    }

    /// Controls stay up while paused — that is when the viewer is looking at them.
    private func scheduleHide() {
        hideTask?.cancel()
        guard !engine.isPaused else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !engine.isPaused else { return }
            withAnimation(NuvioMotion.quickTween) { showsControls = false }
        }
    }

    private func persist(completed: Bool) {
        guard engine.duration > 0 else { return }
        onProgress(engine.position, engine.duration, completed)
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

private extension String {
    func prepending(_ prefix: String) -> String { prefix + self }
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

    func makeUIViewController(context: Context) -> MPVMetalViewController {
        MPVMetalViewController(
            engine: engine, request: request, resumeAt: resumeAt,
            verboseLogging: verboseLogging, hardwareDecoding: hardwareDecoding
        )
    }

    func updateUIViewController(_ controller: MPVMetalViewController, context: Context) {}
}

final class MPVMetalViewController: UIViewController {
    private let engine: MPVEngine
    private let request: PlaybackRequest
    private let resumeAt: Double
    private let verboseLogging: Bool
    private let hardwareDecoding: MpvHardwareDecodeMode

    private let metalLayer = MPVMetalLayer()
    private var lastDrawableSize: CGSize = .zero

    init(
        engine: MPVEngine,
        request: PlaybackRequest,
        resumeAt: Double,
        verboseLogging: Bool,
        hardwareDecoding: MpvHardwareDecodeMode
    ) {
        self.engine = engine
        self.request = request
        self.resumeAt = resumeAt
        self.verboseLogging = verboseLogging
        self.hardwareDecoding = hardwareDecoding
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

        engine.start(
            url: request.streamURL,
            headers: request.headers,
            startAt: resumeAt,
            verboseLogging: verboseLogging,
            hardwareDecoding: hardwareDecoding,
            layer: metalLayer
        )
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
}

#endif
