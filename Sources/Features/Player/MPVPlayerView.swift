#if canImport(Libmpv)
import AVFoundation
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
    @Environment(\.resetFocus) private var resetFocus
    @Environment(AppSettings.self) private var settings

    let request: PlaybackRequest
    let resumeAt: Double
    let verboseLogging: Bool
    let hardwareDecoding: MpvHardwareDecodeMode
    let audioOutput: MpvAudioOutput
    let audioChannels: AudioOutputChannels
    let audioLanguages: [String]
    let subtitleLanguages: [String]
    let subtitleStyle: SubtitleStyle
    let seekTarget: Double?
    let onSeekApplied: () -> Void
    let pauseRequest: PlaybackTransportRequest?
    let onPauseApplied: () -> Void
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
    let onProgress: (Double, Double, Bool) -> Void
    let onFinished: () -> Void

    @State private var engine = MPVEngine()
    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var lastPersistedPosition: Double = 0
    @State private var picker: TrackPicker?
    /// The trailing half of Android's control row, revealed by the chevron.  It holds the tools
    /// a viewer reaches for occasionally — speed, picture mode, hand-off, stream info — so the
    /// primary row stays short enough to cross in a couple of D-pad presses.
    @State private var showsMoreActions = false
    /// When the last Menu press was acted on.  One physical press can reach this view twice:
    /// once through the focused subtree and again while focus is rebuilt after a panel unmounts.
    /// Menu is a discrete gesture, so a second delivery inside one animation is that echo and
    /// never a second decision — without this it closes the panel *and* tears down playback,
    /// dropping the viewer back on the stream list.
    @State private var lastHandledExit: Date = .distantPast
    /// Consecutive scrub commands and when the last one landed. Together they reconstruct
    /// Android's `KeyEvent.repeatCount` acceleration on a platform with no repeat counter.
    @State private var scrubRepeatCount = 0
    @State private var lastScrubAt: Date = .distantPast
    /// Where the viewer has scrubbed to but mpv has not been asked to go yet.  Seeks are
    /// committed once the presses stop, so holding a direction crosses an hour without issuing
    /// an absolute seek per frame of the hold.
    @State private var scrubTarget: Double?
    @State private var scrubCommit: Task<Void, Never>?
    /// The ramp that runs while a direction is held down.  See `PlayerHoldSeekGate`.
    @State private var holdSeek: Task<Void, Never>?
    /// Android flashes the new picture mode as a pill instead of opening a menu, so the aspect
    /// button can be pressed repeatedly while watching the picture change.
    @State private var aspectFlash: String?
    @State private var aspectFlashTask: Task<Void, Never>?
    /// Focus lands on Pause when the transport appears, and moves between the progress bar and
    /// the buttons from there — the same two stops the Android control row has.
    @FocusState private var controlFocus: ControlFocus?
    /// See `retargetFocus`: aiming focus is a race against the render that makes the target
    /// focusable, so the attempt is repeated until it lands.
    @State private var focusRetry: Task<Void, Never>?
    /// Where a focus reset should land. Writing the binding is not always enough — the focus
    /// engine can decline an update whose target became focusable in the same frame — so the
    /// player also asks for the whole scope to be re-evaluated, and this is what it should
    /// choose when it is.
    @State private var preferredFocus: ControlFocus = .playPause
    @Namespace private var playerFocus

    /// `sink` is the invisible full-screen target that owns the remote while the transport is
    /// down; see `remoteSink`. Every button in the row is bound too — not to aim focus at them,
    /// but so that "focus is still somewhere in the transport" is a question this view can
    /// answer. Without it, focus resting on a button with no binding is indistinguishable from
    /// focus having been lost, and those two need opposite responses.
    private enum ControlFocus: Hashable {
        case sink, progress, playPause
        case control(String)
    }

    private enum TrackPicker: String, Identifiable {
        case audio, subtitles, subtitleAppearance, speed, streamInfo, sources, episodes
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MPVMetalSurface(engine: engine, request: request, resumeAt: resumeAt,
                            verboseLogging: verboseLogging, hardwareDecoding: hardwareDecoding,
                            audioOutput: audioOutput, audioChannels: audioChannels,
                            audioLanguages: audioLanguages, subtitleLanguages: subtitleLanguages,
                            subtitleStyle: subtitleStyle)
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

            if engine.isSilentlyFallingBack {
                audioDiagnostic
            }

            if let error = engine.errorMessage {
                ErrorStateView(message: error) { dismiss() }
                    .background(.black.opacity(0.75))
            }

            remoteSink

            // Always mounted, only faded. Swapping the transport in and out — or giving it a
            // focusable full-screen ancestor — means focus has to jump between subtrees every
            // time the bar hides, and tvOS drops it on the way: the remote stops responding, or
            // moving right off Pause lands nowhere. Keeping one set of buttons permanently in
            // the hierarchy means focus never has to move at all.
            // Android hides the transport while a chooser is up so the two never compete for
            // the bottom of the screen — the overlay's own columns start where the control row
            // would be.  Fading rather than unmounting keeps the focus caveat above intact.
            controls
                .opacity(showsControls && picker == nil && !showsPauseOverlay ? 1 : 0)
                .animation(NuvioMotion.quickTween, value: showsControls)
                .animation(NuvioMotion.quickTween, value: picker)
                .animation(NuvioMotion.quickTween, value: showsPauseOverlay)

            clockOverlay
            aspectFlashPill

            if let picker {
                playerPanel(picker)
            }
        }
        // One focus scope for the whole player, so a focus reset has something to aim at: see
        // `applyFocusOwner`.
        .focusScope(playerFocus)
        // Menu is owned here for the whole playback session, the way Android owns Back with a
        // single `BackHandler`.  A press recognizer sits above the responder chain, so the
        // presentation controller behind the player never gets to interpret the press as a
        // request to leave; `onExitCommand` stays as the fallback if the recognizer cannot be
        // installed, and the timestamp above keeps the two from acting on one press twice.
        .background(MenuPressGate(action: handleExitCommand))
        // Holding Left or Right runs a continuous seek.  A tap already stepped ten seconds and
        // a fast series of taps accelerated, but a *held* direction did nothing beyond the
        // first press — tvOS does not repeat a move command the way Android repeats a key
        // event, so the acceleration this player was already written for was unreachable by the
        // one gesture everybody tries first.
        .background(
            PlayerHoldSeekGate(
                isEnabled: allowsHoldSeek,
                onBegan: beginHoldSeek,
                onEnded: endHoldSeek
            )
        )
        .onExitCommand {
            handleExitCommand()
        }
        // Escape from a keyboard is not the same event as Menu from a remote.  It never reaches
        // the press recognizer above — that one filters on `UIPress.PressType.menu`, and a key
        // is not a button — so it travelled on up and was read as a request to dismiss the
        // presentation, which from inside a track panel took the whole player down with it and
        // dropped the viewer back on the stream list.  Claiming it here puts the keyboard on the
        // same ordered chain as the remote, and returning `.handled` stops it going further.  A
        // press that arrives twice, once as a key and once as Menu, is absorbed by the echo
        // window in `PlayerExitPolicy` exactly as any other double delivery is.
        .onKeyPress(.escape) {
            handleExitCommand()
            return .handled
        }
        // Every other press is read here rather than inside the transport, for the same reason
        // Menu is: while the transport is down its buttons are out of the focus graph, so a
        // handler attached to them cannot be reached.  The sink holds focus instead, and these
        // two commands are what it forwards.
        .onPlayPauseCommand {
            perform(PlayerRemotePolicy.playPause(in: remoteState))
        }
        .onMoveCommand { direction in
            perform(PlayerRemotePolicy.move(direction.playerDirection, in: remoteState))
        }
        .task { start() }
        .onDisappear {
            hideTask?.cancel()
            scrubCommit?.cancel()
            holdSeek?.cancel()
            aspectFlashTask?.cancel()
            focusRetry?.cancel()
            persist(completed: false)
            engine.destroy()
            DisplayModeMatcher.restore(mode: settings.player.frameRateMatchingMode)
        }
        .onChange(of: engine.position) { _, position in
            onPlaybackTime(position, engine.duration)
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
            onPlaybackState(paused, isStalled)
        }
        // Derived, and reported from its initial value, because the events it replaces could
        // be missed entirely: mpv is started by the surface controller during the same body
        // evaluation that mounts this view, so a local file could reach its first frame before
        // `start()` ran — and the "Preparing stream" cover, set there, then had nothing left
        // to change and stayed up over a film that was already playing.
        .onChange(of: isStalled, initial: true) { _, stalled in
            onPlaybackState(engine.isPaused, stalled)
        }
        // Anything that covers the transport or uncovers it moves the remote's owner with it.
        .onChange(of: picker) { _, panel in
            if panel == nil { retargetFocus() } else { controlFocus = nil }
        }
        .onChange(of: showsPauseOverlay) { _, _ in retargetFocus() }
        .onChange(of: chromeState, initial: true) { _, state in onChromeChange(state) }
        .onChange(of: hasFocusableOverlay) { _, _ in retargetFocus() }
        .onChange(of: engine.errorMessage) { _, message in
            retargetFocus()
            // The host's "Preparing stream" cover is drawn above this view, so a source that
            // never opens sat behind a spinner that could not end. Reporting the stall as
            // finished is what lets mpv's own account of the failure be read.
            if message != nil { onPlaybackState(engine.isPaused, false) }
        }
        // Browsing the row is use, not idleness: restart the countdown as focus walks it.
        .onChange(of: controlFocus) { _, _ in
            guard isFocusInTransport else { return }
            scheduleHide()
        }
        // The panel can only be matched once the decoder has told us what it is decoding, which
        // is a little after playback starts rather than at load time.
        // Applying it live is the point: the layout is the setting a viewer is changing
        // precisely because they cannot hear anything, and making them leave playback to try
        // the next one turns a ten-second check into a chore.
        .onChange(of: audioChannels) { _, channels in
            engine.setAudioChannels(channels)
        }
        .onChange(of: engine.videoFormat) { _, format in
            guard let format else { return }
            DisplayModeMatcher.apply(format, mode: settings.player.frameRateMatchingMode)
        }
        .onChange(of: seekTarget) { _, target in
            guard let target else { return }
            engine.seek(to: target)
            onSeekApplied()
        }
        .onChange(of: pauseRequest) { _, request in
            guard let request else { return }
            engine.setPaused(request.paused)
            onPauseApplied()
        }
        .onChange(of: revealControlsRequest) { _, _ in wakeControls() }
        .onAppear {
            // One hop's grace so the buttons are in the focus system before it is aimed at them.
            retargetFocus()
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

    /// Silent video is otherwise indistinguishable from a file with no soundtrack, and a
    /// viewer has no way to tell which they are looking at. Naming it makes the difference —
    /// and names the one setting that can do something about it.
    private var audioDiagnostic: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
            Label(L10n.text("player.no_audio_device"), systemImage: "speaker.slash.fill")
                .nuvioText(NuvioTextStyles.cardTitle)
                .foregroundStyle(.white)
            Text(L10n.text("player.no_audio_device_detail"))
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(NuvioTheme.spacing.lg)
        .background(RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous).fill(.black.opacity(0.72)))
        .padding(.top, NuvioTheme.layout.tvSafeVertical)
        .padding(.leading, NuvioTheme.layout.tvSafeHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// mpv is started by `MPVMetalSurface`, which owns the layer it has to be handed. All that
    /// is left here is the addon subtitle tracks and the auto-hide timer.
    private func start() {
        // The viewer's default picture shape. `resize_mode` had been stored and synced since the
        // port began and applied nowhere, so every playback started in Fit whatever they chose.
        engine.setAspectMode(MPVEngine.AspectMode(resizeMode: settings.player.resizeMode))
        for subtitle in request.subtitles.prefix(8) {
            engine.addSubtitle(url: subtitle.url, title: subtitle.displayLanguage)
        }
        scheduleHide()
    }

    // MARK: Remote input

    /// Nothing has been drawn yet, or the picture has stopped for want of data. Either way the
    /// host's loading cover belongs on screen and playback has not really begun.
    private var isStalled: Bool { engine.isBuffering || !engine.hasRenderedFrame }

    /// What the host needs to know about this engine's own chrome.
    private var chromeState: PlayerChromeState {
        PlayerChromeState(controlsVisible: controlsInteractable, panelOpen: picker != nil)
    }

    /// The player's current shape, as the input rules need to see it.
    private var remoteState: PlayerRemotePolicy.State {
        PlayerRemotePolicy.State(
            hasError: engine.errorMessage != nil,
            hasOpenPanel: picker != nil,
            hasFocusableOverlay: hasFocusableOverlay,
            showsPauseCard: showsPauseOverlay,
            showsControls: showsControls
        )
    }

    /// Whether the transport is drawn *and* reachable. Being faded out is not the same as being
    /// gone: without this the buttons keep their place in the focus graph while invisible, and
    /// a Select over black opens a panel the viewer never asked for.
    private var controlsInteractable: Bool {
        PlayerRemotePolicy.controlsInteractable(remoteState)
    }

    /// The focus sink: a full-screen, invisible focus target that owns the remote whenever the
    /// transport is down.
    ///
    /// tvOS delivers directional input, Select and Play/Pause to the focused view and to
    /// nothing else. The instant the transport's buttons leave the focus graph something has to
    /// take their place, or focus lands nowhere and the remote goes dead until Menu is pressed —
    /// which is exactly the failure this replaces. A bare `Color`, not a Button: a Button draws
    /// a full-screen focus highlight over the picture, and dimming it to hide that also drops it
    /// out of the focus engine, so `up` produced no move command at all.
    ///
    /// It must also stay visible to accessibility. `accessibilityHidden(true)` reads like the
    /// right thing for an invisible helper and is not: on tvOS 26 it takes the view out of the
    /// focus system along with the accessibility tree, and the transport hides onto nothing —
    /// measured, with focus landing nowhere at all for the rest of the session.
    private var remoteSink: some View {
        Color.clear
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .focusable(PlayerRemotePolicy.focusOwner(remoteState) == .sink)
            .focused($controlFocus, equals: .sink)
            .prefersDefaultFocus(preferredFocus == .sink, in: playerFocus)
            .onTapGesture { perform(PlayerRemotePolicy.select(in: remoteState)) }
            .accessibilityIdentifier("player.remoteSink")
            .accessibilityLabel(L10n.text("player.reveal_controls"))
    }

    private func perform(_ action: PlayerRemoteAction) {
        switch action {
        case .none:
            break
        case .reveal:
            wakeControls()
        case .togglePause:
            engine.togglePause()
            wakeControls()
        case .resume:
            onDismissPrompt()
            engine.setPaused(false)
        case .seek(let forward):
            scrub(forward: forward)
        case .dismissPauseCard:
            onDismissPrompt()
            wakeControls()
        }
    }

    /// Aims focus at whatever should own the remote now, and keeps trying until it lands.
    ///
    /// A focus binding only takes if its target is already in the focus graph, and the write
    /// races the render that puts it there. Revealing the transport is the worst case in both
    /// directions at once: the sink leaves the graph in the same frame the buttons enter it,
    /// and a single write falls between the two. Measured, that left focus on a sink that was
    /// no longer focusable — the transport was on screen and the remote was dead, which is the
    /// original complaint wearing a different hat.
    ///
    /// So it retries, briefly, and stops the moment focus is genuinely inside the transport —
    /// including on a button the viewer moved to themselves, which must never be yanked back.
    private func retargetFocus(preferring target: ControlFocus = .playPause) {
        focusRetry?.cancel()
        applyFocusOwner(preferring: target)
        focusRetry = Task { @MainActor in
            for delay in [16, 120, 320, 650, 1000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, focusNeedsRepair else { return }
                applyFocusOwner(preferring: target)
            }
        }
    }

    /// Whether focus is somewhere it should not be, or nowhere at all.
    ///
    /// The second half is what `@FocusState` cannot answer. Read straight after a write it
    /// returns the value just written rather than what the focus engine did with it, which is
    /// exactly when the answer matters: a retry loop asking the binding whether its own write
    /// landed always hears yes, stops, and leaves the transport on screen with the remote dead.
    /// `FocusSystemProbe` asks UIKit instead.
    private var focusNeedsRepair: Bool {
        switch PlayerRemotePolicy.focusOwner(remoteState) {
        // A panel or one of the host's cards owns focus; the player is not entitled to an
        // opinion about where it sits.
        case .unmanaged: return false
        case .sink: return !FocusSystemProbe.hasFocusedItem || controlFocus != .sink
        case .transport, .progress: return !FocusSystemProbe.hasFocusedItem || controlFocus == .sink
        }
    }

    private var isFocusInTransport: Bool {
        switch controlFocus {
        case .playPause, .progress, .control: return true
        case .sink, nil: return false
        }
    }

    /// Two mechanisms, because one is not reliable on its own. The binding is precise but is
    /// silently declined when its target entered the focus graph in the same frame; the scope
    /// reset always re-runs an update but can only aim at whatever prefers default focus, which
    /// is what `preferredFocus` is for. Together they cover both halves of the race.
    private func applyFocusOwner(preferring target: ControlFocus) {
        let intended: ControlFocus?
        switch PlayerRemotePolicy.focusOwner(remoteState) {
        case .sink: intended = .sink
        case .transport: intended = target == .sink ? .playPause : target
        case .progress: intended = .progress
        // A panel, an error or one of the host's cards is up: it claims focus itself, and
        // taking it back here is what would strand the viewer inside it.
        case .unmanaged: intended = nil
        }
        controlFocus = intended
        guard let intended else { return }
        preferredFocus = intended
        resetFocus(in: playerFocus)
    }

    // MARK: Controls

    /// The Android control row, in its order: transport first, then the tools that change what
    /// is playing, then a chevron that reveals the occasional ones.  Elapsed/total sits at the
    /// trailing edge of the same row rather than under the bar, which is where it is on TV.
    private var controls: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
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
                if let name = request.streamName?.nilIfBlank {
                    Text(L10n.format("player.via", fallback: "via %@", name.replacingOccurrences(of: "\n", with: " · ")))
                        .nuvioText(NuvioTypography.bodyMedium)
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(2)
                }
            }

            progressBar

            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: NuvioTheme.spacing.xs) {
                    transportButtons
                }
                Spacer(minLength: NuvioTheme.spacing.lg)
                Text("\(timecode(displayPosition)) / \(timecode(engine.duration))")
                    .nuvioText(NuvioTypography.bodyMedium)
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()
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

    @ViewBuilder
    private var transportButtons: some View {
        controlButton(
            engine.isPaused ? "play.fill" : "pause.fill",
            label: engine.isPaused ? L10n.text("player.play") : L10n.text("player.pause"),
            focus: .playPause
        ) { engine.togglePause() }
        .prefersDefaultFocus(preferredFocus == .playPause, in: playerFocus)
        // The transport's home position, and what the UI tests watch to know whether a press
        // reached the player at all. Fixed rather than derived from the localised label.
        .accessibilityIdentifier("player.transport.playPause")

        if let onPlayNextEpisode {
            controlButton("forward.end.fill", label: L10n.text("player.next_episode"), focus: .control("next")) {
                onPlayNextEpisode()
            }
        }

        if !engine.subtitleTracks.isEmpty {
            controlButton("captions.bubble", label: L10n.text("player.subtitles"), focus: .control("subtitles")) { picker = .subtitles }
        }
        if !engine.audioTracks.isEmpty {
            controlButton("speaker.wave.2.fill", label: L10n.text("player.audio"), focus: .control("audio")) { picker = .audio }
        }
        if request.sourceRequest != nil {
            controlButton("arrow.left.arrow.right", label: L10n.text("player.sources"), focus: .control("sources")) { picker = .sources }
        }
        if let onSwitchEngine {
            controlButton("arrow.triangle.2.circlepath", label: L10n.text("player.switch_engine"), focus: .control("engine")) {
                onSwitchEngine()
            }
        }
        if onChooseEpisode != nil, request.contentType == "series" {
            controlButton("list.bullet", label: L10n.text("player.episodes"), focus: .control("episodes")) { picker = .episodes }
        }

        if showsMoreActions {
            controlButton("speedometer", label: L10n.text("player.speed"), focus: .control("speed")) { picker = .speed }
            controlButton("aspectratio", label: L10n.text("player.aspect_ratio"), focus: .control("aspect")) { cycleAspectMode() }
            if externalPlayerTarget != nil {
                controlButton("arrow.up.forward.app", label: L10n.text("player.open_external"), focus: .control("external")) {
                    handOffToExternalPlayer()
                }
            }
            controlButton("info.circle", label: L10n.text("player.stream_information"), focus: .control("info")) { picker = .streamInfo }
        }

        controlButton(
            showsMoreActions ? "chevron.left" : "chevron.right",
            label: showsMoreActions ? L10n.text("player.close_more_actions") : L10n.text("player.more_actions"),
            focus: .control("more")
        ) {
            withAnimation(NuvioMotion.quickTween) { showsMoreActions.toggle() }
        }
    }

    /// Android's progress bar is a focus target that seeks, not a read-out.  Reproducing that
    /// is what makes a remote without a touch surface able to move around a film at all: Left
    /// and Right scrub, Down returns to the buttons, Up dismisses the transport entirely.
    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(controlFocus == .progress ? 0.45 : 0.30))
                if bufferedFraction > fraction {
                    Capsule()
                        .fill(colors.secondary.opacity(0.35))
                        .frame(width: proxy.size.width * bufferedFraction)
                }
                Capsule()
                    .fill(colors.secondary)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: controlFocus == .progress ? NuvioTheme.spacing.md : NuvioTheme.spacing.sm)
        .animation(NuvioMotion.focusTween, value: controlFocus)
        .focusable(controlsInteractable)
        .focused($controlFocus, equals: .progress)
        .prefersDefaultFocus(preferredFocus == .progress, in: playerFocus)
        .onMoveCommand { direction in
            switch direction {
            case .left: scrub(forward: false)
            case .right: scrub(forward: true)
            case .up: hideControls()
            case .down:
                wakeControls()
                controlFocus = .playPause
            @unknown default: break
            }
        }
        .accessibilityLabel(L10n.text("player.progress"))
        .accessibilityValue(timecode(displayPosition))
    }

    /// While a scrub is pending the bar and the clock read the pending position, not mpv's —
    /// otherwise the picture the viewer is aiming at snaps back on every press.
    private var displayPosition: Double { scrubTarget ?? engine.position }

    private var fraction: Double {
        guard engine.duration > 0 else { return 0 }
        return min(1, max(0, displayPosition / engine.duration))
    }

    private var bufferedFraction: Double {
        guard engine.duration > 0 else { return 0 }
        return min(1, max(0, engine.bufferedPosition / engine.duration))
    }

    private func scrub(forward: Bool) {
        // Revealed by a seek, so focus belongs on the bar: the presses that follow continue the
        // scrub and pick up Android's acceleration instead of walking the button row.
        wakeControls(focusing: .progress)
        let now = Date()
        scrubRepeatCount = now.timeIntervalSince(lastScrubAt) <= PlayerScrubRates.repeatWindow
            ? scrubRepeatCount + 1
            : 0
        lastScrubAt = now

        let base = scrubTarget ?? engine.position
        let delta = PlayerScrubRates.delta(forRepeatCount: scrubRepeatCount, forward: forward)
        let upperBound = engine.duration > 0 ? engine.duration : base + delta
        scrubTarget = min(max(0, base + delta), max(0, upperBound))

        scrubCommit?.cancel()
        scrubCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let target = scrubTarget else { return }
            engine.seek(to: target)
            // Hold the pending position until mpv's clock has actually moved to it, otherwise
            // the bar jumps back to the pre-seek time for a frame.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            scrubTarget = nil
            scrubRepeatCount = 0
        }
    }

    /// Whether a held direction should seek.
    ///
    /// The same question `PlayerRemotePolicy` asks of a single press, minus the focus term: the
    /// gate reads the remote below SwiftUI's focus graph, so it works whether the transport is
    /// up or the picture is bare — which is the point of it. It stands down for anything that
    /// owns the remote in its own right, because a hold there belongs to that layer.
    private var allowsHoldSeek: Bool {
        engine.errorMessage == nil && picker == nil && !hasFocusableOverlay && !showsPauseOverlay
    }

    /// Repeats `scrub` for as long as the direction is held, which is what turns the existing
    /// acceleration table into a fast-forward: each tick counts as a repeat, so the step grows
    /// 10 → 20 → 30 → 60 seconds the longer the hold lasts.
    ///
    /// The interval is inside `PlayerScrubRates.repeatWindow` by design — a tick slower than
    /// that window reads as a fresh tap and resets the acceleration to its slowest step, so the
    /// hold would never speed up at all.
    private func beginHoldSeek(forward: Bool) {
        guard allowsHoldSeek else { return }
        holdSeek?.cancel()
        holdSeek = Task { @MainActor in
            while !Task.isCancelled {
                scrub(forward: forward)
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
    }

    /// Stops the ramp and leaves the pending seek alone: `scrub` commits it 300 ms after the
    /// last step, so letting go is what makes the picture move.
    private func endHoldSeek() {
        holdSeek?.cancel()
        holdSeek = nil
    }

    private func cycleAspectMode() {
        let mode = engine.aspectMode.next
        engine.setAspectMode(mode)
        aspectFlash = mode.label
        aspectFlashTask?.cancel()
        aspectFlashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(NuvioMotion.quickTween) { aspectFlash = nil }
        }
    }

    /// The player the hand-off button targets: the one chosen in Playback settings when it is
    /// installed, otherwise whatever is.  With none installed the button is not drawn at all —
    /// on Android it always resolves to something, here it can resolve to nothing.
    private var externalPlayerTarget: ExternalPlayer? {
        let installed = ExternalPlayerLauncher.installed
        if let preferred = ExternalPlayer(rawValue: settings.player.preferredExternalPlayer),
           installed.contains(preferred) {
            return preferred
        }
        return installed.first
    }

    private func handOffToExternalPlayer() {
        guard let target = externalPlayerTarget else { return }
        persist(completed: false)
        if ExternalPlayerLauncher.open(
            target,
            stream: request.streamURL,
            title: request.title,
            subtitleURL: settings.player.externalPlayerForwardSubtitles
                ? request.subtitles.first?.url : nil
        ) {
            dismiss()
        }
    }

    private func controlButton(
        _ systemImage: String,
        label: String,
        focus: ControlFocus,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            wakeControls()
            action()
        }) {
            Image(systemName: systemImage)
                .font(.system(size: dp(26), weight: .medium))
                .frame(width: NuvioTheme.spacing.xxxl, height: NuvioTheme.spacing.xxxl)
                .contentShape(Circle())
        }
        .buttonStyle(PlayerControlButtonStyle())
        .focused($controlFocus, equals: focus)
        // `disabled` rather than `focusable(false)`: on a Button the latter can leave the
        // control looking focused while Select no longer fires, whereas this simply takes it
        // out of the spatial focus graph. Appearance is unaffected — it is faded out anyway.
        .disabled(!controlsInteractable)
        .accessibilityLabel(label)
    }

    // MARK: Floating read-outs

    /// Android draws the wall clock and the projected end time top-right while the transport is
    /// up, so "how long is left" does not need arithmetic against the elapsed counter.
    @ViewBuilder
    private var clockOverlay: some View {
        // The pause card carries its own clock, so the two must never be up together — the
        // transport merely fades behind it, which is not the same as being gone.
        if settings.player.osdClockEnabled, showsControls, picker == nil,
           !showsPauseOverlay, engine.errorMessage == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .trailing, spacing: 0) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: sp(13), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                    Text(endsAtText(now: context.date))
                        .font(.system(size: sp(10)))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .padding(.trailing, dp(28))
            .padding(.top, NuvioTheme.spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .transition(.opacity)
        }
    }

    private func endsAtText(now: Date) -> String {
        guard engine.duration > 0 else {
            return L10n.format("player.ends_at", fallback: "Ends at %@", "--:--")
        }
        let speed = engine.playbackSpeed > 0 ? engine.playbackSpeed : 1
        let remaining = max(0, engine.duration - displayPosition) / speed
        let end = now.addingTimeInterval(remaining.rounded(.up))
        return L10n.format(
            "player.ends_at", fallback: "Ends at %@",
            end.formatted(date: .omitted, time: .shortened)
        )
    }

    @ViewBuilder
    private var aspectFlashPill: some View {
        if let aspectFlash {
            Text(aspectFlash)
                .nuvioText(NuvioTextStyles.button)
                .foregroundStyle(.white)
                .padding(.horizontal, NuvioTheme.spacing.lg)
                .padding(.vertical, NuvioTheme.spacing.sm)
                .background(Capsule().fill(.black.opacity(0.72)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: NuvioTheme.strokes.hairline))
                .padding(.top, dp(80))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func playerPanel(_ which: TrackPicker) -> some View {
        switch which {
        case .sources:
            InPlayerSourcesPanel(request: request, onDismiss: closePicker, handlesExit: false)
        case .episodes:
            if let onChooseEpisode {
                InPlayerEpisodesView(request: request, onDismiss: closePicker, onSelect: { episode in
                    closePicker()
                    onChooseEpisode(episode)
                }, handlesExit: false)
            }
        case .streamInfo:
            InPlayerPanel(
                title: L10n.text("player.stream_information"),
                focusCloseOnAppear: true,
                handlesExit: false,
                onDismiss: closePicker
            ) {
                streamInfoPanelContent
            }
        case .subtitleAppearance:
            subtitleAppearancePanel
        case .speed:
            speedDialog
        case .audio:
            audioOverlay
        case .subtitles:
            subtitleOverlay
        }
    }

    /// Android's audio chooser: the track list on the left, the controls that shape what that
    /// track sounds like on the right, both anchored bottom-left so the picture stays readable.
    private var audioOverlay: some View {
        PlayerRailOverlay(title: L10n.text("player.audio"), onDismiss: closePicker) {
            PlayerRailColumn(width: dp(444)) {
                if engine.audioTracks.isEmpty {
                    Text(L10n.text("player.audio_default_only"))
                        .nuvioText(NuvioTypography.bodyLarge)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.vertical, NuvioTheme.spacing.sm)
                }
                ForEach(Array(engine.audioTracks.enumerated()), id: \.element.id) { index, track in
                    PlayerRailCard(
                        title: track.displayName,
                        subtitle: MediaLanguage.named(track.language),
                        metadata: track.details.joined(separator: " · "),
                        isSelected: track.isSelected,
                        requestsInitialFocus: track.isSelected
                            || (index == 0 && !engine.audioTracks.contains(where: \.isSelected))
                    ) {
                        // The panel stays mounted while mpv changes the active stream: it only
                        // needs an `aid` command, and rebuilding the player here is what used
                        // to produce a visible black-frame flash.
                        engine.selectAudioTrack(track.id)
                    }
                }
            }

            PlayerRailColumn(width: dp(268)) {
                PlayerRailStepper(
                    title: L10n.text("player.audio_delay"),
                    value: delayLabel(engine.audioDelay),
                    helper: L10n.format(
                        "player.delay_range", fallback: "Range: %@ to %@",
                        delayLabel(-MPVEngine.audioDelayLimit), delayLabel(MPVEngine.audioDelayLimit)
                    ),
                    canDecrease: engine.audioDelay > -MPVEngine.audioDelayLimit,
                    canIncrease: engine.audioDelay < MPVEngine.audioDelayLimit,
                    requestsInitialFocus: engine.audioTracks.isEmpty,
                    onDecrease: { engine.adjustAudioDelay(by: -0.025) },
                    onIncrease: { engine.adjustAudioDelay(by: 0.025) }
                )

                PlayerRailStepper(
                    title: L10n.text("player.amplification"),
                    value: "\(engine.amplificationDb) dB",
                    helper: L10n.format(
                        "player.amplification_range", fallback: "Range: %d dB to %d dB",
                        0, MPVEngine.amplificationLimitDb
                    ),
                    canDecrease: engine.amplificationDb > 0,
                    canIncrease: engine.amplificationDb < MPVEngine.amplificationLimitDb,
                    onDecrease: { engine.setAmplification(db: engine.amplificationDb - 1) },
                    onIncrease: { engine.setAmplification(db: engine.amplificationDb + 1) }
                )
            }
        }
    }

    /// The subtitle chooser mirrors it: the tracks mpv holds — the file's own and every addon
    /// track loaded at startup — beside the timing and appearance controls for them.
    private var subtitleOverlay: some View {
        let hasSelection = engine.subtitleTracks.contains(where: \.isSelected)
        return PlayerRailOverlay(title: L10n.text("player.subtitles"), onDismiss: closePicker) {
            PlayerRailColumn(width: dp(444)) {
                PlayerRailCard(
                    title: L10n.text("player.off"),
                    isSelected: !hasSelection,
                    requestsInitialFocus: !hasSelection
                ) { engine.selectSubtitleTrack(nil) }

                ForEach(engine.subtitleTracks) { track in
                    PlayerRailCard(
                        title: track.displayName,
                        subtitle: MediaLanguage.named(track.language),
                        metadata: track.details.joined(separator: " · "),
                        isSelected: track.isSelected,
                        requestsInitialFocus: track.isSelected
                    ) { engine.selectSubtitleTrack(track.id) }
                }
            }

            PlayerRailColumn(width: dp(268)) {
                PlayerRailStepper(
                    title: L10n.text("player.subtitle_delay"),
                    value: delayLabel(engine.subtitleDelay),
                    helper: L10n.format(
                        "player.delay_range", fallback: "Range: %@ to %@",
                        delayLabel(-MPVEngine.subtitleDelayLimit), delayLabel(MPVEngine.subtitleDelayLimit)
                    ),
                    canDecrease: engine.subtitleDelay > -MPVEngine.subtitleDelayLimit,
                    canIncrease: engine.subtitleDelay < MPVEngine.subtitleDelayLimit,
                    onDecrease: { engine.adjustSubtitleDelay(by: -0.1) },
                    onIncrease: { engine.adjustSubtitleDelay(by: 0.1) }
                )

                PlayerRailCard(
                    title: L10n.text("player.subtitle_appearance"),
                    subtitle: L10n.text("player.subtitle_appearance_detail")
                ) { picker = .subtitleAppearance }

                PlayerRailCard(title: L10n.text("player.reset_subtitle_delay")) {
                    engine.setSubtitleDelay(0)
                }
            }
        }
    }

    /// Android keeps speed in a small centred dialog rather than a side panel, because the
    /// choice is one press and the picture behind it is what the viewer is judging.
    private var speedDialog: some View {
        PlayerCenteredDialog(title: L10n.text("player.speed"), onDismiss: closePicker) {
            ForEach(Self.playbackSpeeds, id: \.self) { speed in
                let isSelected = abs(engine.playbackSpeed - speed) < 0.01
                PlayerRailCard(
                    title: speed == 1
                        ? L10n.text("player.speed_normal")
                        : String(format: "%.2gx", speed),
                    isSelected: isSelected,
                    requestsInitialFocus: isSelected
                ) { engine.setPlaybackSpeed(speed) }
            }
        }
    }

    private static let playbackSpeeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    private var subtitleAppearancePanel: some View {
        @Bindable var player = settings.player
        return InPlayerPanel(
            title: L10n.text("player.subtitle_appearance"),
            subtitle: L10n.text("player.applies_immediately"),
            handlesExit: false,
            onDismiss: closePicker
        ) {
            InPlayerPanelSection(title: L10n.text("player.text_size")) {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { scale in
                    InPlayerPanelRow(
                        title: String(format: "%.0f%%", scale * 100),
                        systemImage: "textformat.size",
                        isSelected: abs(player.subtitleSize - scale) < 0.01,
                        requestsInitialFocus: abs(player.subtitleSize - scale) < 0.01
                    ) { player.subtitleSize = scale }
                }
            }
            InPlayerPanelSection(title: L10n.text("player.style")) {
                InPlayerPanelRow(
                    title: L10n.text("player.bold_text"), systemImage: "bold",
                    isSelected: player.subtitleBold
                ) { player.subtitleBold.toggle() }
                InPlayerPanelRow(
                    title: L10n.text("player.outline"), systemImage: "text.outline",
                    isSelected: player.subtitleOutlineEnabled
                ) { player.subtitleOutlineEnabled.toggle() }
            }
            InPlayerPanelSection(title: L10n.text("player.text_color")) {
                ForEach(subtitleColorChoices, id: \.hex) { choice in
                    InPlayerPanelRow(
                        title: choice.title, systemImage: "circle.fill",
                        isSelected: subtitleRGB(player.subtitleTextColor) == choice.hex,
                        requestsInitialFocus: subtitleRGB(player.subtitleTextColor) == choice.hex
                    ) { player.subtitleTextColor = subtitleColor(choice.hex, preservingAlphaFrom: player.subtitleTextColor) }
                }
            }
            InPlayerPanelSection(title: L10n.text("player.text_opacity")) {
                ForEach([50, 75, 100], id: \.self) { percent in
                    InPlayerPanelRow(
                        title: "\(percent)%", systemImage: "circle.lefthalf.filled",
                        isSelected: subtitleAlphaPercent(player.subtitleTextColor) == percent
                    ) { player.subtitleTextColor = subtitleColor(player.subtitleTextColor, alphaPercent: percent) }
                }
            }
            InPlayerPanelSection(title: L10n.text("player.position")) {
                ForEach([(L10n.text("player.bottom"), 0.0), (L10n.text("player.raised"), 30.0), (L10n.text("player.high"), 60.0)], id: \.0) { preset in
                    InPlayerPanelRow(
                        title: preset.0, systemImage: "arrow.up.and.down",
                        isSelected: abs(player.subtitleVerticalOffset - preset.1) < 0.1
                    ) { player.subtitleVerticalOffset = preset.1 }
                }
            }
            InPlayerPanelSection(title: nil) {
                InPlayerPanelRow(title: L10n.text("player.reset_subtitle_style"), systemImage: "arrow.counterclockwise") {
                    player.subtitleSize = SubtitleStyle.default.sizeScale
                    player.subtitleBold = SubtitleStyle.default.bold
                    player.subtitleTextColor = "#FFFFFFFF"
                    player.subtitleBackgroundColor = "#00000000"
                    player.subtitleOutlineEnabled = SubtitleStyle.default.outlineEnabled
                    player.subtitleOutlineColor = "#FF000000"
                    player.subtitleOutlineWidth = SubtitleStyle.default.outlineWidth
                    player.subtitleVerticalOffset = SubtitleStyle.default.verticalOffset
                }
            }
        }
    }

    private func closePicker() {
        picker = nil
        wakeControls()
        retargetFocus()
    }

    /// The whole meaning of Menu during playback, in one place — the port of Android's single
    /// `BackHandler` chain.  Splitting it across the panels is what let one press both close a
    /// panel and leave the player.
    private func handleExitCommand() {
        let now = Date()
        let action = PlayerExitPolicy.action(
            for: PlayerExitPolicy.State(
                hasError: engine.errorMessage != nil,
                hasOpenPanel: picker != nil,
                hasOpenPrompt: hasOpenPrompt,
                showsMoreActions: showsMoreActions,
                showsControls: showsControls
            ),
            sinceLastHandledPress: now.timeIntervalSince(lastHandledExit)
        )
        guard action != .ignore else { return }
        lastHandledExit = now

        switch action {
        case .ignore: break
        case .closePanel: closePicker()
        case .closePrompt: onDismissPrompt()
        case .closeMoreActions: withAnimation(NuvioMotion.quickTween) { showsMoreActions = false }
        case .hideControls: hideControls()
        case .dismissPlayback: dismiss()
        }
    }

    private var subtitleColorChoices: [(title: String, hex: String)] {
        [
            (L10n.text("player.color_white"), "FFFFFF"),
            (L10n.text("player.color_yellow"), "FFD700"),
            (L10n.text("player.color_cyan"), "00E5FF"),
            (L10n.text("player.color_green"), "00FF88")
        ]
    }

    private func subtitleRGB(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "#", with: "").uppercased()
        return cleaned.count == 8 ? String(cleaned.suffix(6)) : cleaned
    }

    private func subtitleAlphaPercent(_ value: String) -> Int {
        let cleaned = value.replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 8, let alpha = Int(cleaned.prefix(2), radix: 16) else { return 100 }
        return Int((Double(alpha) / 255 * 100).rounded())
    }

    private func subtitleColor(_ rgb: String, preservingAlphaFrom current: String) -> String {
        let cleaned = current.replacingOccurrences(of: "#", with: "")
        let alpha = cleaned.count == 8 ? String(cleaned.prefix(2)) : "FF"
        return "#\(alpha)\(subtitleRGB(rgb))"
    }

    private func subtitleColor(_ current: String, alphaPercent: Int) -> String {
        let alpha = String(format: "%02X", Int((Double(alphaPercent) / 100 * 255).rounded()))
        return "#\(alpha)\(subtitleRGB(current))"
    }

    private func delayLabel(_ delay: Double) -> String {
        delay == 0 ? "0.000s" : String(format: "%+.3fs", delay)
    }

    private var streamInfoPanelContent: some View {
        Group {
            InPlayerPanelSection(title: "Source") {
                if let addon = request.sourceAddonName?.nilIfBlank { InPlayerInfoRow(title: "Addon", value: addon) }
                InPlayerInfoRow(title: "Player", value: "MPV")
                if let name = request.streamName?.nilIfBlank { InPlayerInfoRow(title: "Stream", value: name) }
                if let filename = request.filename?.nilIfBlank { InPlayerInfoRow(title: "File", value: filename) }
                if !request.sourceHints.isEmpty { InPlayerInfoRow(title: "Sources", value: request.sourceHints.joined(separator: " · ")) }
            }

            InPlayerPanelSection(title: "Video") {
                infoRow("Codec", engine.streamInfo.videoCodec)
                infoRow("Resolution", engine.streamInfo.resolution)
                infoRow("Frame rate", engine.streamInfo.frameRate)
                InPlayerInfoRow(title: "Display", value: engine.aspectMode.label)
            }

            InPlayerPanelSection(title: "Audio & subtitles") {
                infoRow("Codec", engine.streamInfo.audioCodec)
                infoRow("Channels", engine.streamInfo.audioChannels)
                infoRow("Output", engine.streamInfo.audioOutput)
                InPlayerInfoRow(title: "Audio delay", value: delayLabel(engine.audioDelay))
                InPlayerInfoRow(title: "Subtitle delay", value: delayLabel(engine.subtitleDelay))
            }

            if !engine.logTail.isEmpty {
                InPlayerPanelSection(title: "Recent player log") {
                    Text(engine.logTail.suffix(6).joined(separator: "\n"))
                        .font(.system(size: sp(10), design: .monospaced))
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(6)
                        .padding(NuvioTheme.spacing.md)
                }
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ title: String, _ value: String?) -> some View {
        if let value = value?.nilIfBlank {
            InPlayerInfoRow(title: title, value: value)
        }
    }

    // MARK: Overlay timing

    private func hideControls() {
        hideTask?.cancel()
        scrubCommit?.cancel()
        scrubTarget = nil
        withAnimation(NuvioMotion.quickTween) { showsControls = false }
        retargetFocus()
    }

    /// Brings the transport back and hands it the remote. The focus handoff only happens on the
    /// way up from a hidden transport: called from a button's own action — every one of them
    /// does, to restart the countdown — it must leave focus exactly where the viewer put it.
    private func wakeControls(focusing target: ControlFocus = .playPause) {
        let wasDown = !controlsInteractable
        withAnimation(NuvioMotion.quickTween) { showsControls = true }
        scheduleHide()
        guard wasDown else { return }
        retargetFocus(preferring: target)
    }

    /// Controls stay up while paused — that is when the viewer is looking at them — and while a
    /// panel is open, which draws over them and would otherwise leave nothing to come back to.
    private func scheduleHide() {
        hideTask?.cancel()
        guard !engine.isPaused, picker == nil else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !engine.isPaused else { return }
            hideControls()
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

private extension MoveCommandDirection {
    var playerDirection: PlayerRemoteDirection {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        // A direction this build does not know about still means "the viewer touched the
        // remote", and revealing the transport is the answer to that.
        @unknown default: return .down
        }
    }
}

// MARK: - Transport chrome

/// Android's `ControlButton`: a circular icon that inverts to a white disc with a black glyph
/// when it takes focus.  `NuvioRowButtonStyle` tints and lifts instead, which is right on a
/// settings row and wrong over a moving picture, where the only reliable contrast is the disc.
private struct PlayerControlButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? .black : .white)
            .background(Circle().fill(isFocused ? Color.white : .clear))
            .animation(NuvioMotion.focusTween, value: isFocused)
    }
}

