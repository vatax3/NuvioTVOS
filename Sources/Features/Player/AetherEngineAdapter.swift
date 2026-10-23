#if canImport(PlayerEngineKit)
import AVFoundation
import Combine
import Foundation
import Observation
import QuartzCore
import PlayerEngineKit
import os

/// `AetherEngine` in the shape `PlayerChrome` asks for.
///
/// Three translations, and each one is the reason this type exists rather than a conformance on the
/// engine itself.
///
/// **Observation.** AetherEngine is a Combine `ObservableObject`; our chrome is `@Observable`. Mixing
/// the two in one view tree means a SwiftUI view that re-renders on `objectWillChange` for the whole
/// engine, which is exactly what AetherEngine's own documentation warns about: its clock ticks ~10 Hz
/// and would rebuild an open `Menu` mid-interaction on tvOS. So the published values are mirrored
/// into observed storage here, and the clock is sampled rather than followed.
///
/// **Vocabulary.** The chrome asks what mpv taught it to ask — `isBuffering`, `didEnd`,
/// `errorMessage`. AetherEngine answers with `playbackPhase`, `state` and `errorInfo`, which are
/// better questions. Translating in one place beats teaching the chrome both dialects.
///
/// **Honest refusals.** Three members have no counterpart and are not faked: amplification, the
/// centre mix level, and the colorimetry handshake. They report a limit of zero or nil, which is
/// what makes the chrome draw them inert instead of offering a control the engine will ignore.
@Observable
@MainActor
final class AetherEngineAdapter {
    @ObservationIgnored let engine: AetherEngine
    @ObservationIgnored private var sinks: Set<AnyCancellable> = []
    @ObservationIgnored private let log = Logger(subsystem: "com.nuvio.tvos", category: "Aether")
    /// Mirrors `MPVEngine`'s 4 Hz discipline. The engine publishes position at about 10 Hz, and
    /// every sample that reaches observed storage invalidates the player tree on the main actor.
    @ObservationIgnored private var lastPositionPublication = CACurrentMediaTime()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The addon tracks declared in `LoadOptions`. The chrome adds its tracks again once playback
    /// starts — mpv's `sub-add` has nothing to attach to any earlier, so that is where it belongs
    /// — and on this engine they are already listed, so the repeat is refused here.
    @ObservationIgnored private var declaredSubtitleURLs: Set<String> = []
    /// Which track each list has selected, remembered rather than read back from the engine at the
    /// moment a list arrives: the two are published independently and in either order.
    @ObservationIgnored private var activeAudioTrackID: Int64?
    @ObservationIgnored private var activeSubtitleTrackID: Int64?

    // MARK: Mirrored state

    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var bufferedPosition: Double = 0
    private(set) var didEnd = false
    private(set) var errorMessage: String?
    private(set) var hasRenderedFrame = false
    private(set) var logTail: [String] = []
    private(set) var audioTracks: [PlayerTrack] = []
    private(set) var subtitleTracks: [PlayerTrack] = []
    private(set) var playbackSpeed: Double = 1
    private(set) var audioDelay: Double = 0
    private(set) var subtitleDelay: Double = 0
    private(set) var aspectMode: PlayerAspectMode = .fit
    private(set) var streamInfo = PlayerStreamInfo()
    /// The cues the host draws, converted to our own cue type on the way in: the overlay that
    /// renders them is the one already written for the AVFoundation path, and two cue types in one
    /// view tree would mean two renderers.
    private(set) var cues: [SubtitleCue] = []
    /// What `errorInfo` said about the failure now on `errorMessage`, kept because the kind is the
    /// half that survives a locale and a release — the message is AVFoundation's, in the device's
    /// language, and is a payload rather than a key.
    private(set) var failureKind: PlaybackErrorKind?

    /// Style and obstructions arrive through `applySubtitleStyle`, because that is how the chrome
    /// says them, and are read by the surface that draws the cues.
    private(set) var subtitleStyle = SubtitleStyle()
    private(set) var subtitleObstructions = SubtitlePlacement.Obstructions()

    /// Failable because the engine's own `init` throws, and a host that cannot build one has
    /// nothing to show: the shim above falls back rather than mounting a dead surface.
    init?() {
        guard let engine = try? AetherEngine() else { return nil }
        self.engine = engine
        observe()
    }

    // MARK: Lifecycle

