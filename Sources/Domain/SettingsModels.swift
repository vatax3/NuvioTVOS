import Foundation

// Ports of the enums backing NuvioTV's settings DataStores. Raw values match the Android
// persisted strings so a future sync/import path stays wire-compatible.

protocol SettingsOption: RawRepresentable, CaseIterable, Codable, Identifiable, Hashable
where RawValue == String {
    var displayName: String { get }
}

extension SettingsOption {
    var id: String { rawValue }
}

// MARK: - Playback engine

enum InternalPlayerEngine: String, SettingsOption {
    case exoplayer = "EXOPLAYER"
    case mpv = "MPV"
    var displayName: String { self == .exoplayer ? "Default (AVFoundation)" : "MPV (extended codecs)" }
    var summary: String {
        switch self {
        case .exoplayer: return L10n.text("option.engine_avf_sub", fallback: "System pipeline. Best power efficiency and HDR passthrough.")
        case .mpv: return L10n.text("option.engine_mpv_sub", fallback: "Software pipeline for containers AVFoundation refuses.")
        }
    }
}

enum PlayerPreference: String, SettingsOption {
    case internalPlayer = "INTERNAL"
    case externalPlayer = "EXTERNAL"
    case askEveryTime = "ASK"
    var displayName: String {
        switch self {
        case .internalPlayer: return L10n.text("option.internal_player", fallback: "Internal player")
        case .externalPlayer: return L10n.text("option.external_player", fallback: "External player")
        case .askEveryTime: return L10n.text("option.ask_every_time", fallback: "Ask every time")
        }
    }
}


enum ResizeMode: String, SettingsOption {
    case fit = "FIT"
    case fill = "FILL"
    case zoom = "ZOOM"
    case fixedWidth = "FIXED_WIDTH"
    case fixedHeight = "FIXED_HEIGHT"
    var displayName: String {
        switch self {
        case .fit: return L10n.text("option.fit", fallback: "Fit")
        case .fill: return L10n.text("option.fill", fallback: "Stretch to fill")
        case .zoom: return L10n.text("option.zoom", fallback: "Zoom to fill")
        case .fixedWidth: return L10n.text("option.fixed_width", fallback: "Fixed width")
        case .fixedHeight: return L10n.text("option.fixed_height", fallback: "Fixed height")
        }
    }
}

enum FrameRateMatchingMode: String, SettingsOption {
    case off = "OFF"
    /// Match on the way in and leave the panel there.
    case start = "START"
    /// Match on the way in, hand the display back on the way out.
    case startStop = "START_STOP"

    var displayName: String {
        switch self {
        case .off: return L10n.text("option.off", fallback: "Off")
        case .start: return L10n.text("option.on_start", fallback: "On playback start")
        case .startStop: return L10n.text("option.start_stop", fallback: "Start and stop")
        }
    }

    var summary: String {
        switch self {
        case .off: return L10n.text("option.afr_off_sub", fallback: "Leave the display in whatever mode tvOS is using")
        case .start: return L10n.text("option.afr_start_sub", fallback: "Switch the panel to the film's frame rate and stay there")
        case .startStop: return L10n.text("option.afr_startstop_sub", fallback: "Switch for playback, then restore the previous mode")
        }
    }
}

/// Port of `MpvHardwareDecodeMode`, with Android's `mediacodec` values swapped for their
/// VideoToolbox equivalents.
///
/// `hardwareDirect` is the default, as on Android: with the Vulkan/MoltenVK renderer the
/// zero-copy VideoToolbox path is the supported one. The copy variants are the fallback for a
/// file the direct path refuses.
enum MpvHardwareDecodeMode: String, SettingsOption {
    case legacyDirectCopy = "LEGACY_DIRECT_COPY"
    case autoSafe = "AUTO_SAFE"
    case hardwareCopy = "HARDWARE_COPY"
    case hardwareDirect = "HARDWARE_DIRECT"
    case disabled = "DISABLED"

    var displayName: String {
        switch self {
        case .legacyDirectCopy: return L10n.text("option.hwdec_legacy", fallback: "Legacy (direct, then copy)")
        case .autoSafe: return L10n.text("option.hwdec_autosafe", fallback: "Auto (safe)")
        case .hardwareCopy: return L10n.text("option.hwdec_copy", fallback: "Hardware (copy)")
        case .hardwareDirect: return L10n.text("option.hwdec_direct", fallback: "Hardware (direct)")
        case .disabled: return L10n.text("option.hwdec_off", fallback: "Disabled (software)")
        }
    }