/// The small centred dialog Android uses for playback speed.
struct PlayerCenteredDialog<Content: View>: View {
    @Environment(\.nuvioColors) private var colors

    let title: String
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
                Text(title)
                    .nuvioText(NuvioTypography.headlineLarge)
                    .foregroundStyle(colors.textPrimary)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                        content()
                    }
                }
                .scrollClipDisabled()
                .frame(maxHeight: dp(420))
            }
            .padding(NuvioTheme.spacing.xl)
            .frame(width: dp(300), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: NuvioTheme.radii.xl, style: .continuous)
                    .fill(colors.backgroundElevated)
            )
        }
        .focusSection()
    }
}

// MARK: - Menu ownership

/// Claims the Menu button for the whole presented player.
///
/// tvOS delivers Menu up the responder chain from whatever is focused, and a `fullScreenCover`
/// installs its own dismissal at the presentation root.  Every moment where focus is between
/// two subtrees — the frame after a side panel unmounts, for instance — is a moment where that
/// root handler sees the press instead of the player, and playback is torn down mid-panel.  A
/// press gesture recognizer on the presented controller's own view sits above the chain, so the
/// answer to "what does Menu mean right now" is decided in exactly one place.
private struct MenuPressGate: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = GateView()
        view.isUserInteractionEnabled = false
        view.onMenu = { context.coordinator.action() }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }

    /// A zero-size view whose only job is to find the hosting controller and hang the
    /// recognizer off it. It attaches on the way into the window and takes the recognizer with
    /// it on the way out, so the gate cannot outlive the presentation it belongs to.
    private final class GateView: UIView {
        var onMenu: (() -> Void)?
        private weak var host: UIView?
        private var recognizer: UITapGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                detach()
                return
            }
            attach()
        }

        private func attach() {
            guard recognizer == nil, let host = hostingControllerView else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
            tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            host.addGestureRecognizer(tap)
            self.host = host
            recognizer = tap
        }

        private func detach() {
            if let recognizer { host?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            host = nil
        }

        private var hostingControllerView: UIView? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController { return controller.viewIfLoaded }
                responder = current.next
            }
            return nil
        }

        @objc private func menuPressed() {
            onMenu?()
        }

        deinit {
            // `deinit` can run off the main actor; the recognizer must be released on it.
            guard let recognizer, let host else { return }
            Task { @MainActor in host.removeGestureRecognizer(recognizer) }
        }
    }
}

