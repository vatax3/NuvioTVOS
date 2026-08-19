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
        case .exoplayer: return "System pipeline. Best power efficiency and HDR passthrough."
        case .mpv: return "Software pipeline for containers AVFoundation refuses."
        }
    }
}

enum PlayerPreference: String, SettingsOption {
    case internalPlayer = "INTERNAL"
    case externalPlayer = "EXTERNAL"
    case askEveryTime = "ASK"
    var displayName: String {
        switch self {
        case .internalPlayer: return "Internal player"
        case .externalPlayer: return "External player"
        case .askEveryTime: return "Ask every time"
        }
    }
}

enum DecoderPriority: String, SettingsOption {
    case preferHardware = "PREFER_HARDWARE"
    case preferSoftware = "PREFER_SOFTWARE"
    case hardwareOnly = "HARDWARE_ONLY"
    var displayName: String {
        switch self {
        case .preferHardware: return "Prefer hardware"
        case .preferSoftware: return "Prefer software"
        case .hardwareOnly: return "Hardware only"
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
        case .fit: return "Fit"
        case .fill: return "Stretch to fill"
        case .zoom: return "Zoom to fill"
        case .fixedWidth: return "Fixed width"
        case .fixedHeight: return "Fixed height"
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
        case .off: return "Off"
        case .start: return "On playback start"
        case .startStop: return "Start and stop"
        }
    }

    var summary: String {
        switch self {
        case .off: return "Leave the display in whatever mode tvOS is using"
        case .start: return "Switch the panel to the film's frame rate and stay there"
        case .startStop: return "Switch for playback, then restore the previous mode"
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
        case .legacyDirectCopy: return "Legacy (direct, then copy)"
        case .autoSafe: return "Auto (safe)"
        case .hardwareCopy: return "Hardware (copy)"
        case .hardwareDirect: return "Hardware (direct)"
        case .disabled: return "Disabled (software)"
        }
    }

    var summary: String {
        switch self {
        case .legacyDirectCopy: return "Tries direct mapping first, falls back to a copy"
        case .autoSafe: return "Lets mpv pick whatever it considers safe"
        case .hardwareCopy: return "VideoToolbox decode, frames copied back through system memory"
        case .hardwareDirect: return "Zero-copy VideoToolbox. The fast path on Apple TV."
        case .disabled: return "Software decode. Slowest, but always draws."
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
        case .automatic: return "Automatic"
        case .avfoundation: return "AVFoundation"
        case .audiounit: return "AudioUnit"
        }
    }

    var summary: String {
        switch self {
        case .automatic: return "Try AVFoundation, then AudioUnit"
        case .avfoundation: return "AVSampleBufferAudioRenderer — the supported path on Apple TV"
        case .audiounit: return "RemoteIO — works on iOS, refused by some Apple TV routes"
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
        case .auto: return "Auto"
        case .stereo: return "Stereo"
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
        case .auto: return "Follow whatever layout the Apple TV reports it can take"
        case .stereo: return "Always downmix — the layout every television accepts"
        case .surround51: return "Send 5.1 to the receiver"
        case .surround71: return "Send 7.1 to the receiver"
        }
    }
}

// MARK: - Subtitles

enum LibassRenderType: String, SettingsOption {
    case native = "NATIVE"
    case libass = "LIBASS"
    var displayName: String { self == .native ? "Native renderer" : "libass (full ASS/SSA)" }
}

enum SubtitleOrganizationMode: String, SettingsOption {
    case byLanguage = "BY_LANGUAGE"
    case byAddon = "BY_ADDON"
    case flat = "FLAT"
    var displayName: String {
        switch self {
        case .byLanguage: return "Group by language"
        case .byAddon: return "Group by addon"
        case .flat: return "Flat list"
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
        case .off: return "Off — always show the source list"
        case .first: return "First available source"
        case .matchRegex: return "First source matching a pattern"
        case .preferredQuality: return "Best match for preferred quality"
        }
    }
}