    var summary: String {
        switch self {
        case .legacyDirectCopy: return L10n.text("option.hwdec_legacy_sub", fallback: "Tries direct mapping first, falls back to a copy")
        case .autoSafe: return L10n.text("option.hwdec_autosafe_sub", fallback: "Lets mpv pick whatever it considers safe")
        case .hardwareCopy: return L10n.text("option.hwdec_copy_sub", fallback: "VideoToolbox decode, frames copied back through system memory")
        case .hardwareDirect: return L10n.text("option.hwdec_direct_sub", fallback: "Zero-copy VideoToolbox. The fast path on Apple TV.")
        case .disabled: return L10n.text("option.hwdec_off_sub", fallback: "Software decode. Slowest, but always draws.")
        }
    }

    /// The value handed to mpv's `hwdec` option.
    var mpvValue: String {
        switch self {
        case .legacyDirectCopy: return "videotoolbox,videotoolbox-copy"
        case .autoSafe: return "auto-safe"
        case .hardwareCopy: return "videotoolbox-copy"
        case .hardwareDirect: return "videotoolbox"
        case .disabled: return "no"
        }
    }
}

// MARK: - Audio

/// Which of libmpv's audio outputs to drive.
///
/// `audiounit` is mpv's older Apple output, built on a RemoteIO AudioUnit. It works on iOS and
/// in the tvOS simulator, and refuses to open on Apple TV hardware — the unit fails to start,
/// `audio-fallback-to-null` swallows that into a silent picture, and nothing in the interface
/// says why. `avfoundation` is the newer driver, built on `AVSampleBufferAudioRenderer`, which
/// is the path Apple actually supports on a television. Hence the default order.
enum MpvAudioOutput: String, SettingsOption {
    case automatic = "AUTO"
    case avfoundation = "AVFOUNDATION"
    case audiounit = "AUDIOUNIT"

    var displayName: String {
        switch self {
        case .automatic: return L10n.text("option.automatic", fallback: "Automatic")
        case .avfoundation: return "AVFoundation"
        case .audiounit: return "AudioUnit"
        }
    }

    var summary: String {
        switch self {
        case .automatic: return L10n.text("option.ao_auto_sub", fallback: "Try AVFoundation, then AudioUnit")
        case .avfoundation: return L10n.text("option.ao_avf_sub", fallback: "AVSampleBufferAudioRenderer — the supported path on Apple TV")
        case .audiounit: return L10n.text("option.ao_au_sub", fallback: "RemoteIO — works on iOS, refused by some Apple TV routes")
        }
    }

    /// mpv takes a priority list and walks it until one output initialises.
    var mpvValue: String {
        switch self {
        case .automatic: return "avfoundation,audiounit"
        case .avfoundation: return "avfoundation"
        case .audiounit: return "audiounit"
        }
    }
}

enum AudioOutputChannels: String, SettingsOption {
    case auto = "AUTO"
    case stereo = "STEREO"
    case surround51 = "SURROUND_5_1"
    case surround71 = "SURROUND_7_1"
    var displayName: String {
        switch self {
        case .auto: return L10n.text("option.auto", fallback: "Auto")
        case .stereo: return L10n.text("option.stereo", fallback: "Stereo")
        case .surround51: return "5.1"
        case .surround71: return "7.1"
        }
    }

    var mpvValue: String {
        switch self {
        case .auto: return "auto-safe"
        case .stereo: return "stereo"
        case .surround51: return "5.1"
        case .surround71: return "7.1"
        }
    }

    var summary: String {
        switch self {
        case .auto: return L10n.text("option.ch_auto_sub", fallback: "Follow whatever layout the Apple TV reports it can take")
        case .stereo: return L10n.text("option.ch_stereo_sub", fallback: "Always downmix — the layout every television accepts")
        case .surround51: return L10n.text("option.ch_51_sub", fallback: "Send 5.1 to the receiver")
        case .surround71: return L10n.text("option.ch_71_sub", fallback: "Send 7.1 to the receiver")
        }
    }
}

// MARK: - Subtitles

/// How far the viewer's subtitle style reaches into subtitles that carry their own.
///
/// SRT and WebVTT have no styling of their own, so every appearance setting applies. ASS/SSA —
/// which is what most anime and a good share of remuxes ship — carries a full script: fonts,
/// colours, positions, sign placement. mpv honours that script by default, which is why the
/// appearance settings looked broken on some files and fine on others.
enum SubtitleStyleOverride: String, SettingsOption {
    case respect = "NO"
    case scale = "SCALE"
    case force = "FORCE"

