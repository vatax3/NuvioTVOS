#if canImport(Libmpv)
import SwiftUI
import GLKit
import OpenGLES

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
    let subtitleStyle: SubtitleStyle
    let onProgress: (Double, Double, Bool) -> Void
    let onFinished: () -> Void

    @State private var engine = MPVEngine()
    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var lastPersistedPosition: Double = 0
    @State private var picker: TrackPicker?

    private enum TrackPicker: String, Identifiable {
        case audio, subtitles
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MPVRenderSurface(engine: engine)
                .ignoresSafeArea()

            if engine.isBuffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.8)
            }

            if let error = engine.errorMessage {
                ErrorStateView(message: error) { dismiss() }
                    .background(.black.opacity(0.75))
            }

            if showsControls {
                controls
                    .transition(.opacity)
            }
        }
        // The remote's select button is the primary control, so the whole surface is the target.
        .onTapGesture { toggleControls() }
        .onMoveCommand { direction in
            wakeControls()
            switch direction {
            case .left: engine.seek(by: -10)
            case .right: engine.seek(by: 10)
            default: break
            }
        }
        .onPlayPauseCommand {
            engine.togglePause()
            wakeControls()
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
    }

    private func start() {
        engine.start(
            url: request.streamURL,
            headers: request.headers,
            startAt: resumeAt,
            verboseLogging: verboseLogging
        )
        // Addon subtitles are files, so mpv can load them directly rather than being drawn over.
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

// MARK: - GL surface

/// Hosts mpv's OpenGL output. tvOS still ships GLES, and libmpv's render API targets it directly,
/// which is a far shorter path than bridging through Metal.
private struct MPVRenderSurface: UIViewControllerRepresentable {
    let engine: MPVEngine

    func makeUIViewController(context: Context) -> MPVGLViewController {
        MPVGLViewController(engine: engine)
    }

    func updateUIViewController(_ controller: MPVGLViewController, context: Context) {}
}

final class MPVGLViewController: UIViewController, GLKViewDelegate {
    private let engine: MPVEngine
    private var glContext: EAGLContext?
    private var glView: GLKView?

    init(engine: MPVEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        guard let context = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) else {
            view = UIView()
            return
        }
        glContext = context

        let glView = GLKView(frame: .zero, context: context)
        glView.delegate = self
        glView.drawableDepthFormat = .formatNone
        glView.drawableStencilFormat = .formatNone
        glView.drawableColorFormat = .RGBA8888
        // mpv drives redraws through its update callback; there is no free-running loop.
        glView.enableSetNeedsDisplay = true
        glView.backgroundColor = .black
        glView.isUserInteractionEnabled = false
        self.glView = glView
        view = glView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let glContext else { return }
        EAGLContext.setCurrent(glContext)
        engine.createRenderContext()
        engine.onRedraw = { [weak self] in
            // The callback arrives on mpv's thread; drawing has to be on the main one.
            Task { @MainActor in self?.glView?.setNeedsDisplay() }
        }
    }

    func glkView(_ view: GLKView, drawIn rect: CGRect) {
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)
        engine.render(
            framebuffer: framebuffer,
            width: Int32(view.drawableWidth),
            height: Int32(view.drawableHeight)
        )
    }

    deinit {
        if EAGLContext.current() === glContext { EAGLContext.setCurrent(nil) }
    }
}

#endif