    /// Starts a session. Separate from `init` and absent from `PlayerEngineSurface` because this is
    /// where engines differ most: mpv wants a `CAMetalLayer` and twelve decode options, this wants
    /// `LoadOptions`, and several of those options are read *inside* `load` and cannot be set after.
    func start(
        url: URL,
        headers: [String: String],
        startAt: Double,
        audioLanguages: [String],
        subtitleLanguages: [String],
        externalSubtitles: [ExternalSubtitleTrack],
        matchesContent: Bool,
        initialAspectMode: PlayerAspectMode,
        subtitleStyle: SubtitleStyle
    ) {
        guard loadTask == nil else { return }
        self.subtitleStyle = subtitleStyle
        setAspectMode(initialAspectMode)

        var options = LoadOptions()
        options.httpHeaders = headers
        options.preferredAudioLanguages = audioLanguages
        options.preferredSubtitleLanguages = subtitleLanguages
        // Addon tracks are declared at load rather than added afterwards: a track registered later
        // is overlay-only, where a declared one also joins the native renditions and so survives
        // AirPlay and an external display.
        options.externalSubtitles = externalSubtitles
        declaredSubtitleURLs = Set(externalSubtitles.map(\.url.absoluteString))
        // The engine runs the display-criteria handshake synchronously inside `load`, and wants to
        // be its sole writer. `DisplayModeMatcher` is therefore not called on this path at all.
        options.matchContentEnabled = matchesContent
        options.panelIsInHDRMode = AetherEngine.displayCapabilities.supportsHDR
        options.panelPresentsDolbyVision = AetherEngine.displayCapabilities.supportsDolbyVision
        // The whole reason this engine is here: keep TrueHD Atmos objects and DTS:X heights instead
        // of letting them fall through to the bridge, which would re-encode a 7.1.4 mix to EAC3 5.1.
        // 7.1.4 is the bed the objects are rendered into; tvOS folds it to what the receiver
        // actually drives and delivers it as Dolby MAT. Without this a TrueHD Atmos track falls
        // through to the bridge and arrives as EAC3 5.1 with its heights re-encoded away.
        options.objectAudioRendering = .apac(.l714)
        // Confirms E-AC-3 JOC in the background and republishes the tracks, so the panel can say
        // "Atmos" because a decoder said so rather than because a filename did. Off the start path.
        options.confirmAtmos = true
        // AVKit is not hosting this picture, so nothing else will claim Now Playing for it.
        engine.ownsVideoNowPlayingSession = true
        engine.logTag = "nuvio"
        // Nothing else in this app plays audio — no UI sounds, no TTS, no AVAudioEngine of its own
        // — so the session is ours to release. It matters most on exactly the route this engine is
        // here for: on an E-AC-3 / Atmos bitstream passthrough the sink can keep looping the last
        // MAT frame after the player is gone unless someone releases the session. The engine does
        // it on a genuine final teardown only, never on a reload or a track switch.
        engine.deactivatesAudioSessionOnStop = true

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.load(url: url, startPosition: startAt > 1 ? startAt : nil, options: options)
            } catch is CancellationError {
                // Not a playback failure. Every zap, next-episode call and `stop()` during a load
                // throws this, and a host that reports it turns its own navigation into an error —
                // which on our cascade would hand the stream to another engine on a button press.
                return
            } catch {
                errorMessage = error.localizedDescription
                failureKind = engine.errorInfo?.kind
            }
        }
    }

    // MARK: Mirroring

    private func observe() {
        engine.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.absorb(state) }
            .store(in: &sinks)
        engine.$playbackPhase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.absorb(phase) }
            .store(in: &sinks)
        engine.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.duration = $0 }
            .store(in: &sinks)
        engine.$hasFirstFrameReadyForDisplay
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.hasRenderedFrame = $0 }
            .store(in: &sinks)
        // Four subscriptions for two lists, because on this engine the list and the selection are
        // two independent publishers. The engine switches track by mutating `activeAudioTrackIndex`
        // / `activeSubtitleTrackIndex` and leaves the arrays alone, so a flag derived inside the
        // array's own observer is a snapshot taken before any selection is resolved — and stays
        // frozen afterwards. Which is what left *Off* checked with a subtitle on screen, and the
        // audio list with no checkmark at all whenever a switch did not happen to rebuild it.
        engine.$audioTracks
            .receive(on: RunLoop.main)
            .sink { [weak self] tracks in
                guard let self else { return }
                audioTracks = tracks.map { PlayerTrack($0) }.marking(selected: activeAudioTrackID)
                refreshStreamInfo()
            }
            .store(in: &sinks)
        engine.$activeAudioTrackIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] index in
                guard let self else { return }
                activeAudioTrackID = index.map(Int64.init)
                audioTracks = audioTracks.marking(selected: activeAudioTrackID)
                // The panel names the active track's codec and channel count, so it moves with the
                // selection rather than only with the list.
                refreshStreamInfo()
            }
            .store(in: &sinks)
        engine.$subtitleTracks
            .receive(on: RunLoop.main)
            .sink { [weak self] tracks in
                guard let self else { return }
                subtitleTracks = tracks.map { PlayerTrack($0) }.marking(selected: activeSubtitleTrackID)
            }
            .store(in: &sinks)
        engine.$activeSubtitleTrackIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] index in
                guard let self else { return }
                activeSubtitleTrackID = index.map(Int64.init)
                subtitleTracks = subtitleTracks.marking(selected: activeSubtitleTrackID)
            }
            .store(in: &sinks)
        engine.$subtitleCues
            .receive(on: RunLoop.main)
            .sink { [weak self] published in
                // Bitmap cues (PGS, DVB) carry no text and are dropped rather than drawn blank.
                // Keeping them would need the overlay to render images, which is its own change.
                self?.cues = published.compactMap { cue in
                    cue.text?.nilIfBlank.map { SubtitleCue(start: cue.startTime, end: cue.endTime, text: $0) }
                }
            }
            .store(in: &sinks)
        engine.clock.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.publishPositionIfNeeded($0) }
            .store(in: &sinks)
        engine.clock.$bufferedPosition
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.bufferedPosition = $0 }
            .store(in: &sinks)
        engine.$audioDelivery
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStreamInfo() }
            .store(in: &sinks)
        engine.$sourceVideoStreamFormat
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStreamInfo() }
            .store(in: &sinks)
        // The route can move mid-session — a native session AVPlayer refuses is rebuilt on the
        // software path — so the panel follows it rather than reading it once at the load.
        engine.$videoRoute
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStreamInfo() }
            .store(in: &sinks)

        // Fires from whatever thread emitted the line — demuxer, producer, local server — so it is
        // hopped onto the main actor before it reaches observed storage.
        EngineLog.handler = { [weak self] line in
            Task { @MainActor [weak self] in
                guard let self else { return }
                logTail.append(line)
                if logTail.count > 200 { logTail.removeFirst(logTail.count - 200) }
            }
        }
    }

    private func absorb(_ state: PlaybackState) {
        switch state {
        case .paused: isPaused = true
        case .playing, .seeking: isPaused = false
        default: break
        }
        didEnd = state == .ended
        if case .error(let message) = state {
            errorMessage = message
            failureKind = engine.errorInfo?.kind
        } else if !didEnd {
            errorMessage = nil
            failureKind = nil
        }
    }

    private func absorb(_ phase: PlaybackPhase) {
        // `playbackPhase` is the one signal that tracks motion: `state` turns `.playing` the moment
        // the engine called `play()`, which on a slow start is seconds before the picture moves.
        switch phase {
        case .loading, .rebuffering, .stalled: isBuffering = true
        default: isBuffering = false
        }
    }

    private func publishPositionIfNeeded(_ value: Double) {
        let now = CACurrentMediaTime()
        let isDiscontinuity = value < position || abs(value - position) > 1.25
        guard isDiscontinuity || now - lastPositionPublication >= 0.25 else { return }
        lastPositionPublication = now
        position = value
    }

    private func refreshStreamInfo() {
        let format = engine.sourceVideoStreamFormat
        let active = engine.audioTracks.first { Int64($0.id) == activeAudioTrackID }
        streamInfo = PlayerStreamInfo(
            videoCodec: engine.sourceVideoCodecName,
            resolution: engine.sourceVideoWidth > 0
                ? "\(engine.sourceVideoWidth)×\(engine.sourceVideoHeight)" : nil,
            frameRate: engine.sourceVideoFrameRate.map { String(format: "%.3f fps", $0) },
            sourceRange: [format?.colorPrimariesLabel, format?.transferLabel]
                .compactMap { $0 }.joined(separator: " · ").nilIfBlank,
            // Nothing is tone-mapped on this engine: the source colorimetry reaches the panel, or
            // AVFoundation refused the master and the session is on another route. Repeating the
            // source is the honest answer, and it is what makes the two lines agree in the panel.
            outputRange: engine.videoFormat.label,
            audioCodec: active.map { $0.isAtmos ? "\($0.codec) · Atmos" : $0.codec },
            audioChannels: active.map { "\($0.channels) ch" },
            audioOutput: engine.audioDelivery.label,
            pipeline: engine.videoRoute.label
        )
    }
}