    var displayName: String {
        switch self {
        case .respect: return L10n.text("option.ass_respect", fallback: "Keep the file's own style")
        case .scale: return L10n.text("option.ass_scale", fallback: "Apply size and position only")
        case .force: return L10n.text("option.ass_force", fallback: "Apply my style to everything")
        }
    }

    var summary: String {
        switch self {
        case .respect: return L10n.text("option.ass_respect_sub", fallback: "ASS/SSA subtitles keep their fonts, colours and sign placement")
        case .scale: return L10n.text("option.ass_scale_sub", fallback: "Resize and reposition styled subtitles, leave their colours alone")
        case .force: return L10n.text("option.ass_force_sub", fallback: "Override styled subtitles too — signs and karaoke lose their placement")
        }
    }

    var mpvValue: String {
        switch self {
        case .respect: return "no"
        case .scale: return "scale"
        case .force: return "force"
        }
    }
}


enum SubtitleOrganizationMode: String, SettingsOption {
    case byLanguage = "BY_LANGUAGE"
    case byAddon = "BY_ADDON"
    case flat = "FLAT"
    var displayName: String {
        switch self {
        case .byLanguage: return L10n.text("option.group_language", fallback: "Group by language")
        case .byAddon: return L10n.text("option.group_addon", fallback: "Group by addon")
        case .flat: return L10n.text("option.group_flat", fallback: "Flat list")
        }
    }
}

// MARK: - Auto-play

enum StreamAutoPlayMode: String, SettingsOption {
    case off = "OFF"
    case first = "FIRST"
    case matchRegex = "REGEX"
    case preferredQuality = "PREFERRED_QUALITY"
    var displayName: String {
        switch self {
        case .off: return L10n.text("option.autoplay_off", fallback: "Off — always show the source list")
        case .first: return L10n.text("option.autoplay_first", fallback: "First available source")
        case .matchRegex: return L10n.text("option.autoplay_regex", fallback: "First source matching a pattern")
        case .preferredQuality: return L10n.text("option.autoplay_quality", fallback: "Best match for preferred quality")
        }
    }
}

enum StreamAutoPlaySource: String, SettingsOption {
    case anyAddon = "ANY"
    case debridOnly = "DEBRID_ONLY"
    case cachedOnly = "CACHED_ONLY"
    var displayName: String {
        switch self {
        case .anyAddon: return L10n.text("option.any_source", fallback: "Any source")
        case .debridOnly: return L10n.text("option.debrid_only", fallback: "Debrid sources only")
        case .cachedOnly: return L10n.text("option.cached_only", fallback: "Cached sources only")
        }
    }
}

enum NextEpisodeThresholdMode: String, SettingsOption {
    case percent = "PERCENT"
    case minutesBeforeEnd = "MINUTES"
    var displayName: String {
        self == .percent ? "Percentage watched" : "Minutes before end"
    }
}

// MARK: - Library

/// How the saved-titles grid is ordered. Keys match Android's `LibrarySortOption`.
///
/// Upstream also carries a `default` that means "whatever order the tracking provider returned".
/// It is not offered here: our grid is the local library, which has no provider order to defer
/// to, and an option that silently means "added, newest first" would be the same thing twice.
enum LibrarySortOption: String, SettingsOption, CaseIterable {
    case recentlyAdded = "added_desc"
    case firstAdded = "added_asc"
    case titleAscending = "title_asc"
    case titleDescending = "title_desc"

    var displayName: String {
        switch self {
        case .recentlyAdded: return L10n.text("option.recently_added", fallback: "Recently added")
        case .firstAdded: return L10n.text("option.first_added", fallback: "First added")
        case .titleAscending: return L10n.text("option.title_asc", fallback: "Title, A–Z")
        case .titleDescending: return L10n.text("option.title_desc", fallback: "Title, Z–A")
        }
    }
}

extension Array where Element == SavedLibraryItem {
    /// Sorting is by the item, not by the view, so the grid and anything else reading the
    /// library agree on an order.
    func sorted(by option: LibrarySortOption) -> [SavedLibraryItem] {
        switch option {
        case .recentlyAdded: return sorted { $0.addedAt > $1.addedAt }
        case .firstAdded: return sorted { $0.addedAt < $1.addedAt }
        case .titleAscending:
            return sorted { $0.preview.name.localizedStandardCompare($1.preview.name) == .orderedAscending }
        case .titleDescending:
            return sorted { $0.preview.name.localizedStandardCompare($1.preview.name) == .orderedDescending }
        }
    }
}

