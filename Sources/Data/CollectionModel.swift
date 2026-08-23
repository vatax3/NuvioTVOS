import Foundation

/// Nuvio's collections, in the shape the Android app defines.
///
/// A collection holds **folders**, a folder holds **sources**, and a source is a live query —
/// an addon catalogue, a TMDB request, or a Trakt list. Nothing here stores titles: a folder is
/// a saved question, not a saved answer, which is what separates this from the manual list of
/// bookmarks it replaces.
///
/// The shape is not ours to choose. Collections travel between the two apps through one
/// `collections_json` blob on the account, and before this the payloads had nothing in common:
/// theirs failed to decode here because `JSONDecoder` is strict, ours parsed there into
/// titleless empty collections because Gson is lenient. Whichever app synced last destroyed the
/// other's work. Every field below, and every default, mirrors `CollectionsDataStore.kt`.

// MARK: - Enumerations

/// How a folder lays its sources out. Written upper-cased, read case-insensitively — Android's
/// `fromString` is lenient and a round trip must not depend on which app wrote the file.
enum CollectionViewMode: String, Codable, Hashable, Sendable, CaseIterable {
    case tabbedGrid = "TABBED_GRID"
    case rows = "ROWS"
    case followLayout = "FOLLOW_LAYOUT"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.parse(raw)
    }

    static func parse(_ raw: String?) -> Self {
        switch raw?.lowercased() {
        case "rows": return .rows
        case "follow_layout": return .followLayout
        default: return .tabbedGrid
        }
    }
}

/// `PosterShape` is the app's own, from `Domain/Models.swift`, and its raw values are lower
/// case. Android writes `POSTER` / `LANDSCAPE` / `SQUARE`, so the conversion happens here rather
/// than by giving the design system a second shape type to disagree with.
extension PosterShape {
    /// Android accepts both its own names and the shorthand its importer documents — `wide` for
    /// landscape. A folder with no shape is square there, which is not this type's own default.
    static func collectionTileShape(_ raw: String?) -> PosterShape {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "poster": return .poster
        case "landscape", "wide": return .landscape
        default: return .square
        }
    }

    var collectionTileShapeValue: String { rawValue.uppercased() }
}

enum TmdbSourceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case list = "LIST"
    case collection = "COLLECTION"
    case company = "COMPANY"
    case network = "NETWORK"
    case discover = "DISCOVER"
    case person = "PERSON"
    case director = "DIRECTOR"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw.uppercased()) ?? .discover
    }
}

/// Lower-cased on the wire, unlike the others — it goes straight into a TMDB path.
enum TmdbMediaType: String, Codable, Hashable, Sendable, CaseIterable {
    case movie
    case tv

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw.lowercased()) ?? .movie
    }

    var contentType: ContentType { self == .tv ? .series : .movie }
}

enum TmdbCollectionSort: String, Sendable, CaseIterable {
    case original = "original"
    case popularityDesc = "popularity.desc"
    case voteAverageDesc = "vote_average.desc"
    case voteCountDesc = "vote_count.desc"
    case releaseDateDesc = "primary_release_date.desc"
    case firstAirDateDesc = "first_air_date.desc"

    static let `default` = TmdbCollectionSort.popularityDesc
}

enum TraktListSort: String, Sendable, CaseIterable {
    case rank, added, title, released, runtime, popularity, percentage, votes

    static func normalize(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return Self(rawValue: value)?.rawValue ?? Self.rank.rawValue
    }
}

enum TraktSortHow: String, Sendable, CaseIterable {
    case asc, desc

    static func normalize(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return Self(rawValue: value)?.rawValue ?? Self.asc.rawValue
    }
}

// MARK: - TMDB filters

/// Every filter TMDB's discover endpoint takes, as Android exposes them. All optional; a nil
/// contributes no query item.
struct TmdbCollectionFilters: Codable, Hashable, Sendable {
    var withGenres: String?
    var withoutGenres: String?
    var releaseDateGte: String?
    var releaseDateLte: String?
    var voteAverageGte: Double?
    var voteAverageLte: Double?
    var voteCountGte: Int?
    var withOriginalLanguage: String?
    var withOriginCountry: String?
    var withKeywords: String?
    var withoutKeywords: String?
    var withCompanies: String?
    var withoutCompanies: String?
    var withNetworks: String?
    var year: Int?
    var watchRegion: String?
    var withWatchProviders: String?
    var withoutWatchProviders: String?

    static let none = TmdbCollectionFilters()

