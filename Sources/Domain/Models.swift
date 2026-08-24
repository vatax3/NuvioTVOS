import Foundation

// MARK: - ContentType (port of ContentType.kt)

enum ContentType: String, Codable, Hashable, Sendable {
    case movie, series, channel, tv, unknown

    static func from(_ value: String?) -> ContentType {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "movie": return .movie
        case "series": return .series
        case "channel": return .channel
        case "tv": return .tv
        default: return .unknown
        }
    }

    func apiString(fallback: String? = nil) -> String {
        switch self {
        case .movie: return "movie"
        case .series: return "series"
        case .channel: return "channel"
        case .tv: return "tv"
        case .unknown:
            let trimmed = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed! : "movie"
        }
    }

    var displayName: String {
        switch self {
        case .movie: return "Movies"
        case .series: return "Series"
        case .channel: return "Channels"
        case .tv: return "TV"
        case .unknown: return "Other"
        }
    }
}

enum PosterShape: String, Codable, Hashable, Sendable, CaseIterable {
    case poster, landscape, square

    static func from(_ value: String?) -> PosterShape {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "landscape": return .landscape
        case "square": return .square
        default: return .poster
        }
    }

    var aspectRatio: CGFloat {
        switch self {
        case .poster: return 2.0 / 3.0
        case .landscape: return 16.0 / 9.0
        case .square: return 1
        }
    }
}

// MARK: - Addon (port of Addon.kt)

struct CatalogExtra: Codable, Hashable, Sendable {
    var name: String
    var isRequired: Bool = false
    var options: [String]?
    var defaultValue: String?
    var optionsLimit: Int?
}

struct CatalogDescriptor: Codable, Hashable, Identifiable, Sendable {
    var type: ContentType
    var rawType: String
    var id: String
    var name: String
    var extra: [CatalogExtra] = []
    var pageSize: Int?
    var showInHome: Bool = false
    var hasExplicitShowInHome: Bool = false
    var extraSupported: [String] = []
    var extraRequired: [String] = []

    var apiType: String { type.apiString(fallback: rawType) }

    /// Stable identity across addons — catalogs only need to be unique within their addon.
    var descriptorKey: String { "\(apiType)|\(id)" }

    var supportsSearch: Bool {
        extraSupported.contains("search") || extra.contains { $0.name == "search" }
    }

    var supportsSkip: Bool {
        extraSupported.contains("skip") || extra.contains { $0.name == "skip" }
    }

    var genreOptions: [String] {
        extra.first { $0.name == "genre" }?.options ?? []
    }

    var requiresGenre: Bool {
        extraRequired.contains("genre") || extra.contains { $0.name == "genre" && $0.isRequired }
    }
}

struct AddonResource: Codable, Hashable, Sendable {
    var name: String
    var types: [String]
    var idPrefixes: [String]?
}

struct AddonBehaviorHints: Codable, Hashable, Sendable {
    var configurable: Bool?
    var configurationRequired: Bool?
    var newEpisodeNotifications: Bool?
}

struct StremioAddonsConfig: Codable, Hashable, Sendable {
    var issuer: String?
    var signature: String?
}

struct Addon: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var displayName: String
    var version: String
    var description: String?
    var logo: String?
    var background: String?
    /// Base URL without the trailing `/manifest.json`, query string preserved separately.
    var baseUrl: String
    var catalogs: [CatalogDescriptor]
    var types: [ContentType]
    var rawTypes: [String]
    var resources: [AddonResource]
    var idPrefixes: [String] = []
    var behaviorHints: AddonBehaviorHints?
    var stremioAddonsConfig: StremioAddonsConfig?
    var manifestLanguage: String?
    var configVersion: Int64?
    var timestamp: Int64?
    var enabled: Bool = true

    var isActive: Bool { enabled }

    func supports(resource: String, type: String) -> Bool {
        resources.contains { res in
            res.name.caseInsensitiveCompare(resource) == .orderedSame &&
            (res.types.isEmpty || res.types.contains { $0.caseInsensitiveCompare(type) == .orderedSame })
        }
    }

    /// Mirrors the Stremio `idPrefixes` gate applied before hitting an addon.
    func handles(id: String, resource: String, type: String) -> Bool {
        guard supports(resource: resource, type: type) else { return false }
        let prefixes = resources.first {
            $0.name.caseInsensitiveCompare(resource) == .orderedSame
        }?.idPrefixes ?? (idPrefixes.isEmpty ? nil : idPrefixes)
        guard let prefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }
}

