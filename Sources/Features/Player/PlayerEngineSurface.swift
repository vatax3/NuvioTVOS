import Foundation

/// What the player chrome needs from whichever engine is underneath it.
///
/// The chrome — transport bar, track pickers, stats overlay, the episodes and party panels — is
/// 2,000 lines of ported Compose layout in `MPVPlayerView`, and it was written against `MPVEngine`
/// directly. A second engine that could not reuse it would mean a second chrome, which is a
/// permanent divergence: every in-player feature would have to be built twice and would drift.
/// Hence this protocol. It is deliberately **extracted rather than designed** — every member below
/// is one the chrome already reads or calls, with MPVEngine's own signature, so conformance costs
/// `MPVEngine` nothing and the adapter for a new engine has an exact list to satisfy.
///
/// What is **not** here is as deliberate: `start` stays off it. Each engine is constructed and
/// handed its source by its own surface, with its own options (mpv takes a `MPVMetalLayer` and a
/// dozen decode settings; AetherEngine takes `LoadOptions`), and nothing in the chrome starts
/// playback.
///
/// `Observable` is a requirement rather than an accident: the chrome is SwiftUI, and tracking a
/// generic engine's reads only works when the concrete type carries the macro's conformance.
@MainActor
protocol PlayerEngineSurface: AnyObject, Observable {
    // MARK: Transport state

    var isPaused: Bool { get }
    var isBuffering: Bool { get }
    var position: Double { get }
    var duration: Double { get }
    /// Media time up to which the engine holds data, drawn behind the played fill so a stalling
    /// source is visible before it stops.
    var bufferedPosition: Double { get }
    var didEnd: Bool { get }
    var playbackSpeed: Double { get }

    // MARK: Health

    var errorMessage: String? { get }
    /// True once a frame has actually been presented. A running clock with this still false is the
    /// signature of a renderer that cannot draw — the case that looks like a dead app.
    var hasRenderedFrame: Bool { get }
    /// The engine is playing with something silently degraded (mpv: the audio output refused and
    /// the null fallback took over, so the picture runs and nothing is heard). The chrome says so,
    /// because the viewer cannot tell that case from a file with no soundtrack.
    var isSilentlyFallingBack: Bool { get }
    /// The tail of the engine's own log. Without it a black picture gives nothing to go on.
    var logTail: [String] { get }
    /// Whether the failure now on `errorMessage` is one a *different* engine could plausibly play.
    ///
    /// False for a refusal every engine would meet the same way: an origin answering 401/403, a
    /// rate-limited origin (a second player meets the same meter, AetherEngine's AE#377), a
    /// certificate the host declined. Handing those to another engine spends a second connection
    /// to be refused again, and on a connection-capped debrid or IPTV account that is the bug.
    var failureInvitesAnotherEngine: Bool { get }

    // MARK: Tracks

    var audioTracks: [PlayerTrack] { get }
    var subtitleTracks: [PlayerTrack] { get }

    /// The line of subtitle currently drawn, or nil when there is none.
    ///
    /// Only ever compared, never shown: it is the signal that the subtitle has changed, which is
    /// when the line may move without sliding the words out from under whoever is reading them.
    /// See `SubtitlePlacement.settledLift`.
    var currentCueText: String? { get }

    /// Whether the picture being presented is HDR or Dolby Vision.
    ///
    /// Only used to decide the subtitle colour, which is why it is a plain `Bool` and not the
    /// colorimetry: a renderer needs to know that white will be rendered at the panel's PQ peak,
    /// not which transfer function got it there.
    var isHDRVideo: Bool { get }

    // MARK: Chapters

    /// The chapters the container lists, normalised — empty when the file has none, and also when
    /// it has exactly one, which is a start marker rather than something to skip to.
    ///
    /// Both engines demux the file themselves and so already know this: mpv publishes
    /// `chapter-list` and AetherEngine publishes `mediaChapters`. Upstream has to read the
    /// container over range requests because ExoPlayer's Matroska extractor skips chapters, and
    /// that whole file has no counterpart here.
    var chapters: [PlayerChapter] { get }

    /// Seeks to exactly this time rather than to the nearest keyframe.
    ///
    /// Scrubbing wants the keyframe — it is what makes a long drag answer instantly. A chapter
    /// jump does not: landing a few seconds inside the chapter before the one that was picked is
    /// the whole of what the control was asked to avoid.
    func seek(toExactly seconds: Double)