// MARK: - The chrome's contract

extension AetherEngineAdapter: PlayerEngineSurface {
    static var label: String { "Aether" }

    /// AetherEngine clamps lip-sync correction at ±2 s and keeps the value across the rebuilds a
    /// session makes on its own.
    static var audioDelayLimit: Double { 2 }
    /// The host draws the cues on this engine, so the shift is ours to apply and ours to bound.
    /// Matched to mpv's so the control behaves the same on both.
    static var subtitleDelayLimit: Double { 60 }
    /// No post-decode gain exists here: `volume` stops at unity, and an engine that cannot amplify
    /// should not be asked to. Zero makes the chrome's stepper inert rather than inert-looking.
    static var amplificationLimitDb: Int { 0 }

    var amplificationDb: Int { 0 }

    /// A source that carries audio but is playing video-only, which is the one degradation a viewer
    /// cannot otherwise tell from a film with no soundtrack.
    var isSilentlyFallingBack: Bool { engine.audioDelivery == .droppedNoPipeline }

    /// The display handshake belongs to the engine on this path, so there is nothing to hand to
    /// `DisplayModeMatcher` — and handing it something would make two writers of one panel mode.
    var videoFormat: DisplayModeMatcher.VideoFormat? { nil }

    var failureInvitesAnotherEngine: Bool {
        guard let failureKind else { return true }
        // A refusal, a meter, or a trust decision: another engine opens a second connection to be
        // told the same thing, and on a connection-capped account that is worse than an error.
        return ![.sourceRefused, .sourceRateLimited, .sourceCertificateRejected].contains(failureKind)
    }

