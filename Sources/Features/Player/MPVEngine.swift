#if canImport(Libmpv)
import AVFoundation
import Foundation
import Observation
import QuartzCore
import os
import SwiftUI
import UIKit
import Libmpv

/// libmpv wrapper — the internal engine for everything AVFoundation will not open.
///
/// This is the same player the Android build uses, so the "MPV (extended codecs)" setting stops
/// being a placeholder: MKV, VP9 in odd containers, TrueHD and DTS tracks all decode here.
///
/// Two things it does that a hand-off to Infuse or VLC cannot: it accepts the per-stream request
/// headers a debrid link needs, and playback stays inside Nuvio so resume, progress, Trakt
/// scrobbling and auto-play keep working.
@Observable
@MainActor
final class MPVEngine {
    /// The seven picture modes the Android TV player offers, in its order.  The aspect button
    /// steps through the list one press at a time, so the sequence is part of the port, not an
    /// arbitrary ordering of an enum.
    enum AspectMode: String, CaseIterable, Identifiable {
        case fit, crop, stretch, slightZoom, cinemaZoom, fitHeight, fitWidth

        var id: String { rawValue }
        var label: String {
            switch self {
            case .fit: return L10n.text("player.aspect_fit")
            case .crop: return L10n.text("player.aspect_crop")
            case .stretch: return L10n.text("player.aspect_stretch")
            case .slightZoom: return L10n.text("player.aspect_slight_zoom")
            case .cinemaZoom: return L10n.text("player.aspect_cinema_zoom")
            case .fitHeight: return L10n.text("player.aspect_fit_height")
            case .fitWidth: return L10n.text("player.aspect_fit_width")
            }
        }

        var next: AspectMode {
            let all = AspectMode.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }
    }

    struct StreamInfo: Hashable {
        var videoCodec: String?
        var resolution: String?
        var frameRate: String?
        var audioCodec: String?
        var audioChannels: String?
        var audioOutput: String?
    }

    private(set) var isReady = false
    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// Media time up to which the demuxer has data. Android draws it behind the played fill so
    /// a stalling source is visible before it stops.
    private(set) var bufferedPosition: Double = 0
    private(set) var didEnd = false
    private(set) var errorMessage: String?
    /// True once a frame has actually been presented. A running clock with this still false is
    /// the signature of a renderer that cannot draw — the case that looks like a dead app.
    private(set) var hasRenderedFrame = false
    /// The tail of mpv's own log. Without it a black picture gives nothing to go on.
    private(set) var logTail: [String] = []
    /// Selectable tracks the file itself carries, for the transport menus.
    private(set) var audioTracks: [MPVTrack] = []
    private(set) var subtitleTracks: [MPVTrack] = []
    private(set) var playbackSpeed: Double = 1
    private(set) var audioDelay: Double = 0
    private(set) var subtitleDelay: Double = 0
    private(set) var amplificationDb: Int = 0
    private(set) var aspectMode: AspectMode = .fit
    private(set) var streamInfo = StreamInfo()
    /// Which audio output mpv actually ended up with. `null` means the real one refused to
    /// start and the fallback took over — the picture keeps playing and nothing is heard, so
    /// this is the only way to tell that case apart from a file with no soundtrack.
    private(set) var audioOutput: String?
    /// Everything the display server needs to pick a mode. Published separately from
    /// `streamInfo` because it is machine-readable rather than something to print.
    private(set) var videoFormat: DisplayModeMatcher.VideoFormat?

    @ObservationIgnored private var handle: OpaquePointer?
    @ObservationIgnored private let log = Logger(subsystem: "com.nuvio.tvos", category: "MPV")
    @ObservationIgnored private var appliedSubtitleFont: String?
    @ObservationIgnored private let subtitleFontResolver = MPVSubtitleFontResolver()
    /// libmpv emits `time-pos` much more often than a TV UI needs to redraw. Publishing every
    /// sample invalidates the complete SwiftUI player tree on the main actor and can starve
    /// AudioUnit. The reference iOS bridge samples state; tvOS now does the same at 4 Hz.
    @ObservationIgnored private var lastPositionPublication = CACurrentMediaTime()