extension Array where Element == Addon {
    var enabledAddons: [Addon] { filter(\.enabled) }
}

// MARK: - Meta previews & details

struct MetaLink: Codable, Hashable, Sendable {
    var name: String
    var category: String
    var url: String?
}

struct MetaTrailer: Codable, Hashable, Sendable {
    var source: String?
    var type: String?
    var name: String?
    var ytId: String?
    var lang: String?
}

struct MetaBehaviorHints: Codable, Hashable, Sendable {
    var defaultVideoId: String?
    var hasScheduledVideos: Bool?
}

struct MetaCastMember: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var character: String?
    var photo: String?
    var tmdbId: Int?
    var id: String { "\(name)|\(tmdbId.map(String.init) ?? character ?? "")" }
}

struct MetaCompany: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var logo: String?
    /// Present when the entry came from TMDB, which is what makes it browsable.
    var tmdbId: Int?
    var id: String { name }
}

struct MetaPreview: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var type: ContentType
    var rawType: String
    var name: String
    var poster: String?
    var posterShape: PosterShape = .poster
    var background: String?
    var logo: String?
    var description: String?
    var releaseInfo: String?
    var imdbRating: Float?
    var genres: [String] = []
    var runtime: String?
    var status: String?
    var ageRating: String?
    var language: String?
    var released: String?
    var country: String?
    var imdbId: String?
    var slug: String?
    var landscapePoster: String?
    var rawPosterUrl: String?
    var director: [String] = []
    var writer: [String] = []
    var links: [MetaLink] = []
    var behaviorHints: MetaBehaviorHints?
    var trailers: [MetaTrailer] = []
    var trailerYtIds: [String] = []
    var seasonCount: Int?
    var voteCount: Int?
    var sourceAddonBaseUrl: String?


    /// Restored by hand: writing `init(from:)` above suppresses the memberwise one.
    init(
        id: String,
        type: ContentType,
        rawType: String,
        name: String,
        poster: String? = nil,
        posterShape: PosterShape = .poster,
        background: String? = nil,
        logo: String? = nil,
        description: String? = nil,
        releaseInfo: String? = nil,
        imdbRating: Float? = nil,
        genres: [String] = [],
        runtime: String? = nil,
        status: String? = nil,
        ageRating: String? = nil,
        language: String? = nil,
        released: String? = nil,
        country: String? = nil,
        imdbId: String? = nil,
        slug: String? = nil,
        landscapePoster: String? = nil,
        rawPosterUrl: String? = nil,
        director: [String] = [],
        writer: [String] = [],
        links: [MetaLink] = [],
        behaviorHints: MetaBehaviorHints? = nil,
        trailers: [MetaTrailer] = [],
        trailerYtIds: [String] = [],
        seasonCount: Int? = nil,
        voteCount: Int? = nil,
        sourceAddonBaseUrl: String? = nil
    ) {
        self.id = id
        self.type = type
        self.rawType = rawType
        self.name = name
        self.poster = poster
        self.posterShape = posterShape
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.genres = genres
        self.runtime = runtime
        self.status = status
        self.ageRating = ageRating
        self.language = language
        self.released = released
        self.country = country
        self.imdbId = imdbId
        self.slug = slug
        self.landscapePoster = landscapePoster
        self.rawPosterUrl = rawPosterUrl
        self.director = director
        self.writer = writer
        self.links = links
        self.behaviorHints = behaviorHints
        self.trailers = trailers
        self.trailerYtIds = trailerYtIds
        self.seasonCount = seasonCount
        self.voteCount = voteCount
        self.sourceAddonBaseUrl = sourceAddonBaseUrl
    }

    /// Tolerant of documents written before a field existed — see `Profile`. This one
    /// matters twice over: a `MetaPreview` is embedded in every saved library item, so a
    /// strict decode failure here does not lose a poster, it loses the library.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(ContentType.self, forKey: .type)
        rawType = try c.decode(String.self, forKey: .rawType)
        name = try c.decode(String.self, forKey: .name)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        posterShape = try c.decodeIfPresent(PosterShape.self, forKey: .posterShape) ?? .poster
        background = try c.decodeIfPresent(String.self, forKey: .background)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        releaseInfo = try c.decodeIfPresent(String.self, forKey: .releaseInfo)
        imdbRating = try c.decodeIfPresent(Float.self, forKey: .imdbRating)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        ageRating = try c.decodeIfPresent(String.self, forKey: .ageRating)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        released = try c.decodeIfPresent(String.self, forKey: .released)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        imdbId = try c.decodeIfPresent(String.self, forKey: .imdbId)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        landscapePoster = try c.decodeIfPresent(String.self, forKey: .landscapePoster)
        rawPosterUrl = try c.decodeIfPresent(String.self, forKey: .rawPosterUrl)
        director = try c.decodeIfPresent([String].self, forKey: .director) ?? []
        writer = try c.decodeIfPresent([String].self, forKey: .writer) ?? []
        links = try c.decodeIfPresent([MetaLink].self, forKey: .links) ?? []
        behaviorHints = try c.decodeIfPresent(MetaBehaviorHints.self, forKey: .behaviorHints)
        trailers = try c.decodeIfPresent([MetaTrailer].self, forKey: .trailers) ?? []
        trailerYtIds = try c.decodeIfPresent([String].self, forKey: .trailerYtIds) ?? []
        seasonCount = try c.decodeIfPresent(Int.self, forKey: .seasonCount)
        voteCount = try c.decodeIfPresent(Int.self, forKey: .voteCount)
        sourceAddonBaseUrl = try c.decodeIfPresent(String.self, forKey: .sourceAddonBaseUrl)
    }

    var apiType: String { type.apiString(fallback: rawType) }
    var backdropUrl: String? { background ?? landscapePoster ?? poster }

    /// Identity used by lists — the same title can legitimately appear in several catalogs.
    var rowKey: String { "\(apiType)|\(id)" }
}