// MARK: - Held-direction seeking

/// Turns a held Left or Right on the remote into a continuous seek.
///
/// tvOS has no equivalent of Android's `KeyEvent.repeatCount`: a held direction produces one
/// move command and then silence, so the acceleration table this player was written around
/// could only be reached by tapping quickly, and holding — the gesture everyone reaches for —
/// did nothing. Press gesture recognizers are the only place the platform exposes the button
/// still being down, and they sit outside the focus graph, so this works whether the transport
/// has focus or the picture is bare.
///
/// One recognizer per direction, because `allowedPressTypes` is a filter and not something the
/// callback can read back. It attaches to the hosting controller's own view for the same reason
/// `MenuPressGate` does, and leaves with it.
private struct PlayerHoldSeekGate: UIViewRepresentable {
    /// False while something else owns the remote — a panel, an error, a card drawn over
    /// playback. The recognizers stay attached and stand down, rather than being torn off and
    /// rebuilt every time a panel opens.
    let isEnabled: Bool
    let onBegan: (Bool) -> Void
    let onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = GateView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onBegan = onBegan
        context.coordinator.onEnded = onEnded
        // A gate that goes inert mid-hold has to end the ramp it started, or the seek runs on
        // with nothing left to stop it.
        if !isEnabled { context.coordinator.cancelIfHolding() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onBegan: onBegan, onEnded: onEnded)
    }

    @MainActor
    final class Coordinator: NSObject {
        var isEnabled: Bool
        var onBegan: (Bool) -> Void
        var onEnded: () -> Void
        private var isHolding = false

        init(isEnabled: Bool, onBegan: @escaping (Bool) -> Void, onEnded: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onBegan = onBegan
            self.onEnded = onEnded
            super.init()
        }

        func cancelIfHolding() {
            guard isHolding else { return }
            isHolding = false
            onEnded()
        }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            let forward = recognizer.allowedPressTypes
                .contains(NSNumber(value: UIPress.PressType.rightArrow.rawValue))
            switch recognizer.state {
            case .began:
                guard isEnabled else { return }
                isHolding = true
                onBegan(forward)
            case .ended, .cancelled, .failed:
                cancelIfHolding()
            default:
                break
            }
        }
    }

    /// A zero-size view that finds the hosting controller and hangs the recognizers off it,
    /// taking them with it on the way out — the same lifetime `MenuPressGate` uses.
    private final class GateView: UIView {
        weak var coordinator: Coordinator?
        private weak var host: UIView?
        private var recognizers: [UILongPressGestureRecognizer] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                detach()
                return
            }
            attach()
        }

        private func attach() {
            guard recognizers.isEmpty, let host = hostingControllerView, let coordinator else { return }
            for pressType in [UIPress.PressType.leftArrow, .rightArrow] {
                let hold = UILongPressGestureRecognizer(
                    target: coordinator, action: #selector(Coordinator.held(_:))
                )
                hold.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
                // Long enough that a single click still reads as one ten-second step and never
                // as the start of a scan, short enough that a deliberate hold responds at once.
                hold.minimumPressDuration = 0.4
                host.addGestureRecognizer(hold)
                recognizers.append(hold)
            }
            self.host = host
        }

        private func detach() {
            coordinator?.cancelIfHolding()
            for recognizer in recognizers { host?.removeGestureRecognizer(recognizer) }
            recognizers = []
            host = nil
        }

        private var hostingControllerView: UIView? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController { return controller.viewIfLoaded }
                responder = current.next
            }
            return nil
        }

        deinit {
            // `deinit` can run off the main actor; the recognizers must be released on it.
            guard !recognizers.isEmpty, let host else { return }
            let held = recognizers
            Task { @MainActor in
                for recognizer in held { host.removeGestureRecognizer(recognizer) }
            }
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
    let audioLanguages: [String]
    let subtitleLanguages: [String]
    let subtitleStyle: SubtitleStyle

    func makeUIViewController(context: Context) -> MPVMetalViewController {
        MPVMetalViewController(
            engine: engine, request: request, resumeAt: resumeAt,
            verboseLogging: verboseLogging, hardwareDecoding: hardwareDecoding,
            audioOutput: audioOutput, audioChannels: audioChannels,
            audioLanguages: audioLanguages, subtitleLanguages: subtitleLanguages,
            subtitleStyle: subtitleStyle
        )
    }

    func updateUIViewController(_ controller: MPVMetalViewController, context: Context) {
        controller.applySubtitleStyle(subtitleStyle)
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
    private let audioLanguages: [String]
    private let subtitleLanguages: [String]
    private let subtitleStyle: SubtitleStyle

    private let metalLayer = MPVMetalLayer()
    private var lastDrawableSize: CGSize = .zero
    private var appliedSubtitleStyle: SubtitleStyle?

    init(
        engine: MPVEngine,
        request: PlaybackRequest,
        resumeAt: Double,
        verboseLogging: Bool,
        hardwareDecoding: MpvHardwareDecodeMode,
        audioOutput: MpvAudioOutput,
        audioChannels: AudioOutputChannels,
        audioLanguages: [String],
        subtitleLanguages: [String],
        subtitleStyle: SubtitleStyle
    ) {
        self.engine = engine
        self.request = request
        self.resumeAt = resumeAt
        self.verboseLogging = verboseLogging
        self.hardwareDecoding = hardwareDecoding
        self.audioOutput = audioOutput
        self.audioChannels = audioChannels
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.subtitleStyle = subtitleStyle
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
            audioLanguages: audioLanguages,
            subtitleLanguages: subtitleLanguages,
            subtitleStyle: subtitleStyle,
            layer: metalLayer
        )
        appliedSubtitleStyle = subtitleStyle
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        guard appliedSubtitleStyle != style else { return }
        appliedSubtitleStyle = style
        engine.applySubtitleStyle(style)
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