    struct MPVTrack: Identifiable, Hashable {
        let id: Int64
        let title: String
        let language: String?
        let isSelected: Bool

        var displayName: String {
            let label = title.nilIfBlank ?? language?.uppercased() ?? "Track \(id)"
            guard let language, title.nilIfBlank != nil else { return label }
            return "\(label) · \(language.uppercased())"
        }
    }

    // MARK: Lifecycle

    func start(
        url: String,
        headers: [String: String],
        startAt: Double,
        verboseLogging: Bool,
        hardwareDecoding: MpvHardwareDecodeMode = .hardwareCopy,
        audioOutput: MpvAudioOutput = .automatic,
        audioChannels: AudioOutputChannels = .auto,
        subtitleStyle: SubtitleStyle,
        layer: MPVMetalLayer
    ) {
        guard handle == nil, let mpv = mpv_create() else { return }
        handle = mpv

        // mpv renders straight into the CAMetalLayer it is handed here. `wid` is how a GPU
        // context is given its surface; there is no render API, no framebuffer to pass and no
        // draw callback to service.
        //
        // `gpu-next` + `vulkan` + `moltenvk` is the supported path on Apple platforms, and the
        // reason the OpenGL route this engine used before could composite subtitles but never a
        // video frame: MPVKit builds libmpv with `-Dvideotoolbox-gl=disabled`, so the video
        // plane has no way into a GL context. Same combination the Nuvio iOS client ships.
        var layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layerPointer)
        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("gpu-context", "moltenvk")
        setOption("hwdec", hardwareDecoding.mpvValue)
        setOption("ao", audioOutput.mpvValue)
        setOption("audio-fallback-to-null", "yes")
        // Headroom for the amplification control; mpv refuses volumes above `volume-max`.
        setOption("volume-max", "400")
        // Conservative Vulkan settings: MoltenVK is a translation layer, and the async paths
        // are where it is least reliable.
        setOption("vulkan-swap-mode", "fifo")
        setOption("vulkan-queue-count", "1")
        setOption("vulkan-async-compute", "no")
        setOption("vulkan-async-transfer", "no")
        // VideoToolbox needs its normal Metal interop path. Disabling it forces costly copies
        // and can cause AudioUnit underruns on Apple TV.
        setOption("video-rotate", "no")
        // Let libass detect BOM/declared encodings. Forcing UTF-8 corrupts valid UTF-16 and
        // Windows-1252 releases into replacement squares.
        setOption("sub-codepage", "auto")
        // Register and select the bundled Noto CJK face. System font names alone are not
        // sufficient: libass loads them through FreeType, which cannot read some sandboxed
        // tvOS system font files even though CoreText can display them.
        if let family = subtitleFontResolver.prepare() {
            setOption("sub-font", family)
            appliedSubtitleFont = family
        }
        setOption("subs-match-os-language", "yes")
        setOption("subs-fallback", "yes")
        // HDR: hand the display the source colorimetry and let libplacebo tone-map what the
        // panel cannot show.
        setOption("target-colorspace-hint", "yes")
        setOption("tone-mapping", "auto")
        setOption("hdr-compute-peak", "yes")
        // Keep the file open at EOF so the end is a state change, not a teardown.
        setOption("keep-open", "yes")
        setOption("force-window", "no")
        setOption("ytdl", "no")
        setOption("terminal", "no")
        // The layout mpv asks the AudioUnit for. Getting this wrong is not a quality problem
        // but a silence problem — see `PlayerSettingsStore.audioOutputChannels`.
        setOption("audio-channels", audioChannels.mpvValue)
        applySubtitleStyle(subtitleStyle, asOption: true)
        // A TV is not a laptop: cache generously, the network is the bottleneck.
        setOption("cache", "yes")
        setOption("demuxer-max-bytes", "96MiB")
        setOption("demuxer-readahead-secs", "30")
        if verboseLogging { setOption("msg-level", "all=v") }