struct Video: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String?
    var title: String?
    var released: String?
    var thumbnail: String?
    var season: Int?
    var episode: Int?
    var number: Int?
    var overview: String?
    var description: String?
    var runtime: String?
    var available: Bool?
    /// Filled from TMDB when episode metadata is enabled. Never decoded from an addon: no
    /// Stremio addon publishes a per-episode score.
    var tmdbRating: Double?

    var displayTitle: String {
        name ?? title ?? (episode.map { "Episode \($0)" } ?? id)
    }

    var displayOverview: String? { overview ?? description }

    var releaseDate: Date? {
        guard let released else { return nil }
        return VideoDateParser.parse(released)
    }

    var hasAired: Bool? {
        guard let releaseDate else { return nil }
        return releaseDate <= Date()
    }

    /// The air date as an episode card shows it — a long date in the viewer's own locale, the
    /// same shape `formatEpisodeCardDate` produces on Android.
    ///
    /// Nil rather than an empty string when the addon supplied no date or a date this cannot
    /// parse, so the caller draws nothing instead of an empty slot.
    var releaseLabel: String? {
        guard let releaseDate else { return nil }
        return Video.releaseLabelFormatter.string(from: releaseDate)
    }

    private static let releaseLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}

enum VideoDateParser {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return isoFractional.date(from: trimmed)
            ?? iso.date(from: trimmed)
            ?? dateOnly.date(from: String(trimmed.prefix(10)))
    }
}