    func liveStats() -> PlayerLiveStats {
        let telemetry = engine.diagnostics.liveTelemetry
        return PlayerLiveStats(
            bufferSeconds: max(0, bufferedPosition - position),
            networkBitsPerSecond: telemetry?.instantBitrateMbps.map { $0 * 1_000_000 },
            streamBitsPerSecond: engine.sourceVideoBitrate > 0 ? Double(engine.sourceVideoBitrate) : nil
        )
    }

    func togglePause() { engine.togglePlayPause() }

    func setPaused(_ paused: Bool) { paused ? engine.pause() : engine.play() }

    func seek(by seconds: Double) { seek(to: position + seconds) }

    func seek(to seconds: Double) {
        Task { await engine.seek(to: max(0, seconds)) }
    }

    func selectAudioTrack(_ id: Int64) { engine.selectAudioTrack(index: Int(id)) }

    func selectSubtitleTrack(_ id: Int64?) {
        guard let id else { return engine.clearSubtitle() }
        engine.selectSubtitleTrack(index: Int(id))
    }

    func addSubtitle(url: String, title: String) {
        // Only reached for a track the viewer picked mid-session; the ones known at load are
        // declared in `LoadOptions.externalSubtitles`, where they also become native renditions.
        guard let parsed = URL(string: url), declaredSubtitleURLs.insert(parsed.absoluteString).inserted else {
            return
        }
        _ = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: parsed, name: title))
    }

    func setPlaybackSpeed(_ speed: Double) {
        let clamped = min(Double(engine.maxSupportedRate), max(0.25, speed))
        playbackSpeed = clamped
        engine.setRate(Float(clamped))
    }

    func adjustAudioDelay(by seconds: Double) { setAudioDelay(audioDelay + seconds) }

    func setAudioDelay(_ seconds: Double) {
        let clamped = min(Self.audioDelayLimit, max(-Self.audioDelayLimit, seconds))
        audioDelay = clamped
        // Not free the way a rate change is: audio already fetched is committed to the old offset,
        // so the engine re-anchors at the playhead. Roughly 0.3 s of held picture on the loopback
        // route, position preserved.
        engine.setAudioDelay(clamped)
    }

    func adjustSubtitleDelay(by seconds: Double) { setSubtitleDelay(subtitleDelay + seconds) }

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = min(Self.subtitleDelayLimit, max(-Self.subtitleDelayLimit, seconds))
    }

    /// The layout is AVFoundation's to negotiate on this engine, and with tvOS's Continuous Audio
    /// Connection on, every HDMI route reports 32 unlabelled channels whatever the sink takes — so
    /// an eARC soundbar and a legacy-ARC one are indistinguishable from here. Choosing for the
    /// viewer on that basis is how a 7.1 pick plays stereo, so nothing is chosen.
    func setAudioChannels(_ channels: AudioOutputChannels) {
        log.debug("audio-channels is AVFoundation's on this engine; \(channels.rawValue, privacy: .public) not applied")
    }

    func setAmplification(db: Int) {
        guard db != 0 else { return }
        log.debug("no post-decode amplification on this engine; \(db, privacy: .public) dB not applied")
    }

    func setAspectMode(_ mode: PlayerAspectMode) {
        aspectMode = mode
        // `videoGravity` has three fill modes against the chrome's seven. The three that map
        // exactly do; the zoom steps land on fill, which is what they mean, and the two fixed-axis
        // modes have no equivalent short of transforming the layer — they are listed here as fill
        // rather than silently doing nothing.
        switch mode {
        case .fit: engine.videoGravity = .resizeAspect
        case .stretch: engine.videoGravity = .resize
        case .crop, .slightZoom, .cinemaZoom, .fitWidth, .fitHeight: engine.videoGravity = .resizeAspectFill
        }
    }

    func applySubtitleStyle(_ style: SubtitleStyle, obstructions: SubtitlePlacement.Obstructions) {
        subtitleStyle = style
        subtitleObstructions = obstructions
    }

    /// Deliberately nothing. The engine declares the category at init and never activates it on the
    /// native path, because AVKit activates per playback and that is what lets tvOS negotiate the
    /// HDMI route — which on an Atmos passthrough session is the whole point of being here.
    func activateAudioSession() {}

    func destroy() {
        loadTask?.cancel()
        loadTask = nil
        EngineLog.handler = nil
        sinks.removeAll()
        engine.stop()
    }
}