        // The header set a debrid link needs — the reason this path exists at all.
        if !headers.isEmpty {
            let joined = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
            setOption("http-header-fields", joined)
        }
        if startAt > 1 {
            setOption("start", String(format: "%.3f", startAt))
        }

        // mpv's own diagnostics. Errors always; the whole stream when verbose logging is on.
        mpv_request_log_messages(mpv, verboseLogging ? "v" : "warn")

        guard mpv_initialize(mpv) >= 0 else {
            errorMessage = "The MPV engine could not start."
            destroy()
            return
        }

        for property in ["time-pos", "duration", "demuxer-cache-time", "pause", "eof-reached", "core-idle", "track-list", "current-tracks/sub/lang", "sub-text"] {
            let format: mpv_format = {
                switch property {
                case "time-pos", "duration", "demuxer-cache-time": return MPV_FORMAT_DOUBLE
                case "pause", "eof-reached", "core-idle": return MPV_FORMAT_FLAG
                case "current-tracks/sub/lang", "sub-text": return MPV_FORMAT_STRING
                default: return MPV_FORMAT_NODE
                }
            }()
            mpv_observe_property(mpv, 0, property, format)
        }

        // mpv posts events on its own thread; the wakeup callback hops them to us.
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            let engine = Unmanaged<MPVEngineBox>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in engine.engine?.drainEvents() }
        }, Unmanaged.passUnretained(box).toOpaque())

        command(["loadfile", url])
        isReady = true
        hasRenderedFrame = true
    }

    /// Retains a weak back-reference for the C callbacks, which cannot capture Swift context.
    @ObservationIgnored private lazy var box: MPVEngineBox = {
        let box = MPVEngineBox()
        box.engine = self
        return box
    }()

    func destroy() {
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            self.handle = nil
        }
        isReady = false
    }

    // MARK: Transport

    func togglePause() { setPaused(!isPaused) }

    func setPaused(_ paused: Bool) {
        var flag: CInt = paused ? 1 : 0
        guard let handle else { return }
        mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func seek(by seconds: Double) {
        command(["seek", String(seconds), "relative"])
    }

    func seek(to seconds: Double) {
        command(["seek", String(seconds), "absolute"])
    }

    func selectAudioTrack(_ id: Int64) { command(["set", "aid", String(id)]) }

    func selectSubtitleTrack(_ id: Int64?) {
        if let id, let track = subtitleTracks.first(where: { $0.id == id }) {
            if let family = subtitleFontResolver.familyForLanguage(track.language) {
                applySubtitleFont(family)
            }
        }
        command(["set", "sid", id.map(String.init) ?? "no"])
    }

    /// Loads an addon-supplied subtitle file into the running instance.
    func addSubtitle(url: String, title: String) {
        command(["sub-add", url, "select", title])
    }

    func setPlaybackSpeed(_ speed: Double) {
        let clamped = min(3, max(0.25, speed))
        playbackSpeed = clamped
        command(["set", "speed", String(format: "%.2f", clamped)])
    }

    /// Android's ranges: audio delay is ±3 s in 25 ms steps, subtitle delay ±60 s in 100 ms
    /// steps.  The asymmetry is not arbitrary — an out-of-sync audio track is a decoder-level
    /// offset of a few frames, while a mismatched subtitle file can be a whole minute out.
    static let audioDelayLimit: Double = 3
    static let subtitleDelayLimit: Double = 60

    func adjustAudioDelay(by seconds: Double) {
        setAudioDelay(audioDelay + seconds)
    }

    func setAudioDelay(_ seconds: Double) {
        audioDelay = min(Self.audioDelayLimit, max(-Self.audioDelayLimit, seconds))
        command(["set", "audio-delay", String(format: "%.3f", audioDelay)])
    }

    func adjustSubtitleDelay(by seconds: Double) {
        setSubtitleDelay(subtitleDelay + seconds)
    }

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = min(Self.subtitleDelayLimit, max(-Self.subtitleDelayLimit, seconds))
        command(["set", "sub-delay", String(format: "%.3f", subtitleDelay)])
    }

    /// Changing the layout makes mpv rebuild its audio output, so it takes effect without
    /// leaving playback — which matters when the setting is the one being tested.
    func setAudioChannels(_ channels: AudioOutputChannels) {
        command(["set", "audio-channels", channels.mpvValue])
    }

    /// Post-decode gain, Android's "Amplification (PCM)" control. mpv expresses volume as a
    /// percentage, so the dB the viewer picks is converted rather than passed through.
    static let amplificationLimitDb = 10

    func setAmplification(db: Int) {
        let clamped = min(Self.amplificationLimitDb, max(0, db))
        amplificationDb = clamped
        let percent = pow(10.0, Double(clamped) / 20.0) * 100
        command(["set", "volume", String(format: "%.0f", percent)])
    }

    func setAspectMode(_ mode: AspectMode) {
        aspectMode = mode
        // The modes are alternatives, not layers, and mpv keeps whichever knob was last set —
        // so every one of them is returned to its neutral value before the new mode is applied.
        command(["set", "keepaspect", "yes"])
        command(["set", "panscan", "0"])
        command(["set", "video-zoom", "0"])

        // mpv's panscan is its content-aware crop-to-fill implementation. `video-zoom` is a
        // log₂ scale, hence 0.20 ≈ 1.15× and 0.41 ≈ 1.33× — the same steps as Android TV.
        switch mode {
        case .fit:
            break
        case .crop:
            command(["set", "panscan", "1"])
        case .stretch:
            command(["set", "keepaspect", "no"])
        case .slightZoom:
            command(["set", "video-zoom", "0.20"])
        case .cinemaZoom:
            command(["set", "video-zoom", "0.41"])
        case .fitHeight:
            // Android fills the height only when the picture is wider than the panel; a 4:3
            // source is deliberately left untouched rather than blown up.
            if let aspect = sourceAspect, aspect > displayAspect { command(["set", "panscan", "1"]) }
        case .fitWidth:
            if let aspect = sourceAspect, aspect < displayAspect { command(["set", "panscan", "1"]) }
        }
    }

    /// Playing to no audio device at all: there is a soundtrack, and it is going nowhere.
    var isSilentlyFallingBack: Bool {
        !audioTracks.isEmpty && audioOutput == "null"
    }

    /// Display aspect ratio of the decoded picture, as mpv reports it after applying the
    /// container's pixel aspect — the same number Android reads off `VideoSize`.
    private var sourceAspect: Double? {
        propertyString("video-params/aspect").flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Apple TV outputs 16:9 in every supported mode, so the panel aspect is a constant here
    /// rather than something to measure off the layer.
    private var displayAspect: Double { 16.0 / 9.0 }

    /// Apply the same subtitle preferences used by AVKit and the custom external-subtitle
    /// overlay.  This is deliberately a live update: changing an audio/subtitle preference
    /// must never recreate the MPV surface or briefly interrupt playback.
    func applySubtitleStyle(_ style: SubtitleStyle) {
        applySubtitleStyle(style, asOption: false)
    }

    private func applySubtitleStyle(_ style: SubtitleStyle, asOption: Bool) {
        let set: (String, String) -> Void = { name, value in
            if asOption { self.setOption(name, value) }
            else { self.command(["set", name, value]) }
        }
        set("sub-ass-override", "no")
        set("sub-font-size", String(format: "%.0f", min(96, max(18, 55 * style.sizeScale))))
        set("sub-bold", style.bold ? "yes" : "no")
        set("sub-color", mpvColor(style.textColor))
        set("sub-back-color", mpvColor(style.backgroundColor))
        set("sub-outline-color", mpvColor(style.outlineColor))
        set("sub-border-color", mpvColor(style.outlineColor))
        let outlineSize = style.outlineEnabled ? String(format: "%.1f", max(1, style.outlineWidth * 1.5)) : "0"
        set("sub-outline-size", outlineSize)
        set("sub-border-size", outlineSize)
        set("sub-border-style", style.backgroundColor.alphaComponent > 0.01 ? "opaque-box" : "outline-and-shadow")
        // MPV places subtitles using a percentage from the bottom.  Nuvio's stored offset is
        // intentionally in small display points, so a 2:1 conversion produces useful remote
        // presets without making the transport bar overlap the text.
        set("sub-pos", String(format: "%.0f", min(100, max(0, 100 - style.verticalOffset / 10))))
    }

    private func mpvColor(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X%02X",
            Int((alpha * 255).rounded()), Int((red * 255).rounded()),
            Int((green * 255).rounded()), Int((blue * 255).rounded())
        )
    }

    // MARK: Commands

    private func setOption(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_option_string(handle, name, value)
    }

    private func command(_ arguments: [String]) {
        guard let handle else { return }
        // mpv wants a NULL-terminated argv; the C strings must outlive the call.
        let owned = arguments.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        argv.append(nil)
        argv.withUnsafeMutableBufferPointer { buffer in
            _ = mpv_command(handle, buffer.baseAddress)
        }
    }

    // MARK: Events

    fileprivate func drainEvents() {
        guard let handle else { return }
        while true {
            guard let event = mpv_wait_event(handle, 0) else { return }
            if event.pointee.event_id == MPV_EVENT_NONE { return }
            process(event: event)
        }
    }

    private func process(event: UnsafeMutablePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.pointee.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            apply(property)

        case MPV_EVENT_FILE_LOADED:
            isBuffering = false
            // The audio output is built when the file opens, not when mpv starts, and it needs
            // an active session at that moment. Taking it once in `viewDidLoad` is not enough:
            // a session left active by the AVFoundation engine, or an interruption between the
            // two, leaves the AudioUnit unable to start — and `audio-fallback-to-null` then
            // hides that as silent video.
            activateAudioSession()
            refreshTracks()
            refreshStreamInfo()

        case MPV_EVENT_END_FILE:
            guard let data = event.pointee.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            // `error` means the source failed; EOF is a normal finish.
            if end.reason == MPV_END_FILE_REASON_ERROR {
                errorMessage = String(cString: mpv_error_string(end.error))
            } else if end.reason == MPV_END_FILE_REASON_EOF {
                didEnd = true
            }

        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.pointee.data else { return }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let text = String(cString: message.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let prefix = String(cString: message.prefix)
            logTail.append("[\(prefix)] \(text)")
            // mpv's own diagnosis of a failure — "unable to initialize audio unit" and the
            // like — used to exist only inside a player panel, where nobody looking at a bug
            // report can see it. Mirroring it into the system log makes a silent playback
            // reproducible from a `log stream` instead of a screenshot.
            switch String(cString: message.level) {
            case "fatal", "error":
                log.error("[\(prefix, privacy: .public)] \(text, privacy: .public)")
            case "warn":
                log.warning("[\(prefix, privacy: .public)] \(text, privacy: .public)")
            default:
                log.debug("[\(prefix, privacy: .public)] \(text, privacy: .public)")
            }
            // Only the tail is useful, and an unbounded array on a long playback is a leak.
            if logTail.count > 40 { logTail.removeFirst(logTail.count - 40) }

        case MPV_EVENT_SHUTDOWN:
            destroy()

        default:
            break
        }
    }

    private func apply(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        switch name {
        case "time-pos":
            if let value = property.data?.assumingMemoryBound(to: Double.self).pointee,
               value.isFinite {
                publishPositionIfNeeded(value)
            }
        case "duration":
            if let value = property.data?.assumingMemoryBound(to: Double.self).pointee,
               value.isFinite, value > 0 {
                duration = value
            }
        case "demuxer-cache-time":
            if let value = property.data?.assumingMemoryBound(to: Double.self).pointee,
               value.isFinite, value >= 0 {
                bufferedPosition = value
            }
        case "pause":
            if let value = property.data?.assumingMemoryBound(to: CInt.self).pointee {
                isPaused = value != 0
            }
        case "core-idle":
            if let value = property.data?.assumingMemoryBound(to: CInt.self).pointee {
                // Idle while unpaused means it is waiting on data.
                isBuffering = value != 0 && !isPaused
            }
        case "eof-reached":
            if let value = property.data?.assumingMemoryBound(to: CInt.self).pointee, value != 0 {
                didEnd = true
            }
        case "track-list":
            refreshTracks()
        case "current-tracks/sub/lang":
            if let family = subtitleFontResolver.familyForLanguage(property.stringValue) {
                applySubtitleFont(family)
            }
        case "sub-text":
            if let family = subtitleFontResolver.familyForText(property.stringValue) {
                applySubtitleFont(family)
            }
        default:
            break
        }
    }

    /// Claims the playback route. Failures are recorded rather than swallowed — a refused
    /// session is one of the two ways playback ends up silent, and it is invisible otherwise.
    func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            let message = "audio session: \(error.localizedDescription)"
            log.error("\(message, privacy: .public)")
            logTail.append("[error] \(message)")
        }
    }

    /// Reads the track list back as JSON, which is far less error-prone than walking mpv_node.
    private func refreshTracks() {
        guard let handle,
              let raw = mpv_get_property_string(handle, "track-list") else { return }
        defer { mpv_free(raw) }

        guard let data = String(cString: raw).data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        var audio: [MPVTrack] = []
        var subtitles: [MPVTrack] = []
        for entry in entries {
            guard let id = entry["id"] as? Int64 ?? (entry["id"] as? Int).map(Int64.init),
                  let type = entry["type"] as? String else { continue }
            let track = MPVTrack(
                id: id,
                title: (entry["title"] as? String) ?? "",
                language: entry["lang"] as? String,
                isSelected: (entry["selected"] as? Bool) ?? false
            )
            if type == "audio" { audio.append(track) }
            if type == "sub" { subtitles.append(track) }
        }
        audioTracks = audio
        subtitleTracks = subtitles
        if let family = subtitleFontResolver.familyForLanguage(subtitles.first(where: \.isSelected)?.language) {
            applySubtitleFont(family)
        }
    }

    private func applySubtitleFont(_ family: String) {
        guard family != appliedSubtitleFont else { return }
        appliedSubtitleFont = family
        command(["set", "sub-font", family])
    }

    private func publishPositionIfNeeded(_ value: Double) {
        let now = CACurrentMediaTime()
        let isDiscontinuity = value < position || abs(value - position) > 1.25
        guard isDiscontinuity || now - lastPositionPublication >= 0.25 else { return }
        lastPositionPublication = now
        position = value
    }

    private func refreshStreamInfo() {
        let width = propertyString("video-params/w")
        let height = propertyString("video-params/h")
        // `video-params` has no fps member. `container-fps` is the declared rate — the one a
        // display should be matched to — and the filtered estimate is the fallback for a
        // container that declares nothing.
        let fps = (propertyString("container-fps") ?? propertyString("estimated-vf-fps"))
            .flatMap(Double.init)
        let codec = propertyString("video-codec") ?? propertyString("video-format")
        audioOutput = propertyString("current-ao")
        streamInfo = StreamInfo(
            videoCodec: codec,
            resolution: width.flatMap { width in height.map { "\(width) × \($0)" } },
            frameRate: fps.map { String(format: "%.3g fps", $0) },
            audioCodec: propertyString("audio-codec-name") ?? propertyString("audio-codec"),
            audioChannels: propertyString("audio-params/channel-count"),
            audioOutput: audioOutput
        )

        if let fps, let width = width.flatMap(Int32.init), let height = height.flatMap(Int32.init) {
            videoFormat = DisplayModeMatcher.VideoFormat(
                codec: codec,
                width: width,
                height: height,
                frameRate: fps,
                transfer: propertyString("video-params/gamma"),
                primaries: propertyString("video-params/primaries"),
                matrix: propertyString("video-params/colormatrix")
            )
        }
    }

    private func propertyString(_ name: String) -> String? {
        guard let handle, let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.nilIfBlank
    }
}

/// Bridges the C callbacks, which take a raw pointer and cannot hold a Swift reference.
private final class MPVEngineBox: @unchecked Sendable {
    weak var engine: MPVEngine?
}

private extension mpv_event_property {
    var stringValue: String? {
        guard format == MPV_FORMAT_STRING,
              let pointer = data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
        else { return nil }
        return String(cString: pointer).nilIfBlank
    }
}

#endif