// MARK: - Ratings visibility

/// Whether scores are drawn on Home. `SHOW_ALL`/`HIDE_ALL` upstream.
enum HomeRatingsVisibility: String, SettingsOption {
    case showAll = "SHOW_ALL"
    case hideAll = "HIDE_ALL"

    var displayName: String {
        switch self {
        case .showAll: return L10n.text("option.ratings_show", fallback: "Show ratings")
        case .hideAll: return L10n.text("option.ratings_hide", fallback: "Hide ratings")
        }
    }

    var showsRatings: Bool { self == .showAll }
}

/// Whether scores are drawn on a detail screen, and on its episodes.
///
/// The middle case is the one worth having: an episode score is a spoiler in itself — a 9.6
/// three episodes ahead says something happens there — so hiding it until the episode has been
/// watched protects the viewer without hiding the title's own rating.
enum DetailRatingsVisibility: String, SettingsOption {
    case showAll = "SHOW_ALL"
    case hideUnwatchedEpisodes = "HIDE_UNWATCHED_EPISODES"
    case hideEpisodes = "HIDE_EPISODES"
    case hideAll = "HIDE_ALL"

    var displayName: String {
        switch self {
        case .showAll: return L10n.text("option.ratings_all", fallback: "Show everything")
        case .hideUnwatchedEpisodes: return L10n.text("option.ratings_until_watched", fallback: "Hide until watched")
        case .hideEpisodes: return L10n.text("option.ratings_hide_episodes", fallback: "Hide episode scores")
        case .hideAll: return L10n.text("option.ratings_hide", fallback: "Hide ratings")
        }
    }

    var summary: String {
        switch self {
        case .showAll: return L10n.text("option.ratings_all_sub", fallback: "Titles and episodes both show their score")
        case .hideUnwatchedEpisodes: return L10n.text("option.ratings_until_watched_sub", fallback: "An episode score appears once you have watched it")
        case .hideEpisodes: return L10n.text("option.ratings_hide_episodes_sub", fallback: "Only the title keeps its score")
        case .hideAll: return L10n.text("option.ratings_hide_sub", fallback: "No score anywhere on the screen")
        }
    }

    /// The title's own rating, in the hero.
    var showsTitleRating: Bool { self != .hideAll }

    /// One episode's rating, which depends on whether it has been watched.
    func showsEpisodeRating(isWatched: Bool) -> Bool {
        switch self {
        case .showAll: return true
        case .hideUnwatchedEpisodes: return isWatched
        case .hideEpisodes, .hideAll: return false
        }
    }
}

// MARK: - Dolby Vision


// MARK: - Buffering


// MARK: - Layout

enum DiscoverLocation: String, SettingsOption {
    case sidebar = "SIDEBAR"
    case searchTab = "SEARCH"
    case off = "OFF"
    var displayName: String {
        switch self {
        case .sidebar: return L10n.text("option.discover_sidebar", fallback: "Its own sidebar entry")
        case .searchTab: return L10n.text("option.discover_search", fallback: "Inside Search")
        case .off: return L10n.text("option.hidden", fallback: "Hidden")
        }
    }
}

enum ContinueWatchingSortMode: String, SettingsOption {
    case recentlyWatched = "RECENT"
    case recentlyAdded = "ADDED"
    case alphabetical = "ALPHA"
    var displayName: String {
        switch self {
        case .recentlyWatched: return L10n.text("option.recently_watched", fallback: "Recently watched")
        case .recentlyAdded: return L10n.text("option.recently_added", fallback: "Recently added")
        case .alphabetical: return "A–Z"
        }
    }
}

/// Where an inline trailer would play on focus, if one could.
///
/// Kept without a reader, alone among the five enums that were in this position, because it is
/// the only one that describes something we *want* and cannot have rather than a problem another
/// engine has. tvOS has no supported YouTube playback path — no web view, and AVPlayer cannot
/// resolve a watch page — so `TrailerLauncher` hands off to the YouTube app instead. This is the
/// shape the setting takes on the day that changes.
///
/// The other four went: decoder priority and the libass renderer choice are ExoPlayer questions
/// (mpv *is* libass, and hardware decoding is `hwdec`), the Dolby Vision profile 7 modes exist to
/// work around an engine that cannot play dual-layer DV, and the cache-size mode is part of the
/// buffer-tuning surface the audit already records as given up with ExoPlayer.
enum FocusedPosterTrailerTarget: String, SettingsOption {
    case posterCard = "POSTER"
    case heroOnly = "HERO"
    var displayName: String { self == .posterCard ? "Poster cards" : "Hero only" }
}