// MARK: - Translations

private extension PlayerTrack {
    /// One track, in the chrome's vocabulary. `isAtmos` and `isDTSX` are folded into the codec
    /// label because that is the line a viewer reads, and a bed channel count is not the answer
    /// they are looking for on an Atmos track.
    ///
    /// Selection is deliberately not a parameter: it is applied afterwards by
    /// `marking(selected:)`, from the one publisher that actually carries it.
    init(_ track: TrackInfo) {
        self.init(
            id: Int64(track.id),
            title: track.name,
            language: track.language,
            isSelected: false,
            isExternal: track.isExternal,
            isDefault: track.isDefault,
            isForced: track.isForced,
            isHearingImpaired: track.isHearingImpaired,
            codec: track.isAtmos ? "\(track.codec) (Atmos)"
                : track.isDTSX ? "\(track.codec) (DTS:X)" : track.codec,
            channelCount: track.channels > 0 ? track.channels : nil
        )
    }
}

private extension AudioDelivery {
    /// What the information panel prints for "Output". The distinction that matters to the viewer
    /// who came here is the first one: a stream copy is the bitstream reaching their receiver
    /// intact, which is what makes an Atmos track arrive as Atmos.
    var label: String? {
        switch self {
        case .streamCopy: return L10n.text("player.audio_stream_copy", fallback: "Passthrough (stream copy)")
        case .bridged: return L10n.text("player.audio_bridged", fallback: "Bridged (re-encoded)")
        case .decoded: return L10n.text("player.audio_decoded", fallback: "Decoded to PCM")
        case .playerManaged: return L10n.text("player.audio_player_managed", fallback: "AVFoundation")
        case .droppedNoPipeline: return L10n.text("player.audio_dropped", fallback: "Dropped — no pipeline")
        case .noAudioInSource, .none: return nil
        }
    }
}

private extension VideoRoute {
    /// Named for what it means to the viewer rather than for the code path. `.loopback` is the one
    /// this engine was adopted for: the source is remuxed and handed to AVPlayer, which is what
    /// lets an audio bitstream reach the receiver untouched.
    var label: String? {
        switch self {
        case .loopback: return L10n.text("player.route_loopback", fallback: "Remux to AVPlayer (bitstream intact)")
        case .remoteBypass: return L10n.text("player.route_native", fallback: "Direct to AVPlayer")
        case .software: return L10n.text("player.route_software", fallback: "Software decode (no passthrough)")
        case .audio: return L10n.text("player.route_audio", fallback: "Audio only")
        case .none: return nil
        }
    }
}

private extension VideoFormat {
    var label: String? {
        switch self {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return "Dolby Vision"
        case .hlg: return "HLG"
        }
    }
}
#endif