struct Meta: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var type: ContentType
    var rawType: String
    var name: String
    var poster: String?
    var posterShape: PosterShape = .poster
    var background: String?
    var logo: String?
    var description: String?
    var releaseInfo: String?
    var status: String?
    var imdbRating: Float?
    var genres: [String] = []
    var runtime: String?
    var director: [String] = []
    var writer: [String] = []
    var cast: [String] = []
    var castMembers: [MetaCastMember] = []
    var videos: [Video] = []
    var productionCompanies: [MetaCompany] = []
    var networks: [MetaCompany] = []
    var ageRating: String?
    var country: String?
    var awards: String?
    var language: String?
    var links: [MetaLink] = []
    var trailerYtIds: [String] = []
    var imdbId: String?
    var slug: String?
    var released: String?
    var landscapePoster: String?
    var rawPosterUrl: String?
    var behaviorHints: MetaBehaviorHints?
    var trailers: [MetaTrailer] = []

    var apiType: String { type.apiString(fallback: rawType) }
    var backdropUrl: String? { background ?? landscapePoster ?? poster }

    /// Port of `Meta.watchableEpisodes()` — drops specials and not-yet-released seasons.
    /// `includeUnaired` is the `show_unaired_next_up` preference: with it on, episodes that
    /// have not aired stay in the list so Next Up can point at one.
    func watchableEpisodes(includeUnaired: Bool = false) -> [Video] {
        let candidates = videos.filter { ($0.season ?? 0) > 0 && $0.episode != nil }
        guard !includeUnaired else {
            return candidates.filter { $0.available != false }
        }
        let grouped = Dictionary(grouping: candidates) { $0.season ?? 0 }
        let unavailableSeasons: Set<Int> = Set(grouped.compactMap { season, eps -> Int? in
            guard let first = eps.min(by: { ($0.episode ?? .max) < ($1.episode ?? .max) }) else { return nil }
            if first.available == false { return season }
            if first.hasAired == false { return season }
            return nil
        })
        return candidates.filter { video in
            guard !unavailableSeasons.contains(video.season ?? 0) else { return false }
            guard video.available != false else { return false }
            return video.hasAired != false
        }
    }

    var seasons: [Int] {
        Array(Set(videos.compactMap(\.season)).filter { $0 > 0 }).sorted()
    }

    func episodes(inSeason season: Int) -> [Video] {
        videos
            .filter { $0.season == season }
            .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    func preview() -> MetaPreview {
        MetaPreview(
            id: id, type: type, rawType: rawType, name: name,
            poster: poster, posterShape: posterShape, background: background,
            logo: logo, description: description, releaseInfo: releaseInfo,
            imdbRating: imdbRating, genres: genres, runtime: runtime,
            status: status, ageRating: ageRating, language: language,
            released: released, country: country, imdbId: imdbId, slug: slug,
            landscapePoster: landscapePoster, rawPosterUrl: rawPosterUrl,
            director: director, writer: writer, links: links,
            behaviorHints: behaviorHints, trailers: trailers, trailerYtIds: trailerYtIds
        )
    }
}

// MARK: - Streams (port of Stream.kt)

struct ProxyHeaders: Codable, Hashable, Sendable {
    var request: [String: String]?
    var response: [String: String]?
}

struct StreamBehaviorHints: Codable, Hashable, Sendable {
    var notWebReady: Bool?
    var bingeGroup: String?
    var countryWhitelist: [String]?
    var proxyHeaders: ProxyHeaders?
    var videoHash: String?
    var videoSize: Int64?
    var filename: String?
}