    // MARK: Picture and sound settings the player itself exposes

    var audioDelay: Double { get }
    var subtitleDelay: Double { get }
    var amplificationDb: Int { get }
    var aspectMode: PlayerAspectMode { get }

    // MARK: What the information panel prints

    var streamInfo: PlayerStreamInfo { get }
    /// Machine-readable colorimetry for the display-mode handshake, published apart from
    /// `streamInfo` because that one is text to print. Nil on an engine that drives the display
    /// criteria itself rather than handing them to `DisplayModeMatcher`.
    var videoFormat: DisplayModeMatcher.VideoFormat? { get }

    func liveStats() -> PlayerLiveStats

    /// What the stream-information panel calls this engine.
    ///
    /// It used to be the literal "MPV" in the panel, which was true while the chrome was mpv's
    /// own and became a lie the moment it was shared: a viewer reading the panel would be told the
    /// wrong engine while the other one played. The name has to come from whatever is underneath.
    static var label: String { get }

    // MARK: Capability limits
    //
    // The chrome draws its steppers against these rather than against constants of its own,
    // because they are genuinely per-engine: mpv takes ±3 s of audio delay and 10 dB of
    // post-decode gain, where AetherEngine clamps delay at ±2 s and has no amplification at all
    // (its `volume` stops at unity). A stepper offering a range the engine will refuse is worse
    // than one that stops where the engine does.

    static var audioDelayLimit: Double { get }
    static var subtitleDelayLimit: Double { get }
    static var amplificationLimitDb: Int { get }

    // MARK: Commands

    func togglePause()
    func setPaused(_ paused: Bool)
    func seek(by seconds: Double)
    func seek(to seconds: Double)
    func selectAudioTrack(_ id: Int64)
    func selectSubtitleTrack(_ id: Int64?)
    func addSubtitle(url: String, title: String)
    func setPlaybackSpeed(_ speed: Double)
    func adjustAudioDelay(by seconds: Double)
    func setAudioDelay(_ seconds: Double)
    func adjustSubtitleDelay(by seconds: Double)
    func setSubtitleDelay(_ seconds: Double)
    func setAudioChannels(_ channels: AudioOutputChannels)
    func setAmplification(db: Int)
    func setAspectMode(_ mode: PlayerAspectMode)
    func applySubtitleStyle(_ style: SubtitleStyle, obstructions: SubtitlePlacement.Obstructions)
    func activateAudioSession()
    func destroy()
}

/// What the chrome knows and the picture needs.
///
/// Two values, and both are the chrome's own: where the controls currently sit, so a subtitle line
/// can be lifted clear of them, and the speed in force, which is the viewer's choice unless a
/// watch party is correcting it. An engine surface is handed them at every update rather than
/// reaching up for them, which is what keeps the chrome generic over engines that need neither.
struct PlayerSurfaceContext {
    var subtitleObstructions: SubtitlePlacement.Obstructions
    var playbackSpeed: Double
}

// MARK: - Shared value types

/// The seven picture modes the Android TV player offers, in its order.  The aspect button steps
/// through the list one press at a time, so the sequence is part of the port, not an arbitrary
/// ordering of an enum.
///
/// Lifted out of `MPVEngine` when the second engine arrived: that type sits behind
/// `#if canImport(Libmpv)`, so a chrome generic over engines could not name it.
enum PlayerAspectMode: String, CaseIterable, Identifiable {
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

    var next: PlayerAspectMode {
        let all = PlayerAspectMode.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// The mode playback starts in, from the viewer's `resize_mode` preference.
    ///
    /// Android's five values do not map one to one onto the seven offered in the player —
    /// `slightZoom` and `cinemaZoom` are steps the viewer reaches by cycling, not defaults —
    /// so the two zoom cases both land on `crop`, which is what "zoom to fill" means.
    init(resizeMode: ResizeMode) {
        switch resizeMode {
        case .fit: self = .fit
        case .fill: self = .stretch
        case .zoom: self = .crop
        case .fixedWidth: self = .fitWidth
        case .fixedHeight: self = .fitHeight
        }
    }
}

extension PlayerEngineSurface {
    /// Most engines seek exactly already — AetherEngine hands AVPlayer a zero tolerance either
    /// side — so this is only overridden where the distinction exists.
    func seek(toExactly seconds: Double) { seek(to: seconds) }
}

/// A selectable track the source carries, for the transport menus.
struct PlayerTrack: Identifiable, Hashable {
    let id: Int64
    let title: String
    let language: String?
    var isSelected: Bool
    /// mpv's `external` flag: true for the addon subtitles loaded with `sub-add`, false for
    /// what the container itself carries. It is the difference a viewer most wants to see
    /// in the list, because it predicts whether the timing will match this exact release.
    let isExternal: Bool
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    /// `subrip`, `ass`, `webvtt`, `eac3`, `dts`… as the demuxer names it.
    let codec: String?
    let channelCount: Int?