enum SettingsUIStyle: String, SettingsOption {
    case rail = "RAIL"
    case list = "LIST"
    var displayName: String { self == .rail ? "Two-pane rail" : "Single list" }
}

// MARK: - Tracking

enum WatchProgressSource: String, SettingsOption {
    case local = "LOCAL"
    case trakt = "TRAKT"
    case simkl = "SIMKL"
    var displayName: String {
        switch self {
        case .local: return L10n.text("option.this_device", fallback: "This device")
        case .trakt: return "Trakt"
        case .simkl: return "Simkl"
        }
    }
}

enum LibrarySourceMode: String, SettingsOption {
    case local = "LOCAL"
    case trakt = "TRAKT"
    case simkl = "SIMKL"
    var displayName: String {
        switch self {
        case .local: return L10n.text("option.this_device", fallback: "This device")
        case .trakt: return L10n.text("option.trakt_collection", fallback: "Trakt collection")
        case .simkl: return L10n.text("option.simkl_list", fallback: "Simkl list")
        }
    }
}

enum MoreLikeThisSource: String, SettingsOption {
    case addonCatalog = "ADDON"
    case tmdb = "TMDB"
    case trakt = "TRAKT"
    var displayName: String {
        switch self {
        case .addonCatalog: return L10n.text("option.addon_catalog", fallback: "Addon catalog")
        case .tmdb: return "TMDB"
        case .trakt: return "Trakt"
        }
    }
}

// MARK: - Stream badges

enum StreamBadgePlacement: String, SettingsOption {
    case inline = "INLINE"
    case belowTitle = "BELOW_TITLE"
    case hidden = "HIDDEN"
    var displayName: String {
        switch self {
        case .inline: return L10n.text("option.badge_inline", fallback: "Inline with the title")
        case .belowTitle: return L10n.text("option.badge_below", fallback: "On their own line")
        case .hidden: return L10n.text("option.hidden", fallback: "Hidden")
        }
    }
}

// MARK: - Debrid stream shaping (port of DebridSettings.kt)

enum DebridStreamSortMode: String, SettingsOption {
    case `default` = "DEFAULT"
    case qualityDesc = "QUALITY_DESC"
    case sizeDesc = "SIZE_DESC"
    case sizeAsc = "SIZE_ASC"
    var displayName: String {
        switch self {
        case .default: return L10n.text("option.sort_default", fallback: "Addon order")
        case .qualityDesc: return L10n.text("option.sort_quality", fallback: "Highest quality first")
        case .sizeDesc: return L10n.text("option.sort_size_desc", fallback: "Largest file first")
        case .sizeAsc: return L10n.text("option.sort_size_asc", fallback: "Smallest file first")
        }
    }
}

enum DebridStreamMinimumQuality: String, SettingsOption {
    case any = "ANY"
    case p720 = "P720"
    case p1080 = "P1080"
    case p2160 = "P2160"

    var minResolution: Int {
        switch self {
        case .any: return 0
        case .p720: return 720
        case .p1080: return 1080
        case .p2160: return 2160
        }
    }

    var displayName: String { self == .any ? "Any" : "\(minResolution)p and above" }
}

enum DebridStreamFeatureFilter: String, SettingsOption {
    case any = "ANY"
    case exclude = "EXCLUDE"
    case only = "ONLY"
    var displayName: String {
        switch self {
        case .any: return L10n.text("option.filter_allow", fallback: "Allow")
        case .exclude: return L10n.text("option.filter_exclude", fallback: "Exclude")
        case .only: return L10n.text("option.filter_only", fallback: "Only")
        }
    }
}

enum DebridStreamCodecFilter: String, SettingsOption {
    case any = "ANY"
    case h264 = "H264"
    case hevc = "HEVC"
    case av1 = "AV1"
    var displayName: String {
        switch self {
        case .any: return L10n.text("option.any_codec", fallback: "Any codec")
        case .h264: return "H.264 / AVC"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        }
    }
}

enum DebridStreamResolution: String, SettingsOption {
    case p2160 = "P2160", p1440 = "P1440", p1080 = "P1080", p720 = "P720"
    case p576 = "P576", p480 = "P480", p360 = "P360", unknown = "UNKNOWN"

    var displayName: String { self == .unknown ? L10n.text("option.unknown", fallback: "Unknown") : "\(value)p" }