    var isEmpty: Bool { self == .none }
}

// MARK: - Sources

struct AddonCollectionSource: Codable, Hashable, Sendable {
    var addonId: String
    var type: String
    var catalogId: String
    var genre: String?
}

struct TmdbCollectionSource: Codable, Hashable, Sendable {
    var sourceType: TmdbSourceKind
    var title: String
    var tmdbId: Int?
    var mediaType: TmdbMediaType = .movie
    var sortBy: String = TmdbCollectionSort.default.rawValue
    var filters: TmdbCollectionFilters = .none
}

struct TraktCollectionSource: Codable, Hashable, Sendable {
    var title: String
    var traktListId: Int
    var mediaType: TmdbMediaType = .movie
    var sortBy: String = TraktListSort.rank.rawValue
    var sortHow: String = TraktSortHow.asc.rawValue
}

/// One query inside a folder.
///
/// On the wire this is a **flat** object discriminated by `provider`, not Swift's default nested
/// form — `{"provider":"tmdb","tmdbSourceType":"DISCOVER",…}`. Encoding it the idiomatic way
/// would produce `{"tmdb":{…}}`, which Android reads as an addon source with no fields.
enum CollectionSource: Hashable, Sendable, Identifiable {
    case addon(AddonCollectionSource)
    case tmdb(TmdbCollectionSource)
    case trakt(TraktCollectionSource)

    var id: String {
        switch self {
        case .addon(let source): return "addon:\(source.addonId):\(source.type):\(source.catalogId):\(source.genre ?? "")"
        case .tmdb(let source): return "tmdb:\(source.sourceType.rawValue):\(source.tmdbId.map(String.init) ?? source.title)"
        case .trakt(let source): return "trakt:\(source.traktListId):\(source.mediaType.rawValue)"
        }
    }

    /// What the tab or rail above this source is called.
    var title: String? {
        switch self {
        case .addon: return nil
        case .tmdb(let source): return source.title
        case .trakt(let source): return source.title
        }
    }

    var addonSource: AddonCollectionSource? {
        if case .addon(let source) = self { return source }
        return nil
    }
}

extension CollectionSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case provider
        case addonId, type, catalogId, genre
        case tmdbSourceType, title, tmdbId, mediaType, sortBy, sortHow, filters
        case traktListId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An absent provider means addon: Android's own default, and what its older payloads
        // carry, since addon sources predate the other two.
        let provider = (try container.decodeIfPresent(String.self, forKey: .provider) ?? "addon")
            .lowercased()

        switch provider {
        case "tmdb":
            self = .tmdb(TmdbCollectionSource(
                sourceType: try container.decodeIfPresent(TmdbSourceKind.self, forKey: .tmdbSourceType) ?? .discover,
                title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
                tmdbId: try container.decodeIfPresent(Int.self, forKey: .tmdbId),
                mediaType: try container.decodeIfPresent(TmdbMediaType.self, forKey: .mediaType) ?? .movie,
                sortBy: try container.decodeIfPresent(String.self, forKey: .sortBy) ?? TmdbCollectionSort.default.rawValue,
                filters: try container.decodeIfPresent(TmdbCollectionFilters.self, forKey: .filters) ?? .none
            ))
        case "trakt":
            self = .trakt(TraktCollectionSource(
                title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
                traktListId: try container.decodeIfPresent(Int.self, forKey: .traktListId) ?? 0,
                mediaType: try container.decodeIfPresent(TmdbMediaType.self, forKey: .mediaType) ?? .movie,
                sortBy: TraktListSort.normalize(try container.decodeIfPresent(String.self, forKey: .sortBy)),
                sortHow: TraktSortHow.normalize(try container.decodeIfPresent(String.self, forKey: .sortHow))
            ))
        default:
            self = .addon(AddonCollectionSource(
                addonId: try container.decodeIfPresent(String.self, forKey: .addonId) ?? "",
                type: try container.decodeIfPresent(String.self, forKey: .type) ?? "",
                catalogId: try container.decodeIfPresent(String.self, forKey: .catalogId) ?? "",
                genre: try container.decodeIfPresent(String.self, forKey: .genre)
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addon(let source):
            // The provider is written even though it is the default, because Android's importer
            // validates the required fields per provider and reads an absent one as addon.
            try container.encode("addon", forKey: .provider)
            try container.encode(source.addonId, forKey: .addonId)
            try container.encode(source.type, forKey: .type)
            try container.encode(source.catalogId, forKey: .catalogId)
            try container.encodeIfPresent(source.genre, forKey: .genre)
        case .tmdb(let source):
            try container.encode("tmdb", forKey: .provider)
            try container.encode(source.sourceType, forKey: .tmdbSourceType)
            try container.encode(source.title, forKey: .title)
            try container.encodeIfPresent(source.tmdbId, forKey: .tmdbId)
            try container.encode(source.mediaType, forKey: .mediaType)
            try container.encode(source.sortBy, forKey: .sortBy)
            if !source.filters.isEmpty { try container.encode(source.filters, forKey: .filters) }
        case .trakt(let source):
            try container.encode("trakt", forKey: .provider)
            try container.encode(source.title, forKey: .title)
            try container.encode(source.traktListId, forKey: .traktListId)
            try container.encode(source.mediaType, forKey: .mediaType)
            try container.encode(source.sortBy, forKey: .sortBy)
            try container.encode(source.sortHow, forKey: .sortHow)
        }
    }
}

