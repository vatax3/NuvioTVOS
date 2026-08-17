#if canImport(Libmpv)
import Foundation
import Observation
import GLKit
import OpenGLES
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
    /// Selectable tracks the file itself carries, for the transport menus.
    private(set) var audioTracks: [MPVTrack] = []
    private(set) var subtitleTracks: [MPVTrack] = []

    @ObservationIgnored private var handle: OpaquePointer?
    @ObservationIgnored private(set) var renderContext: OpaquePointer?
    @ObservationIgnored private let log = Logger(subsystem: "com.nuvio.tvos", category: "MPV")
    /// Called off the main actor whenever mpv has a new frame ready.
    @ObservationIgnored var onRedraw: (() -> Void)?

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

    func start(url: String, headers: [String: String], startAt: Double, verboseLogging: Bool) {
        guard handle == nil, let mpv = mpv_create() else { return }
        handle = mpv

        // Rendering goes through the render API rather than a window mpv owns.
        setOption("vo", "libmpv")
        setOption("gpu-api", "opengl")
        // VideoToolbox handles H.264/HEVC in hardware; software decode covers the rest.
        setOption("hwdec", "videotoolbox")
        setOption("hwdec-codecs", "all")
        // Keep the file open at EOF so the end is a state change, not a teardown.
        setOption("keep-open", "yes")
        setOption("force-window", "no")
        setOption("ytdl", "no")
        setOption("terminal", "no")
        setOption("audio-channels", "auto-safe")
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
    }

    /// Retains a weak back-reference for the C callbacks, which cannot capture Swift context.
    @ObservationIgnored private lazy var box: MPVEngineBox = {
        let box = MPVEngineBox()
        box.engine = self
        return box
    }()

    func destroy() {
        if let renderContext {
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            self.handle = nil
        }
        isReady = false
    }

    // MARK: Render context

    /// Created once the GL view has a context current. Rendering is driven by the view.
    func createRenderContext() {
        guard let handle, renderContext == nil else { return }

        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                // dlsym against the process resolves the GLES symbols mpv asks for.
                return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
            },
            get_proc_address_ctx: nil
        )
        var advanced: CInt = 1

        let apiType = UnsafeMutableRawPointer(
            mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String
        )
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: &initParams),
            mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: &advanced),
            mpv_render_param()
        ]

        var context: OpaquePointer?
        guard mpv_render_context_create(&context, handle, &params) >= 0 else {
            errorMessage = "Could not create the video renderer."
            return
        }
        renderContext = context

        mpv_render_context_set_update_callback(context, { pointer in
            guard let pointer else { return }
            let box = Unmanaged<MPVEngineBox>.fromOpaque(pointer).takeUnretainedValue()
            box.redraw?()
        }, Unmanaged.passUnretained(box).toOpaque())
        box.redraw = { [weak self] in self?.onRedraw?() }
    }

    /// Draws one frame into the currently bound framebuffer. Called from the GL view.
    nonisolated func render(framebuffer: GLint, width: Int32, height: Int32) {
        guard let context = MainActor.assumeIsolated({ renderContext }) else { return }
        var fbo = mpv_opengl_fbo(
            fbo: Int32(framebuffer), w: width, h: height, internal_format: 0
        )
        // GL's origin is bottom-left; mpv renders top-down, so the frame is flipped.
        var flip: CInt = 1
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: &fbo),
            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: &flip),
            mpv_render_param()
        ]
        mpv_render_context_render(context, &params)
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
        var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        pointers.withUnsafeMutableBufferPointer { buffer in
            _ = mpv_command(handle, buffer.baseAddress)
        }
    }

    // MARK: Events

    fileprivate func drainEvents() {
        guard let handle else { return }
        while true {
            guard let event = mpv_wait_event(handle, 0) else { return }
            if event.pointee.event_id == MPV_EVENT_NONE { return }
            handle(event: event)
        }
    }

    private func handle(event: UnsafeMutablePointer<mpv_event>) {
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
    var redraw: (() -> Void)?
}

#endif