enum StreamAutoPlaySource: String, SettingsOption {
    case anyAddon = "ANY"
    case debridOnly = "DEBRID_ONLY"
    case cachedOnly = "CACHED_ONLY"
    var displayName: String {
        switch self {
        case .anyAddon: return "Any source"
        case .debridOnly: return "Debrid sources only"
        case .cachedOnly: return "Cached sources only"
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

// MARK: - Dolby Vision

enum DolbyVision7HandlingMode: String, SettingsOption {
    case auto = "AUTO"
    case forceBaseLayer = "FORCE_BASE_LAYER"
    case passthrough = "PASSTHROUGH"
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .forceBaseLayer: return "Force HDR10 base layer"
        case .passthrough: return "Passthrough"
        }
    }
}

// MARK: - Buffering

enum VodCacheSizeMode: String, SettingsOption {
    case automatic = "AUTO"
    case manual = "MANUAL"
    var displayName: String { self == .automatic ? "Automatic" : "Manual" }
}

// MARK: - Layout

enum DiscoverLocation: String, SettingsOption {
    case sidebar = "SIDEBAR"
    case searchTab = "SEARCH"
    case off = "OFF"
    var displayName: String {
        switch self {
        case .sidebar: return "Its own sidebar entry"
        case .searchTab: return "Inside Search"
        case .off: return "Hidden"
        }
    }
}

enum ContinueWatchingSortMode: String, SettingsOption {
    case recentlyWatched = "RECENT"
    case recentlyAdded = "ADDED"
    case alphabetical = "ALPHA"
    var displayName: String {
        switch self {
        case .recentlyWatched: return "Recently watched"
        case .recentlyAdded: return "Recently added"
        case .alphabetical: return "A–Z"
        }
    }
}

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
        case .local: return "This device"
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
        case .local: return "This device"
        case .trakt: return "Trakt collection"
        case .simkl: return "Simkl list"
        }
    }
}

enum MoreLikeThisSource: String, SettingsOption {
    case addonCatalog = "ADDON"
    case tmdb = "TMDB"
    case trakt = "TRAKT"
    var displayName: String {
        switch self {
        case .addonCatalog: return "Addon catalog"
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
        case .inline: return "Inline with the title"
        case .belowTitle: return "On their own line"
        case .hidden: return "Hidden"
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
        case .default: return "Addon order"
        case .qualityDesc: return "Highest quality first"
        case .sizeDesc: return "Largest file first"
        case .sizeAsc: return "Smallest file first"
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
        case .any: return "Allow"
        case .exclude: return "Exclude"
        case .only: return "Only"
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
        case .any: return "Any codec"
        case .h264: return "H.264 / AVC"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        }
    }
}

enum DebridStreamResolution: String, SettingsOption {
    case p2160 = "P2160", p1440 = "P1440", p1080 = "P1080", p720 = "P720"
    case p576 = "P576", p480 = "P480", p360 = "P360", unknown = "UNKNOWN"

    var displayName: String { self == .unknown ? "Unknown" : "\(value)p" }

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
        case .unknown: return "Unknown"
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
        case .unknown: return "Unknown"
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
        case .unknown: return "Unknown"
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
        case .unknown: return "Unknown"
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
        case .unknown: return "Unknown"
        }
    }
    static let defaultOrder: [DebridStreamEncode] = [.av1, .hevc, .avc, .xvid, .divx, .unknown]
}

enum DebridStreamLanguage: String, SettingsOption {
    case en, hi, it, es, fr, de, pt, pl, cs, la, ja, ko, zh, multi, unknown

    var displayName: String {
        switch self {
        case .en: return "English"
        case .hi: return "Hindi"
        case .it: return "Italian"
        case .es: return "Spanish"
        case .fr: return "French"
        case .de: return "German"
        case .pt: return "Portuguese"
        case .pl: return "Polish"
        case .cs: return "Czech"
        case .la: return "Latino"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .zh: return "Chinese"
        case .multi: return "Multi"
        case .unknown: return "Unknown"
        }
    }
}

enum DebridStreamSortKey: String, SettingsOption {
    case resolution = "RESOLUTION", quality = "QUALITY", visualTag = "VISUAL_TAG"
    case audioTag = "AUDIO_TAG", audioChannel = "AUDIO_CHANNEL", encode = "ENCODE"
    case size = "SIZE", language = "LANGUAGE", releaseGroup = "RELEASE_GROUP"

    var displayName: String {
        switch self {
        case .resolution: return "Resolution"
        case .quality: return "Quality"
        case .visualTag: return "Visual tag"
        case .audioTag: return "Audio"
        case .audioChannel: return "Audio channel"
        case .encode: return "Encode"
        case .size: return "Size"
        case .language: return "Language"
        case .releaseGroup: return "Release group"
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
