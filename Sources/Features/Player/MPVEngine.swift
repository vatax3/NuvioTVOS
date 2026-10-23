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
    /// Lifted to `PlayerAspectMode` when the second engine arrived: a chrome generic over
    /// engines cannot name a type nested in a class that sits behind `#if canImport(Libmpv)`.
    /// The alias keeps `MPVEngine.AspectMode` meaning what it has always meant at every call site.
    typealias AspectMode = PlayerAspectMode

    typealias StreamInfo = PlayerStreamInfo

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
    private(set) var chapters: [PlayerChapter] = []
    /// mpv's `sub-text`: the line it is drawing right now, whoever authored it.
    private(set) var currentCueText: String?

    /// From mpv's own `video-params/gamma`, which is the transfer function it decoded with.
    /// `pq` covers HDR10, HDR10+ and the Dolby Vision profiles mpv tone-maps from.
    var isHDRVideo: Bool {
        guard let transfer = videoFormat?.transfer?.lowercased() else { return false }
        return ["pq", "smpte2084", "hlg", "arib-std-b67"].contains(transfer)
    }
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

    typealias MPVTrack = PlayerTrack

    // MARK: Lifecycle

    func start(
        url: String,
        headers: [String: String],
        startAt: Double,
        verboseLogging: Bool,
        hardwareDecoding: MpvHardwareDecodeMode = .hardwareCopy,
        audioOutput: MpvAudioOutput = .automatic,
        audioChannels: AudioOutputChannels = .auto,
        audioMix: PlayerAudioMix.Options = .init(),
        audioLanguages: [String] = [],
        subtitleLanguages: [String] = [],
        prefersForcedSubtitles: Bool = true,
        hdrPeakDetection: HDRPeakDetection = .automatic,
        subtitleStyle: SubtitleStyle,
        initialAspectMode: AspectMode = .fit,
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
        // A remembered amplification is set here rather than after playback starts, so the first
        // second of the film is already at the level the viewer chose.
        if audioMix.amplificationDb != 0 {
            amplificationDb = audioMix.amplificationDb
            setOption("volume", String(format: "%.0f", PlayerAudioMix.volumePercent(amplificationDb: amplificationDb)))
        }
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
        // mpv's own filter, for the tracks muxed into the file. Sidecar subtitles never reach it
        // — Nuvio draws those itself — so `SubtitleSDHFilter` covers them separately.
        setOption("sub-filter-sdh", subtitleStyle.stripsSDH ? "yes" : "no")
        // Register and select the bundled Noto CJK face. System font names alone are not
        // sufficient: libass loads them through FreeType, which cannot read some sandboxed
        // tvOS system font files even though CoreText can display them.
        if let family = subtitleFontResolver.prepare() {
            setOption("sub-font", family)
            appliedSubtitleFont = family
        }
        // Registering the face with CoreText is not enough: libass loads fonts through FreeType
        // and never consults the process registration, so a bundled CJK face could be visible to
        // Swift and still render as tofu inside mpv. It needs the directory as a font source.
        if let directory = subtitleFontResolver.bundledFontsDirectory {
            setOption("sub-fonts-dir", directory)
        }
        setOption("sub-font-provider", "auto")
        // A television crops the edge of the picture. Without margins mpv lays subtitles out
        // against the frame rather than inside it, and the bottom line is the one that goes.
        setOption("sub-use-margins", "yes")
        setOption("sub-ass-force-margins", "yes")
        // The preferred-language settings were stored and read by nobody, so a file with five
        // audio tracks always opened on whichever one it listed first. mpv takes an ordered
        // list and picks the best match, which is exactly the semantics the settings describe.
        if !audioLanguages.isEmpty { setOption("alang", audioLanguages.joined(separator: ",")) }
        if !subtitleLanguages.isEmpty { setOption("slang", subtitleLanguages.joined(separator: ",")) }
        setOption("subs-match-os-language", "yes")
        // mpv's own default, restored. `yes` widened the fallback to *any* subtitle track when
        // the language preference found nothing, which is how a French television ended up on a
        // Finnish track sitting one row above the French one. `default` falls back only to a
        // track the file itself marked as default, which is the track the viewer expects.
        setOption("subs-fallback", "default")
        // `subtitle_use_forced_subtitles` read by the engine at last. mpv's `yes` is exactly what
        // the setting means: a forced track when the audio is already in the subtitle language,
        // because a full track would then be repeating dialogue the viewer can hear.
        setOption("subs-fallback-forced", prefersForcedSubtitles ? "yes" : "no")
        // HDR: hand the display the source colorimetry and let libplacebo tone-map what the
        // panel cannot show.
        //
        // A reading from a real Apple TV settled what this used to be guesswork about. On a
        // Dolby Vision HEVC file the panel reported `pq · bt.2020` for **both** the source and
        // the presented output — so `target-colorspace-hint` is working and the picture is not
        // being flattened to SDR, which had been the standing suspect for a viewer's report of
        // light that was "too dark or too bright, and varies by scene".
        //
        // What remains is below: we forced `hdr-compute-peak` to `yes` where mpv's own default
        // is `auto`. Measuring every frame's peak in a path that is not converting lets the
        // presented brightness follow the content, which is the right shape for that complaint.
        // The override is gone; the value is the viewer's to try, because it cannot be judged
        // from here. See `HDRPeakDetection`.
        setOption("target-colorspace-hint", "yes")
        setOption("tone-mapping", "auto")
        setOption("hdr-compute-peak", hdrPeakDetection.mpvValue)
        // Keep the file open at EOF so the end is a state change, not a teardown.
        setOption("keep-open", "yes")
        setOption("force-window", "no")
        setOption("ytdl", "no")
        setOption("terminal", "no")
        // The layout mpv asks the AudioUnit for. Getting this wrong is not a quality problem
        // but a silence problem — see `PlayerSettingsStore.audioOutputChannels`.
        setOption("audio-channels", audioChannels.mpvValue)
        setOption("audio-normalize-downmix", audioMix.normalizesDownmix ? "yes" : "no")
        // The dialogue control. Passed to libswresample rather than set on mpv, because mpv has
        // no centre-level option of its own — it is the resampler that folds the channels.
        if let swresample = PlayerAudioMix.swresampleOptions(centerMixDb: audioMix.centerMixLevelDb) {
            setOption("audio-swresample-o", swresample)
        }
        applySubtitleStyle(subtitleStyle, asOption: true)
        // A TV is not a laptop: cache generously, the network is the bottleneck.
        setOption("cache", "yes")
        setOption("demuxer-max-bytes", "96MiB")
        setOption("demuxer-readahead-secs", "30")
        // Switching audio or subtitle track is not free: mpv only demuxes the streams that are
        // selected, so picking a new one makes it seek back to the playhead to collect that
        // stream's packets. With no backward buffer that seek goes to the network, which is the
        // one-to-two second silence a viewer hears when they change track. Held in memory, the
        // same seek is served from RAM and the switch happens under the picture.
        setOption("demuxer-max-back-bytes", "32MiB")
        setOption("demuxer-seekable-cache", "yes")
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
            errorMessage = L10n.text("player.engine_failed", fallback: "The MPV engine could not start.")
            destroy()
            return
        }

        // Before `loadfile`, so the first frame already has the viewer's shape. Applied from the
        // SwiftUI `.task` it landed after playback had started, which is a visible snap out of
        // Fit for anyone whose default is not Fit — and it relied on `.task` running after
        // `makeUIViewController`, which SwiftUI happens to do but does not promise.
        setAspectMode(initialAspectMode)

        for property in ["time-pos", "duration", "demuxer-cache-time", "pause", "eof-reached", "core-idle", "track-list", "chapter-list", "current-tracks/sub/lang", "sub-text"] {
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

    /// `exact` decodes forward from the keyframe to the frame asked for. Slower, and the right
    /// trade for a chapter: a keyframe seek can land seconds away, which on a chapter boundary
    /// means landing in the chapter the viewer was trying to leave.
    func seek(toExactly seconds: Double) {
        command(["seek", String(seconds), "absolute+exact"])
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

    /// Post-decode gain, Android's L10n.text("player.amplification_pcm", fallback: "Amplification (PCM)") control. See `PlayerAudioMix` for the
    /// conversion — mpv wants a percentage, the viewer picked decibels.
    static let amplificationLimitDb = PlayerAudioMix.amplificationRangeDb.upperBound

    func setAmplification(db: Int) {
        let clamped = min(Self.amplificationLimitDb, max(0, db))
        amplificationDb = clamped
        command(["set", "volume", String(format: "%.0f", PlayerAudioMix.volumePercent(amplificationDb: clamped))])
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
    /// - Parameter obstructions: what is covering the bottom of the picture. The line is lifted
    ///   clear of it while it is there, and only while it is — see `SubtitlePlacement`.
    func applySubtitleStyle(
        _ style: SubtitleStyle, obstructions: SubtitlePlacement.Obstructions = .init()
    ) {
        applySubtitleStyle(style, asOption: false, obstructions: obstructions)
    }

    private func applySubtitleStyle(
        _ style: SubtitleStyle,
        asOption: Bool,
        obstructions: SubtitlePlacement.Obstructions = .init()
    ) {
        let set: (String, String) -> Void = { name, value in
            if asOption { self.setOption(name, value) }
            else { self.command(["set", name, value]) }
        }
        set("sub-ass-override", style.assOverride)
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
        // `sub-pos` stays at mpv's own 100 and the whole distance is spent through the margin,
        // which is the only way the two renderers can agree: `sub-pos` is a percentage of the
        // frame and the overlay works in points, so mixing them double-counted the gap and made
        // the stored offset worth about half as much here as there. See `SubtitlePlacement`.
        set("sub-pos", "100")
        set("sub-use-margins", "yes")
        set(
            "sub-margin-y",
            String(format: "%.0f", SubtitlePlacement.mpvMarginY(
                offset: style.verticalOffset, obstructions: obstructions
            ))
        )
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

        case MPV_EVENT_VIDEO_RECONFIG:
            // `loadfile` only means the demuxer accepted the URL. This is the first event that
            // proves the decoder produced a video configuration for the renderer; setting the
            // flag at load time made the first-frame watchdog permanently blind.
            hasRenderedFrame = true
            // And it is the first moment `video-params` carries a colorimetry, which the
            // file-loaded pass above reads a beat too early — the comment two lines up says why.
            //
            // That cost more than a blank row. `videoFormat` is built in the same call, so the
            // criteria handed to `AVDisplayManager` carried a frame rate and **no transfer
            // function**: 1.0.38 stopped suppressing display matching, and the dynamic range we
            // then sent was empty anyway. `videoFormat` is observed, so re-reading it here
            // re-applies the criteria with what the decoder actually reported.
            refreshStreamInfo()

        case MPV_EVENT_END_FILE:
            guard let data = event.pointee.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            // `error` means the source failed; EOF is a normal finish.
            if end.reason == MPV_END_FILE_REASON_ERROR {
                // mpv's own words said accurately what had happened and nothing about what to do
                // about it — a viewer reading "unrecognized file format" on a television learns
                // only that something is wrong. The raw text is kept underneath; see
                // `MPVPlaybackFailure`.
                errorMessage = MPVPlaybackFailure.message(
                    fileError: String(cString: mpv_error_string(end.error)),
                    logLine: logTail.last
                )
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
        case "chapter-list":
            refreshChapters()
        case "current-tracks/sub/lang":
            if let family = subtitleFontResolver.familyForLanguage(property.stringValue) {
                applySubtitleFont(family)
            }
        case "sub-text":
            currentCueText = property.stringValue?.nilIfBlank
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

    /// Reads the chapter list back as JSON, the same way the tracks are read.
    ///
    /// mpv lists chapters itself for every container it demuxes, so there is nothing to parse out
    /// of the file by hand — which is the whole of upstream's `MatroskaChapterLoader`, written
    /// because ExoPlayer's Matroska extractor skips them.
    private func refreshChapters() {
        guard let handle,
              let raw = mpv_get_property_string(handle, "chapter-list") else { return }
        defer { mpv_free(raw) }

        guard let data = String(cString: raw).data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        chapters = PlayerChapters.normalize(
            entries.compactMap { entry in
                guard let time = entry["time"] as? Double, time.isFinite else { return nil }
                return PlayerChapter(start: time, title: entry["title"] as? String)
            }
        )
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
                isSelected: (entry["selected"] as? Bool) ?? false,
                isExternal: (entry["external"] as? Bool) ?? false,
                isDefault: (entry["default"] as? Bool) ?? false,
                isForced: (entry["forced"] as? Bool) ?? false,
                isHearingImpaired: (entry["hearing-impaired"] as? Bool) ?? false,
                codec: entry["codec"] as? String,
                channelCount: (entry["demux-channel-count"] as? Int)
                    ?? (entry["audio-channels"] as? Int)
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
            sourceRange: Self.colorimetry(
                gamma: propertyString("video-params/gamma"),
                primaries: propertyString("video-params/primaries")
            ),
            outputRange: Self.colorimetry(
                gamma: propertyString("video-target-params/gamma"),
                primaries: propertyString("video-target-params/primaries")
            ),
            audioCodec: propertyString("audio-codec-name") ?? propertyString("audio-codec"),
            audioChannels: propertyString("audio-params/channel-count"),
            audioOutput: audioOutput,
            videoWidth: width.flatMap(Int.init),
            videoHeight: height.flatMap(Int.init),
            audioChannelCount: propertyString("audio-params/channel-count").flatMap(Int.init),
            // `video-params/depth` is the decoded depth, which is what a badge means by "10bit".
            bitDepth: propertyString("video-params/depth").flatMap(Int.init)
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

    /// One line out of mpv's two colorimetry vocabularies, or nil when it knows neither.
    ///
    /// `video-target-params` is absent on engines or builds that do not expose it, so a missing
    /// answer has to read as "unknown" rather than as "same as the source" — claiming the output
    /// matches when we cannot see it is exactly the wrong way for this diagnostic to fail.
    nonisolated static func colorimetry(gamma: String?, primaries: String?) -> String? {
        let parts = [gamma?.nilIfBlank, primaries?.nilIfBlank].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    typealias LiveStats = PlayerLiveStats

    func liveStats() -> LiveStats {
        // `cache-speed` is bytes per second; every other rate in the overlay is bits.
        let cacheBytes = propertyDouble("cache-speed")
        let video = propertyDouble("video-bitrate") ?? 0
        let audio = propertyDouble("audio-bitrate") ?? 0
        let stream = video + audio
        return LiveStats(
            bufferSeconds: propertyDouble("demuxer-cache-duration"),
            networkBitsPerSecond: cacheBytes.map { $0 * 8 },
            streamBitsPerSecond: stream > 0 ? stream : nil
        )
    }

    private func propertyDouble(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else {
            return nil
        }
        return value
    }

    private func propertyString(_ name: String) -> String? {
        guard let handle, let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.nilIfBlank
    }
}

/// Everything the chrome asks of an engine, `MPVEngine` already had — which is the point of how
/// `PlayerEngineSurface` was extracted. The conformance is empty on purpose: a member that needed
/// an adapter here would be a sign the protocol had been designed rather than measured.
extension MPVEngine: PlayerEngineSurface {
    static var label: String { "MPV" }

    /// mpv sees a demuxer and a decoder, never the origin's HTTP answer: a refusal reaches it as
    /// an empty stream and reads as invalid content. So it cannot tell a refused origin from a
    /// file another engine would open, and says so by never ruling the hand-off out. The engine
    /// that *can* tell is the one that classifies — see the adapter's `errorInfo` reading.
    var failureInvitesAnotherEngine: Bool { true }
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