    var value: Int {
        switch self {
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p576: return 576
        case .p480: return 480
        case .p360: return 360
        case .unknown: return 0
        }
    }

    static let defaultOrder: [DebridStreamResolution] = [.p2160, .p1440, .p1080, .p720, .p576, .p480, .p360, .unknown]
}

enum DebridStreamQuality: String, SettingsOption {
    case blurayRemux = "BLURAY_REMUX", bluray = "BLURAY", webDl = "WEB_DL", webrip = "WEBRIP"
    case hdrip = "HDRIP", hcHdRip = "HD_RIP", dvdrip = "DVDRIP", hdtv = "HDTV"
    case cam = "CAM", ts = "TS", tc = "TC", scr = "SCR", unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .blurayRemux: return "BluRay REMUX"
        case .bluray: return "BluRay"
        case .webDl: return "WEB-DL"
        case .webrip: return "WEBRip"
        case .hdrip: return "HDRip"
        case .hcHdRip: return "HC HD-Rip"
        case .dvdrip: return "DVDRip"
        case .hdtv: return "HDTV"
        case .cam: return "CAM"
        case .ts: return "TS"
        case .tc: return "TC"
        case .scr: return "SCR"
        case .unknown: return L10n.text("option.unknown", fallback: "Unknown")
        }
    }

    static let defaultOrder: [DebridStreamQuality] = [
        .blurayRemux, .bluray, .webDl, .webrip, .hdrip, .hcHdRip, .dvdrip, .hdtv, .cam, .ts, .tc, .scr, .unknown
    ]
}

enum DebridStreamVisualTag: String, SettingsOption {
    case hdrDv = "HDR_DV", dvOnly = "DV_ONLY", hdrOnly = "HDR_ONLY", hdr10Plus = "HDR10_PLUS"
    case hdr10 = "HDR10", dv = "DV", hdr = "HDR", hlg = "HLG", tenBit = "TEN_BIT"
    case threeD = "THREE_D", imax = "IMAX", ai = "AI", sdr = "SDR", hou = "H_OU", hsbs = "H_SBS"
    case unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .hdrDv: return "HDR+DV"
        case .dvOnly: return "DV Only"
        case .hdrOnly: return "HDR Only"
        case .hdr10Plus: return "HDR10+"
        case .hdr10: return "HDR10"
        case .dv: return "DV"
        case .hdr: return "HDR"
        case .hlg: return "HLG"
        case .tenBit: return "10bit"
        case .threeD: return "3D"
        case .imax: return "IMAX"
        case .ai: return "AI"
        case .sdr: return "SDR"
        case .hou: return "H-OU"
        case .hsbs: return "H-SBS"
        case .unknown: return L10n.text("option.unknown", fallback: "Unknown")
        }
    }

    static let defaultOrder: [DebridStreamVisualTag] = [
        .hdrDv, .dvOnly, .hdrOnly, .hdr10Plus, .hdr10, .dv, .hdr, .hlg,
        .tenBit, .imax, .sdr, .threeD, .ai, .hou, .hsbs, .unknown
    ]
}

enum DebridStreamAudioTag: String, SettingsOption {
    case atmos = "ATMOS", ddPlus = "DD_PLUS", dd = "DD", dtsX = "DTS_X", dtsHdMa = "DTS_HD_MA"
    case dtsHd = "DTS_HD", dtsEs = "DTS_ES", dts = "DTS", truehd = "TRUEHD"
    case opus = "OPUS", flac = "FLAC", aac = "AAC", unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .atmos: return "Atmos"
        case .ddPlus: return "DD+"
        case .dd: return "DD"
        case .dtsX: return "DTS:X"
        case .dtsHdMa: return "DTS-HD MA"
        case .dtsHd: return "DTS-HD"
        case .dtsEs: return "DTS-ES"
        case .dts: return "DTS"
        case .truehd: return "TrueHD"
        case .opus: return "OPUS"
        case .flac: return "FLAC"
        case .aac: return "AAC"
        case .unknown: return L10n.text("option.unknown", fallback: "Unknown")
        }
    }

    static let defaultOrder: [DebridStreamAudioTag] = [
        .atmos, .ddPlus, .dd, .dtsX, .dtsHdMa, .dtsHd, .dtsEs, .dts, .truehd, .opus, .flac, .aac, .unknown
    ]
}