// MARK: - Folder

struct CollectionFolder: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var coverImageUrl: String?
    /// Parsed and written back, never drawn. An animated cover on focus would need a video layer
    /// per card on tvOS; preserving it costs nothing and keeps an Android round trip lossless.
    var focusGifUrl: String?
    var focusGifEnabled: Bool?
    var coverEmoji: String?
    var tileShape: PosterShape = .square
    var hideTitle: Bool = false
    var sources: [CollectionSource] = []
    var heroBackdropUrl: String?
    /// Same as `focusGifUrl`: carried, not played.
    var heroVideoUrl: String?
    var titleLogoUrl: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, coverImageUrl, focusGifUrl, focusGifEnabled, coverEmoji
        case tileShape, hideTitle, sources, catalogSources
        case heroBackdropUrl, heroVideoUrl, titleLogoUrl
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        coverImageUrl: String? = nil,
        focusGifUrl: String? = nil,
        focusGifEnabled: Bool? = nil,
        coverEmoji: String? = nil,
        tileShape: PosterShape = .square,
        hideTitle: Bool = false,
        sources: [CollectionSource] = [],
        heroBackdropUrl: String? = nil,
        heroVideoUrl: String? = nil,
        titleLogoUrl: String? = nil
    ) {
        self.id = id
        self.title = title
        self.coverImageUrl = coverImageUrl
        self.focusGifUrl = focusGifUrl
        self.focusGifEnabled = focusGifEnabled
        self.coverEmoji = coverEmoji
        self.tileShape = tileShape
        self.hideTitle = hideTitle
        self.sources = sources
        self.heroBackdropUrl = heroBackdropUrl
        self.heroVideoUrl = heroVideoUrl
        self.titleLogoUrl = titleLogoUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        coverImageUrl = try container.decodeIfPresent(String.self, forKey: .coverImageUrl)
        focusGifUrl = try container.decodeIfPresent(String.self, forKey: .focusGifUrl)
        focusGifEnabled = try container.decodeIfPresent(Bool.self, forKey: .focusGifEnabled)
        coverEmoji = try container.decodeIfPresent(String.self, forKey: .coverEmoji)
        tileShape = .collectionTileShape(try container.decodeIfPresent(String.self, forKey: .tileShape))
        hideTitle = try container.decodeIfPresent(Bool.self, forKey: .hideTitle) ?? false
        heroBackdropUrl = try container.decodeIfPresent(String.self, forKey: .heroBackdropUrl)
        heroVideoUrl = try container.decodeIfPresent(String.self, forKey: .heroVideoUrl)
        titleLogoUrl = try container.decodeIfPresent(String.self, forKey: .titleLogoUrl)

        // `catalogSources` predates `sources` and still ships alongside it. A payload written by
        // an older build has only the former, so it is the fallback rather than an alternative.
        if let sources = try container.decodeIfPresent([CollectionSource].self, forKey: .sources) {
            self.sources = sources
        } else {
            let legacy = try container.decodeIfPresent([AddonCollectionSource].self, forKey: .catalogSources) ?? []
            self.sources = legacy.map(CollectionSource.addon)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(coverImageUrl, forKey: .coverImageUrl)
        try container.encodeIfPresent(focusGifUrl, forKey: .focusGifUrl)
        try container.encodeIfPresent(focusGifEnabled, forKey: .focusGifEnabled)
        try container.encodeIfPresent(coverEmoji, forKey: .coverEmoji)
        try container.encode(tileShape.collectionTileShapeValue, forKey: .tileShape)
        try container.encode(hideTitle, forKey: .hideTitle)
        try container.encode(sources, forKey: .sources)
        // Written in addition to `sources`, mirroring the addon entries only. Dropping it leaves
        // older Android builds looking at empty folders.
        try container.encode(catalogSources, forKey: .catalogSources)
        try container.encodeIfPresent(heroBackdropUrl, forKey: .heroBackdropUrl)
        try container.encodeIfPresent(heroVideoUrl, forKey: .heroVideoUrl)
        try container.encodeIfPresent(titleLogoUrl, forKey: .titleLogoUrl)
    }

    var catalogSources: [AddonCollectionSource] {
        sources.compactMap(\.addonSource)
    }
}