    var displayName: String {
        let label = title.nilIfBlank ?? MediaLanguage.named(language) ?? "Track \(id)"
        guard let language, title.nilIfBlank != nil else { return label }
        return "\(label) · \(language.uppercased())"
    }

    /// The second line of a track card: where it came from, what it is, and how it is
    /// flagged. Everything here is already in the demuxer's own metadata.
    var details: [String] {
        var parts: [String] = [isExternal ? "Addon" : "Built-in"]
        if let codec = codec?.nilIfBlank { parts.append(Self.formatName(codec)) }
        if let channelCount { parts.append("\(channelCount) ch") }
        if isDefault { parts.append("Default") }
        if isForced { parts.append("Forced") }
        if isHearingImpaired { parts.append("SDH") }
        return parts
    }

    private static func formatName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "subrip": return "SRT"
        case "webvtt": return "VTT"
        case "ass", "ssa": return "ASS"
        case "hdmv_pgs_subtitle": return "PGS"
        case "dvd_subtitle": return "VobSub"
        case "mov_text": return "TX3G"
        default: return codec.uppercased()
        }
    }
}

extension Array where Element == PlayerTrack {
    /// The same tracks, with `isSelected` set from one identifier and nowhere else.
    ///
    /// `PlayerChrome` reads the current track off this flag alone, so an engine whose active track
    /// is a separately published value has to re-mark the list every time that value moves — not
    /// only when the list itself is republished. Deriving the flag inside the track-list observer
    /// is how the Aether path came to leave *Off* checked while a subtitle was on screen.
    func marking(selected id: Int64?) -> [PlayerTrack] {
        map { track in
            guard track.isSelected != (track.id == id) else { return track }
            var marked = track
            marked.isSelected = track.id == id
            return marked
        }
    }
}

/// What the information panel prints about the stream.
struct PlayerStreamInfo: Hashable {
    var videoCodec: String?
    var resolution: String?
    var frameRate: String?
    /// The colorimetry of the **source**.
    var sourceRange: String?
    /// The colorimetry actually being **presented**, after any tone-mapping. When this differs
    /// from the source the picture is being converted, which is the difference between "HDR
    /// reaching the panel" and "HDR flattened to SDR first" — and it is not otherwise observable
    /// from the sofa. Reported as the light being wrong, too dark or too bright, and varying by
    /// scene. Equal to `sourceRange` on an engine that never converts.
    var outputRange: String?
    var audioCodec: String?
    var audioChannels: String?
    var audioOutput: String?
    /// Which pipeline inside the engine is actually serving, for an engine that has more than one.
    /// nil on mpv, which has exactly one and would only ever repeat itself here.
    ///
    /// Worth a row of its own because it is the difference between a session that is doing what
    /// this engine was adopted for and one that quietly is not: a remux served to AVPlayer keeps
    /// the audio bitstream intact, and a session that fell back to software decode does not.
    var pipeline: String?

    /// The same facts as some of the strings above, unformatted.
    ///
    /// Badge rules match on tokens — `2160p`, `5.1`, `10bit` — and the strings above are already
    /// composed for a human to read ("3840 × 2160", "6 ch"). Parsing them back would be a
    /// formatter and a parser kept in step for no reason, since both engines have the numbers
    /// immediately before they format them. Nothing but `playbackBadgeTokens` reads these.
    var videoWidth: Int?
    var videoHeight: Int?
    var audioChannelCount: Int?
    var bitDepth: Int?
}

/// The three readings the stats overlay needs from the engine. Everything else it draws comes
/// from the process itself — see `PlaybackStatsSampler`.
struct PlayerLiveStats {
    var bufferSeconds: Double?
    var networkBitsPerSecond: Double?
    var streamBitsPerSecond: Double?
}
