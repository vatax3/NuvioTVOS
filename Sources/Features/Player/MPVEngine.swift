#if canImport(Libmpv)
import Foundation
import Observation
import QuartzCore
import os
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
    private(set) var isReady = false
    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
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

    @ObservationIgnored private var handle: OpaquePointer?
    @ObservationIgnored private let log = Logger(subsystem: "com.nuvio.tvos", category: "MPV")

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
        setOption("ao", "audiounit")
        setOption("audio-fallback-to-null", "yes")
        // Conservative Vulkan settings: MoltenVK is a translation layer, and the async paths
        // are where it is least reliable.
        setOption("vulkan-swap-mode", "fifo")
        setOption("vulkan-queue-count", "1")
        setOption("vulkan-async-compute", "no")
        setOption("vulkan-async-transfer", "no")
        setOption("vulkan-disable-interop", "yes")
        setOption("video-rotate", "no")
        // Force UTF-8 rather than letting uchardet guess. It mis-detects short lines — a "♪"
        // arrives as "â™ª" — and essentially everything shipped today, embedded or external,
        // is UTF-8 anyway.
        setOption("sub-codepage", "+utf-8")
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
        setOption("audio-channels", "auto")
        // A TV is not a laptop: cache generously, the network is the bottleneck.
        setOption("cache", "yes")
        setOption("demuxer-max-bytes", "64MiB")
        setOption("demuxer-readahead-secs", "20")
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

        for property in ["time-pos", "duration", "pause", "eof-reached", "core-idle", "track-list"] {
            let format: mpv_format = {
                switch property {
                case "time-pos", "duration": return MPV_FORMAT_DOUBLE
                case "pause", "eof-reached", "core-idle": return MPV_FORMAT_FLAG
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
        command(["set", "sid", id.map(String.init) ?? "no"])
    }

    /// Loads an addon-supplied subtitle file into the running instance.
    func addSubtitle(url: String, title: String) {
        command(["sub-add", url, "select", title])
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
            refreshTracks()

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
            logTail.append("[\(String(cString: message.prefix))] \(text)")
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
                position = value
            }
        case "duration":
            if let value = property.data?.assumingMemoryBound(to: Double.self).pointee,
               value.isFinite, value > 0 {
                duration = value
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
        default:
            break
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
    }
}

/// Bridges the C callbacks, which take a raw pointer and cannot hold a Swift reference.
private final class MPVEngineBox: @unchecked Sendable {
    weak var engine: MPVEngine?
}

#endif