enum DebridStreamAudioChannel: String, SettingsOption {
    case ch20 = "CH_2_0", ch51 = "CH_5_1", ch61 = "CH_6_1", ch71 = "CH_7_1", unknown = "UNKNOWN"
    var displayName: String {
        switch self {
        case .ch20: return "2.0"
        case .ch51: return "5.1"
        case .ch61: return "6.1"
        case .ch71: return "7.1"
        case .unknown: return L10n.text("option.unknown", fallback: "Unknown")
        }
    }
    static let defaultOrder: [DebridStreamAudioChannel] = [.ch71, .ch61, .ch51, .ch20, .unknown]
}

enum DebridStreamEncode: String, SettingsOption {
    case av1 = "AV1", hevc = "HEVC", avc = "AVC", xvid = "XVID", divx = "DIVX", unknown = "UNKNOWN"
    var displayName: String {
        switch self {
        case .av1: return "AV1"
        case .hevc: return "HEVC"
        case .avc: return "AVC"
        case .xvid: return "XviD"
        case .divx: return "DivX"
        case .unknown: return L10n.text("option.unknown", fallback: "Unknown")
        }
    }
    static let defaultOrder: [DebridStreamEncode] = [.av1, .hevc, .avc, .xvid, .divx, .unknown]
}

enum DebridStreamLanguage: String, SettingsOption {
    case en, hi, it, es, fr, de, pt, pl, cs, la, ja, ko, zh, multi, unknown

    var displayName: String {
        switch self {
        case .en: return L10n.text("option.lang_en", fallback: "English")
        case .hi: return L10n.text("option.lang_hi", fallback: "Hindi")
        case .it: return L10n.text("option.lang_it", fallback: "Italian")
        case .es: return L10n.text("option.lang_es", fallback: "Spanish")
        case .fr: return L10n.text("option.lang_fr", fallback: "French")
        case .de: return L10n.text("option.lang_de", fallback: "German")
        case .pt: return L10n.text("option.lang_pt", fallback: "Portuguese")
        case .pl: return L10n.text("option.lang_pl", fallback: "Polish")
        case .cs: return L10n.text("option.lang_cs", fallback: "Czech")
        case .la: return "Latino"
        case .ja: return L10n.text("option.lang_ja", fallback: "Japanese")
        case .ko: return L10n.text("option.lang_ko", fallback: "Korean")
        case .zh: return L10n.text("option.lang_zh", fallback: "Chinese")
        case .multi: return "Multi"
        case .unknown: return L10n.text("option.unknown", fallback: "Unknown")
        }
    }
}

enum DebridStreamSortKey: String, SettingsOption {
    case resolution = "RESOLUTION", quality = "QUALITY", visualTag = "VISUAL_TAG"
    case audioTag = "AUDIO_TAG", audioChannel = "AUDIO_CHANNEL", encode = "ENCODE"
    case size = "SIZE", language = "LANGUAGE", releaseGroup = "RELEASE_GROUP"

    var displayName: String {
        switch self {
        case .resolution: return L10n.text("option.resolution", fallback: "Resolution")
        case .quality: return L10n.text("option.quality", fallback: "Quality")
        case .visualTag: return L10n.text("option.visual_tag", fallback: "Visual tag")
        case .audioTag: return "Audio"
        case .audioChannel: return L10n.text("option.audio_channel", fallback: "Audio channel")
        case .encode: return L10n.text("option.encode", fallback: "Encode")
        case .size: return L10n.text("option.size", fallback: "Size")
        case .language: return L10n.text("option.language", fallback: "Language")
        case .releaseGroup: return L10n.text("option.release_group", fallback: "Release group")
        }
    }
}

enum DebridStreamSortDirection: String, SettingsOption {
    case asc = "ASC", desc = "DESC"
    var displayName: String { self == .asc ? "Ascending" : "Descending" }
}

struct DebridStreamSortCriterion: Codable, Hashable, Identifiable {
    var key: DebridStreamSortKey = .resolution
    var direction: DebridStreamSortDirection = .desc
    var id: String { key.rawValue }

    static let defaultOrder: [DebridStreamSortCriterion] = [
        .init(key: .resolution, direction: .desc),
        .init(key: .quality, direction: .desc),
        .init(key: .visualTag, direction: .desc),
        .init(key: .audioTag, direction: .desc),
        .init(key: .audioChannel, direction: .desc),
        .init(key: .encode, direction: .desc),
        .init(key: .size, direction: .desc)
    ]
}

/// Port of `DebridStreamPreferences` — the full preferred/required/excluded matrix.
struct DebridStreamPreferences: Codable, Hashable {
    var maxResults: Int = 0
    var maxPerResolution: Int = 0
    var maxPerQuality: Int = 0
    var sizeMinGb: Int = 0
    var sizeMaxGb: Int = 0