// MARK: - Collection

struct MediaCollection: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var backdropImageUrl: String?
    var pinToTop: Bool = false
    var focusGlowEnabled: Bool?
    var viewMode: CollectionViewMode = .tabbedGrid
    var showAllTab: Bool = true
    var folders: [CollectionFolder] = []

    private enum CodingKeys: String, CodingKey {
        case id, title, backdropImageUrl, pinToTop, focusGlowEnabled, viewMode, showAllTab, folders
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        backdropImageUrl: String? = nil,
        pinToTop: Bool = false,
        focusGlowEnabled: Bool? = nil,
        viewMode: CollectionViewMode = .tabbedGrid,
        showAllTab: Bool = true,
        folders: [CollectionFolder] = []
    ) {
        self.id = id
        self.title = title
        self.backdropImageUrl = backdropImageUrl
        self.pinToTop = pinToTop
        self.focusGlowEnabled = focusGlowEnabled
        self.viewMode = viewMode
        self.showAllTab = showAllTab
        self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        backdropImageUrl = try container.decodeIfPresent(String.self, forKey: .backdropImageUrl)
        pinToTop = try container.decodeIfPresent(Bool.self, forKey: .pinToTop) ?? false
        focusGlowEnabled = try container.decodeIfPresent(Bool.self, forKey: .focusGlowEnabled)
        viewMode = try container.decodeIfPresent(CollectionViewMode.self, forKey: .viewMode) ?? .tabbedGrid
        showAllTab = try container.decodeIfPresent(Bool.self, forKey: .showAllTab) ?? true
        folders = try container.decodeIfPresent([CollectionFolder].self, forKey: .folders) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(backdropImageUrl, forKey: .backdropImageUrl)
        try container.encode(pinToTop, forKey: .pinToTop)
        try container.encodeIfPresent(focusGlowEnabled, forKey: .focusGlowEnabled)
        try container.encode(viewMode, forKey: .viewMode)
        try container.encode(showAllTab, forKey: .showAllTab)
        try container.encode(folders, forKey: .folders)
    }

    /// The key this collection is ordered by on the home screen, alongside addon catalogues.
    var homeRowKey: String { "collection_\(id)" }
}

// MARK: - Home hero

extension CollectionFolder {
    /// What the hero shows while this folder card holds focus.
    ///
    /// A folder is not a title, so there is no year, rating, runtime or synopsis to draw — and
    /// leaving the previous title's up is worse than drawing nothing, because the hero then
    /// describes something the cursor is no longer on. Upstream builds exactly this in
    /// `buildCollectionFolderItem`: a `HeroPreview` carrying the folder's own name, logo and
    /// backdrop, and null for every field a folder cannot have.
    ///
    /// The backdrop falls back the way upstream's does — the folder's hero image, then its
    /// cover, then the collection's — so a folder with only a cover still changes the picture.
    ///
    /// `hideTitle` is honoured for the same reason it is on the card: a cover with the name
    /// burned into the artwork should not have it written over the top a second time.
    func heroPreview(in collection: MediaCollection) -> MetaPreview {
        let displayName: String
        if hideTitle {
            displayName = ""
        } else if let emoji = coverEmoji?.nilIfBlank {
            displayName = "\(emoji)  \(title)"
        } else {
            displayName = title
        }

        return MetaPreview(
            id: "collection:\(collection.id):\(id)",
            type: .unknown,
            rawType: "collection",
            name: displayName,
            poster: coverImageUrl?.nilIfBlank,
            posterShape: tileShape,
            background: heroBackdropUrl?.nilIfBlank
                ?? coverImageUrl?.nilIfBlank
                ?? collection.backdropImageUrl?.nilIfBlank,
            logo: hideTitle ? nil : titleLogoUrl?.nilIfBlank
        )
    }
}