struct StreamBadge: Codable, Hashable, Sendable {
    var name: String
    var imageURL: String = ""
    var tagColor: String = ""
    var tagStyle: String = ""
    var textColor: String = ""
    var borderColor: String = ""
}

struct Stream: Codable, Hashable, Identifiable, Sendable {
    var name: String?
    var title: String?
    var description: String?
    var url: String?
    var ytId: String?
    var infoHash: String?
    var fileIdx: Int?
    var externalUrl: String?
    var behaviorHints: StreamBehaviorHints?
    var addonName: String
    var addonLogo: String?
    var sources: [String]?
    var quality: String?
    var qualityValue: Int = -1
    var badges: [StreamBadge] = []
    /// Disambiguates genuine duplicates coming from the same addon.
    var occurrence: Int = 0

    var id: String { stableKey }

    func streamURL() -> String? {
        [url, externalUrl]
            .compactMap { $0 }
            .first { !$0.isMagnetLink && !$0.isTorrentScheme }
    }

    func torrentMagnetURI() -> String? {
        [url, externalUrl].compactMap { $0 }.first { $0.isMagnetLink }
    }

    var isTorrent: Bool {
        (streamURL()?.isEmpty ?? true) &&
        (!(infoHash?.isEmpty ?? true) || torrentMagnetURI() != nil || hasTorrentURL)
    }

    private var hasTorrentURL: Bool {
        (url?.isTorrentScheme ?? false) || (externalUrl?.isTorrentScheme ?? false)
    }

    var effectiveInfoHash: String? {
        if let infoHash, !infoHash.isEmpty { return infoHash }
        for candidate in [url, externalUrl].compactMap({ $0 }) {
            if let hash = candidate.torrentSchemeInfoHash ?? candidate.magnetInfoHash { return hash }
        }
        return nil
    }

    var isYouTube: Bool { ytId != nil }

    var isExternal: Bool {
        externalUrl != nil && url == nil && !(externalUrl?.isMagnetLink ?? false)
    }

    var displayName: String { name ?? title ?? description ?? "Unknown Stream" }
    var displayDescription: String? { description ?? title }

    var stableKey: String {
        [
            addonName,
            url ?? infoHash ?? ytId ?? externalUrl ?? "",
            fileIdx.map(String.init) ?? "",
            name ?? "", title ?? "", description ?? "", quality ?? "",
            (sources ?? []).joined(separator: "|"),
            String(occurrence)
        ].joined(separator: "\u{0}")
    }
}

struct AddonStreams: Identifiable, Hashable, Sendable {
    var addonName: String
    var addonLogo: String?
    var streams: [Stream]
    var id: String { addonName }
}

// MARK: - Subtitles

struct Subtitle: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var url: String
    var lang: String
    var addonName: String?

    var displayLanguage: String {
        Locale.current.localizedString(forLanguageCode: lang)?.capitalized ?? lang.uppercased()
    }
}

// MARK: - String helpers used by Stream

extension String {
    var isMagnetLink: Bool {
        trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("magnet:")
    }

    var isTorrentScheme: Bool {
        trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("torrent:")
    }

    var torrentSchemeInfoHash: String? {
        guard isTorrentScheme else { return nil }
        var clean = self
        if let range = clean.range(of: "torrent://") { clean = String(clean[range.upperBound...]) }
        else if let range = clean.range(of: "torrent:") { clean = String(clean[range.upperBound...]) }
        clean = String(clean.split(separator: "?").first ?? "")
        let hash = String(clean.split(separator: "/").first ?? "")
        return (hash.count == 40 || hash.count == 32) ? hash : nil
    }

    var magnetInfoHash: String? {
        guard isMagnetLink, let range = range(of: "urn:btih:") else { return nil }
        let tail = String(self[range.upperBound...])
        let hash = String(tail.prefix { $0 != "&" && $0 != "?" })
        return (hash.count == 40 || hash.count == 32) ? hash : nil
    }
}