    var preferredResolutions: [DebridStreamResolution] = DebridStreamResolution.defaultOrder
    var requiredResolutions: [DebridStreamResolution] = []
    var excludedResolutions: [DebridStreamResolution] = []

    var preferredQualities: [DebridStreamQuality] = DebridStreamQuality.defaultOrder
    var requiredQualities: [DebridStreamQuality] = []
    var excludedQualities: [DebridStreamQuality] = []

    var preferredVisualTags: [DebridStreamVisualTag] = DebridStreamVisualTag.defaultOrder
    var requiredVisualTags: [DebridStreamVisualTag] = []
    var excludedVisualTags: [DebridStreamVisualTag] = []

    var preferredAudioTags: [DebridStreamAudioTag] = DebridStreamAudioTag.defaultOrder
    var requiredAudioTags: [DebridStreamAudioTag] = []
    var excludedAudioTags: [DebridStreamAudioTag] = []

    var preferredAudioChannels: [DebridStreamAudioChannel] = DebridStreamAudioChannel.defaultOrder
    var requiredAudioChannels: [DebridStreamAudioChannel] = []
    var excludedAudioChannels: [DebridStreamAudioChannel] = []

    var preferredEncodes: [DebridStreamEncode] = DebridStreamEncode.defaultOrder
    var requiredEncodes: [DebridStreamEncode] = []
    var excludedEncodes: [DebridStreamEncode] = []

    var preferredLanguages: [DebridStreamLanguage] = []
    var requiredLanguages: [DebridStreamLanguage] = []
    var excludedLanguages: [DebridStreamLanguage] = []

    var requiredReleaseGroups: [String] = []
    var excludedReleaseGroups: [String] = []

    var sortCriteria: [DebridStreamSortCriterion] = []
}

// MARK: - Debrid providers

/// A settings option whose `UNKNOWN` case means "the parser found nothing", not a value.
///
/// Every stream attribute carries one, and a template that printed L10n.text("option.unknown", fallback: "Unknown") wherever a release
/// name omitted the codec would be worse than printing nothing — so the templates read through
/// this rather than `displayName`.
protocol StreamAttributeOption: SettingsOption {
    static var unknownCase: Self { get }
}

extension StreamAttributeOption {
    var labelUnlessUnknown: String? { self == Self.unknownCase ? nil : displayName }
}

enum DebridProvider: String, SettingsOption {
    case realDebrid = "realdebrid"
    case premiumize = "premiumize"
    case torbox = "torbox"

    var displayName: String {
        switch self {
        case .realDebrid: return "Real-Debrid"
        case .premiumize: return "Premiumize"
        case .torbox: return "TorBox"
        }
    }

    /// What a stream row calls it when space is short. Android's `service.shortName`.
    var shortName: String {
        switch self {
        case .realDebrid: return "RD"
        case .premiumize: return "PM"
        case .torbox: return "TB"
        }
    }

    var apiKeyHint: String {
        switch self {
        case .realDebrid: return "real-debrid.com → My Account → API token"
        case .premiumize: return "premiumize.me → My Account → API key"
        case .torbox: return "torbox.app → Settings → API key"
        }
    }

    /// Only these providers can answer an instant-availability query.
    var supportsCacheCheck: Bool {
        switch self {
        case .realDebrid: return false // RD retired /instantAvailability
        case .premiumize, .torbox: return true
        }
    }

    var supportsCloudLibrary: Bool { self != .realDebrid }
}

/// A configured provider: the enum plus the key the user pasted.
struct DebridCredential: Hashable, Identifiable {
    let provider: DebridProvider
    let apiKey: String
    var id: String { provider.rawValue }
}

extension DebridStreamResolution: StreamAttributeOption {
    static var unknownCase: Self { .unknown }
}

extension DebridStreamQuality: StreamAttributeOption {
    static var unknownCase: Self { .unknown }
}

extension DebridStreamVisualTag: StreamAttributeOption {
    static var unknownCase: Self { .unknown }
}

extension DebridStreamAudioTag: StreamAttributeOption {
    static var unknownCase: Self { .unknown }
}

extension DebridStreamAudioChannel: StreamAttributeOption {
    static var unknownCase: Self { .unknown }
}

extension DebridStreamEncode: StreamAttributeOption {
    static var unknownCase: Self { .unknown }
}

extension DebridStreamLanguage: StreamAttributeOption {
    static var unknownCase: Self { .unknown }
}
