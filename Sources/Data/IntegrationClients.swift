import Foundation
import os

// MARK: - Shared HTTP helper

/// Internal rather than private, and `session` a `var`, for exactly one reason: the write
/// endpoints below mutate somebody's real Trakt or Simkl library. There is no way to develop
/// them against a live account without adding and removing real titles from it, so the tests
/// swap in a stubbed session instead. Nothing in the app ever assigns to it.
enum IntegrationHTTP {
    static var session: URLSession = makeSession()

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }

    static func get<T: Decodable>(
        _ url: String, headers: [String: String] = [:], as type: T.Type
    ) async throws -> T {
        guard let url = URL(string: url) else { throw StremioError.invalidURL(url) }
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StremioError.http(http.statusCode, url.absoluteString)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    static func post<T: Decodable>(
        _ url: String, headers: [String: String] = [:], json: Encodable, as type: T.Type
    ) async throws -> T {
        guard let url = URL(string: url) else { throw StremioError.invalidURL(url) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONEncoder().encode(AnyEncodable(json))
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StremioError.http(http.statusCode, url.absoluteString)
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Used for removing a remote resume point, which both Trakt and Simkl spell
    /// `DELETE /sync/playback/{id}`. No body either way, and no response worth decoding — the
    /// status is the whole answer.
    static func delete(_ url: String, headers: [String: String] = [:]) async throws {
        guard let url = URL(string: url) else { throw StremioError.invalidURL(url) }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StremioError.http(http.statusCode, url.absoluteString)
        }
    }
}

struct EmptyResponse: Decodable {}

private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeClosure = wrapped.encode(to:) }
    func encode(to encoder: Encoder) throws { try encodeClosure(encoder) }
}

// MARK: - Parental guide (port of ParentalGuideRepository)

struct ParentalWarning: Hashable, Sendable {
    let label: String
    let severity: String
}

actor ParentalGuideClient {
    static let shared = ParentalGuideClient()
    private let base = "https://api.tiffara.com"
    private var cache: [String: [ParentalWarning]] = [:]

    func warnings(imdbId: String) async -> [ParentalWarning] {
        guard imdbId.hasPrefix("tt") else { return [] }
        if let cached = cache[imdbId] { return cached }
        guard let response = try? await IntegrationHTTP.get(
            "\(base)/titles/\(imdbId)/parentsGuide", as: ParentalGuideResponse.self
        ) else { return [] }

        let names: [String: String] = [
            "SEXUAL_CONTENT": "Sexual content",
            "VIOLENCE": "Violence",
            "PROFANITY": "Profanity",
            "ALCOHOL_DRUGS": "Alcohol & drugs",
            "FRIGHTENING_INTENSE_SCENES": "Frightening scenes"
        ]
        let result = response.parentsGuide.compactMap { category -> ParentalWarning? in
            guard let label = names[category.category.uppercased()],
                  let severity = dominantSeverity(category.severityBreakdowns)
            else { return nil }
            return ParentalWarning(label: label, severity: severity.capitalized)
        }
        cache[imdbId] = result
        return result
    }

    private func dominantSeverity(_ values: [ParentalGuideSeverity]?) -> String? {
        guard let values else { return nil }
        let noneVotes = values.first { $0.severityLevel.lowercased() == "none" }?.voteCount ?? 0
        guard let candidate = values
            .filter({ $0.severityLevel.lowercased() != "none" })
            .max(by: { $0.voteCount < $1.voteCount }),
              candidate.voteCount > noneVotes
        else { return nil }
        return candidate.severityLevel.lowercased()
    }
}

private struct ParentalGuideResponse: Decodable {
    let parentsGuide: [ParentalGuideCategory]
}

private struct ParentalGuideCategory: Decodable {
    let category: String
    let severityBreakdowns: [ParentalGuideSeverity]?
}

private struct ParentalGuideSeverity: Decodable {
    let severityLevel: String
    let voteCount: Int
}

/// Every filter a collection's TMDB source can carry, rendered as query items.
///
/// Kept apart from `TMDBClient.BrowseFilter`, which answers a narrower question — one entity,
/// fixed sort — and is used by screens that do not want any of this.
struct TMDBDiscoverQuery: Sendable {
    var sortBy: String
    var filters: TmdbCollectionFilters

    /// `original` means "whatever TMDB considers the natural order", which discover has no term
    /// for, so it becomes popularity. The date filters are named per media type: a film has a
    /// primary release date, a series a first air date.
    func queryString(for type: ContentType) -> String {
        var items: [String] = []
        let sort = sortBy == TmdbCollectionSort.original.rawValue
            ? TmdbCollectionSort.popularityDesc.rawValue
            : sortBy
        items.append("sort_by=\(sort)")

        let datePrefix = type == .series ? "first_air_date" : "primary_release_date"
        func add(_ name: String, _ value: String?) {
            guard let value = value?.nilIfBlank,
                  let escaped = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            else { return }
            items.append("\(name)=\(escaped)")
        }

        add("with_genres", filters.withGenres)
        add("without_genres", filters.withoutGenres)
        add("\(datePrefix).gte", filters.releaseDateGte)
        add("\(datePrefix).lte", filters.releaseDateLte)
        add("with_original_language", filters.withOriginalLanguage)
        add("with_origin_country", filters.withOriginCountry)
        add("with_keywords", filters.withKeywords)
        add("without_keywords", filters.withoutKeywords)
        add("with_companies", filters.withCompanies)
        add("without_companies", filters.withoutCompanies)
        add("with_networks", filters.withNetworks)
        add("watch_region", filters.watchRegion)
        add("with_watch_providers", filters.withWatchProviders)
        add("without_watch_providers", filters.withoutWatchProviders)

        if let value = filters.voteAverageGte { items.append("vote_average.gte=\(value)") }
        if let value = filters.voteAverageLte { items.append("vote_average.lte=\(value)") }
        if let value = filters.voteCountGte { items.append("vote_count.gte=\(value)") }
        if let year = filters.year {
            items.append(type == .series ? "first_air_date_year=\(year)" : "primary_release_year=\(year)")
        }
        return items.joined(separator: "&")
    }
}

// MARK: - TMDB (port of TmdbApi usage)

/// Metadata enrichment: better artwork, logos, cast photos, episode stills and recommendations
/// than most Stremio catalogs carry.
actor TMDBClient {
    static let shared = TMDBClient()
    private let base = "https://api.themoviedb.org/3"
    static let imageBase = "https://image.tmdb.org/t/p"

    struct Enrichment: Sendable {
        var tmdbId: Int?
        var backdrop: String?
        var poster: String?
        var logo: String?
        var overview: String?
        var rating: Float?
        var runtimeMinutes: Int?
        var genres: [String] = []
        var cast: [MetaCastMember] = []
        var networks: [MetaCompany] = []
        var productionCompanies: [MetaCompany] = []
        var certification: String?
        var trailerYouTubeIds: [String] = []
        var recommendations: [MetaPreview] = []
        /// The franchise this film belongs to, when TMDB says it belongs to one. Carried on the
        /// detail payload we already fetch, so knowing costs nothing — only listing the other
        /// films does.
        var collection: Collection?
    }

    struct Collection: Sendable, Equatable {
        var id: Int
        var name: String
    }

    /// Resolves an IMDb id to a TMDB record, then pulls everything the settings allow.
    func enrich(
        imdbId: String,
        type: ContentType,
        apiKey: String,
        language: String,
        options: TMDBOptions
    ) async -> Enrichment? {
        guard !apiKey.isEmpty else { return nil }
        let mediaType = type == .series ? "tv" : "movie"

        guard let found = try? await IntegrationHTTP.get(
            "\(base)/find/\(imdbId)?api_key=\(apiKey)&external_source=imdb_id&language=\(language)",
            as: TMDBFindResponse.self
        ) else { return nil }

        let match = type == .series ? found.tv_results?.first : found.movie_results?.first
        guard let tmdbId = match?.id else { return nil }

        var enrichment = Enrichment(tmdbId: tmdbId)

        var appends: [String] = []
        if options.useCredits { appends.append("credits") }
        if options.useArtwork { appends.append("images") }
        if options.useTrailers { appends.append("videos") }
        if options.useMoreLikeThis { appends.append("recommendations") }
        if options.useReleaseDates { appends.append(type == .series ? "content_ratings" : "release_dates") }

        let appendQuery = appends.isEmpty ? "" : "&append_to_response=\(appends.joined(separator: ","))"
        // `include_image_language` keeps language-less logos, which are the clean ones.
        let imageQuery = options.useArtwork ? "&include_image_language=\(language.prefix(2)),en,null" : ""

        guard let details = try? await IntegrationHTTP.get(
            "\(base)/\(mediaType)/\(tmdbId)?api_key=\(apiKey)&language=\(language)\(appendQuery)\(imageQuery)",
            as: TMDBDetails.self
        ) else { return enrichment }

        if options.useBasicInfo {
            enrichment.overview = details.overview?.nilIfBlank
            enrichment.rating = details.vote_average.map { Float($0) }
            enrichment.genres = details.genres?.compactMap(\.name) ?? []
        }
        if options.useDetails {
            enrichment.runtimeMinutes = details.runtime ?? details.episode_run_time?.first
        }
        if options.useArtwork {
            enrichment.backdrop = details.backdrop_path.map { "\(Self.imageBase)/original\($0)" }
            enrichment.poster = details.poster_path.map { "\(Self.imageBase)/w500\($0)" }
            enrichment.logo = details.images?.logos?.first?.file_path
                .map { "\(Self.imageBase)/w500\($0)" }
        }
        if options.useCredits {
            enrichment.cast = (details.credits?.cast ?? []).prefix(30).compactMap { member in
                guard let name = member.name else { return nil }
                return MetaCastMember(
                    name: name,
                    character: member.character,
                    photo: member.profile_path.map { "\(Self.imageBase)/w300\($0)" },
                    tmdbId: member.id
                )
            }
        }
        if options.useNetworks {
            enrichment.networks = (details.networks ?? []).compactMap { network in
                guard let name = network.name else { return nil }
                return MetaCompany(
                    name: name,
                    logo: network.logo_path.map { "\(Self.imageBase)/w300\($0)" },
                    tmdbId: network.id
                )
            }
        }
        if options.useProductions {
            enrichment.productionCompanies = (details.production_companies ?? []).compactMap { company in
                guard let name = company.name else { return nil }
                return MetaCompany(
                    name: name,
                    logo: company.logo_path.map { "\(Self.imageBase)/w300\($0)" },
                    tmdbId: company.id
                )
            }
        }
        if options.useTrailers {
            enrichment.trailerYouTubeIds = (details.videos?.results ?? [])
                .filter { $0.site?.lowercased() == "youtube" && $0.type?.lowercased() == "trailer" }
                .compactMap(\.key)
        }
        if options.useMoreLikeThis {
            enrichment.recommendations = (details.recommendations?.results ?? []).compactMap { item in
                guard let name = item.title ?? item.name else { return nil }
                return MetaPreview(
                    id: "tmdb:\(item.id ?? 0)",
                    type: type,
                    rawType: type.apiString(),
                    name: name,
                    poster: item.poster_path.map { "\(Self.imageBase)/w500\($0)" },
                    background: item.backdrop_path.map { "\(Self.imageBase)/original\($0)" },
                    description: item.overview,
                    releaseInfo: (item.release_date ?? item.first_air_date).map { String($0.prefix(4)) },
                    imdbRating: item.vote_average.map { Float($0) }
                )
            }
        }
        // Free: it rides along on the detail payload already fetched. Listing the other
        // films is the request, and that is only made when there is a franchise to list.
        if let reference = details.belongs_to_collection,
           let id = reference.id, let name = reference.name?.nilIfBlank {
            enrichment.collection = Collection(id: id, name: name)
        }
        if options.useReleaseDates {
            enrichment.certification = details.certification(for: "US")
        }

        return enrichment
    }

    struct TMDBOptions: Sendable {
        var useArtwork = true
        var useBasicInfo = true
        var useCredits = true
        var useDetails = true
        var useTrailers = true
        var useNetworks = true
        var useProductions = true
        var useReleaseDates = true
        var useMoreLikeThis = true
    }

    // MARK: - People

    struct PersonProfile: Sendable {
        var tmdbId: Int
        var name: String
        var biography: String?
        var photo: String?
        var birthday: String?
        var deathday: String?
        var placeOfBirth: String?
        var knownFor: String?
        var credits: [MetaPreview] = []
    }

    /// Cast detail: the person plus everything they appeared in, newest first.
    func person(id: Int, apiKey: String, language: String) async -> PersonProfile? {
        guard !apiKey.isEmpty else { return nil }
        guard let details = try? await IntegrationHTTP.get(
            "\(base)/person/\(id)?api_key=\(apiKey)&language=\(language)&append_to_response=combined_credits",
            as: TMDBPerson.self
        ), let name = details.name?.nilIfBlank else { return nil }

        var profile = PersonProfile(
            tmdbId: id,
            name: name,
            biography: details.biography?.nilIfBlank,
            photo: details.profile_path.map { "\(Self.imageBase)/h632\($0)" },
            birthday: details.birthday?.nilIfBlank,
            deathday: details.deathday?.nilIfBlank,
            placeOfBirth: details.place_of_birth?.nilIfBlank,
            knownFor: details.known_for_department?.nilIfBlank
        )

        // Acting credits only, deduplicated, most recent first — the crew list is noise here.
        var seen = Set<Int>()
        profile.credits = (details.combined_credits?.cast ?? [])
            .filter { ($0.media_type == "movie" || $0.media_type == "tv") }
            .filter { $0.id.map { seen.insert($0).inserted } ?? false }
            .sorted { ($0.sortDate ?? "") > ($1.sortDate ?? "") }
            .compactMap { $0.preview }
        return profile
    }

    // MARK: - Browse

    enum BrowseFilter: Hashable, Sendable {
        case network(Int)
        case company(Int)
        case genre(Int)

        var queryItem: String {
            switch self {
            case .network(let id): return "with_networks=\(id)"
            case .company(let id): return "with_companies=\(id)"
            case .genre(let id): return "with_genres=\(id)"
            }
        }
    }

    /// TMDB `discover`, used for the "more from this network / studio / genre" screens.
    func discover(
        type: ContentType,
        filter: BrowseFilter,
        page: Int,
        apiKey: String,
        language: String
    ) async -> [MetaPreview] {
        guard !apiKey.isEmpty else { return [] }
        let mediaType = type == .series ? "tv" : "movie"
        guard let response = try? await IntegrationHTTP.get(
            "\(base)/discover/\(mediaType)?api_key=\(apiKey)&language=\(language)"
                + "&sort_by=popularity.desc&page=\(max(1, page))&\(filter.queryItem)",
            as: TMDBDiscoverResponse.self
        ) else { return [] }
        return (response.results ?? []).compactMap { $0.preview(type: type) }
    }

    // MARK: Collections

    /// A discover call with every filter Android's collection editor exposes.
    ///
    /// `BrowseFilter` above stays as it is — it serves the "more from this network" screens and
    /// carries exactly one filter with a fixed sort. A collection source can combine eighteen of
    /// them and choose the sort, which is a different question with the same endpoint.
    func discover(
        type: ContentType,
        query: TMDBDiscoverQuery,
        page: Int,
        apiKey: String,
        language: String
    ) async -> [MetaPreview] {
        guard !apiKey.isEmpty else { return [] }
        let mediaType = type == .series ? "tv" : "movie"
        let url = "\(base)/discover/\(mediaType)?api_key=\(apiKey)&language=\(language)"
            + "&page=\(max(1, page))&\(query.queryString(for: type))"
        guard let response = try? await IntegrationHTTP.get(url, as: TMDBDiscoverResponse.self) else { return [] }
        return (response.results ?? []).compactMap { $0.preview(type: type) }
    }

    /// The source kinds that name a specific TMDB entity rather than describing a query.
    ///
    /// Four of them are discover calls under a different name — a company, a network and a
    /// director are all "discover, filtered by this id" — while a list and a collection have
    /// endpoints of their own that answer with their members directly.
    func collectionItems(
        kind: TmdbSourceKind,
        tmdbId: Int,
        type: ContentType,
        sortBy: String,
        page: Int,
        apiKey: String,
        language: String
    ) async -> [MetaPreview] {
        guard !apiKey.isEmpty else { return [] }
        let mediaType = type == .series ? "tv" : "movie"

        switch kind {
        case .list:
            struct Response: Decodable { let items: [TMDBMediaItem]? }
            guard let response = try? await IntegrationHTTP.get(
                "\(base)/list/\(tmdbId)?api_key=\(apiKey)&language=\(language)&page=\(max(1, page))",
                as: Response.self
            ) else { return [] }
            // A list mixes films and series, so each row names its own type.
            return (response.items ?? []).compactMap { $0.preview(type: type) }

        case .collection:
            struct Response: Decodable { let parts: [TMDBMediaItem]? }
            guard let response = try? await IntegrationHTTP.get(
                "\(base)/collection/\(tmdbId)?api_key=\(apiKey)&language=\(language)",
                as: Response.self
            ) else { return [] }
            // A collection is served whole; asking for a second page would repeat it.
            guard page <= 1 else { return [] }
            return (response.parts ?? []).compactMap { $0.preview(type: type) }

        case .person, .director:
            struct Response: Decodable {
                let cast: [TMDBMediaItem]?
                let crew: [TMDBMediaItem]?
            }
            guard page <= 1, let response = try? await IntegrationHTTP.get(
                "\(base)/person/\(tmdbId)/combined_credits?api_key=\(apiKey)&language=\(language)",
                as: Response.self
            ) else { return [] }
            // A director is credited in crew, an actor in cast — the same person endpoint,
            // read from the other side.
            let rows = kind == .director ? (response.crew ?? []) : (response.cast ?? [])
            return rows.compactMap { $0.preview(type: type) }

        case .company, .network, .discover:
            let filter: String
            switch kind {
            case .network: filter = "with_networks=\(tmdbId)"
            case .company: filter = "with_companies=\(tmdbId)"
            default: filter = "with_genres=\(tmdbId)"
            }
            let sort = sortBy == TmdbCollectionSort.original.rawValue
                ? TmdbCollectionSort.popularityDesc.rawValue
                : sortBy
            guard let response = try? await IntegrationHTTP.get(
                "\(base)/discover/\(mediaType)?api_key=\(apiKey)&language=\(language)"
                    + "&page=\(max(1, page))&sort_by=\(sort)&\(filter)",
                as: TMDBDiscoverResponse.self
            ) else { return [] }
            return (response.results ?? []).compactMap { $0.preview(type: type) }
        }
    }

    // MARK: Episodes

    /// One season's episodes: names, overviews, air dates and stills.
    ///
    /// This is what `tmdb_use_episodes` turns on. Plenty of addons return an episode list with
    /// nothing but numbers, and a rail of "Episode 4" cards with no image is the result; TMDB
    /// fills those gaps without displacing anything the addon did supply.
    struct EpisodeDetail: Sendable, Hashable {
        var season: Int
        var episode: Int
        var name: String?
        var overview: String?
        var still: String?
        var airDate: String?
        var runtimeMinutes: Int?
        /// TMDB's own score, not IMDb's. Upstream shows an IMDb figure per episode, fetched from
        /// two services whose base URLs are build secrets pointing at `placeholder.nuvio.tv` in
        /// the public source — so that number cannot be had here. This one arrives in the same
        /// response the episode titles and stills already come from, and the UI says whose it is.
        var rating: Double?
    }

    func seasonEpisodes(
        tmdbId: Int,
        season: Int,
        apiKey: String,
        language: String
    ) async -> [EpisodeDetail] {
        guard !apiKey.isEmpty else { return [] }
        struct Episode: Decodable {
            let episode_number: Int?
            let season_number: Int?
            let name: String?
            let overview: String?
            let still_path: String?
            let air_date: String?
            let runtime: Int?
            let vote_average: Double?
        }
        struct Season: Decodable { let episodes: [Episode]? }

        guard let response = try? await IntegrationHTTP.get(
            "\(base)/tv/\(tmdbId)/season/\(season)?api_key=\(apiKey)&language=\(language)",
            as: Season.self
        ) else { return [] }

        return (response.episodes ?? []).compactMap { episode in
            guard let number = episode.episode_number else { return nil }
            return EpisodeDetail(
                season: episode.season_number ?? season,
                episode: number,
                name: episode.name?.nilIfBlank,
                overview: episode.overview?.nilIfBlank,
                still: episode.still_path.map { "\(Self.imageBase)/w780\($0)" },
                airDate: episode.air_date?.nilIfBlank,
                runtimeMinutes: episode.runtime,
                // TMDB sends 0 for an episode nobody has scored. Zero is not a score.
                rating: episode.vote_average.flatMap { $0 > 0 ? $0 : nil }
            )
        }
    }

    /// The TMDB id behind an IMDb id, without pulling the whole detail payload with it. Used by
    /// the Continue Watching enrichment, which needs an id and one still, nothing more.
    func tmdbId(imdbId: String, type: ContentType, apiKey: String) async -> Int? {
        guard !apiKey.isEmpty else { return nil }
        guard let found = try? await IntegrationHTTP.get(
            "\(base)/find/\(imdbId)?api_key=\(apiKey)&external_source=imdb_id",
            as: TMDBFindResponse.self
        ) else { return nil }
        return (type == .series ? found.tv_results?.first : found.movie_results?.first)?.id
    }

    /// Resolves a TMDB id to an IMDb id so an addon can serve the detail page. Nuvio's own
    /// screens are keyed on IMDb ids; TMDB-sourced rows would otherwise be dead ends.
    func imdbId(tmdbId: Int, type: ContentType, apiKey: String) async -> String? {
        guard !apiKey.isEmpty else { return nil }
        let mediaType = type == .series ? "tv" : "movie"
        let response = try? await IntegrationHTTP.get(
            "\(base)/\(mediaType)/\(tmdbId)/external_ids?api_key=\(apiKey)",
            as: TMDBExternalIds.self
        )
        return response?.imdb_id?.nilIfBlank
    }
}

// MARK: TMDB wire types

private struct TMDBFindResult: Decodable { let id: Int? }
private struct TMDBFindResponse: Decodable {
    let movie_results: [TMDBFindResult]?
    let tv_results: [TMDBFindResult]?
}

private struct TMDBNamed: Decodable { let id: Int?; let name: String?; let logo_path: String? }
private struct TMDBCollectionRef: Decodable { let id: Int?; let name: String? }
private struct TMDBGenre: Decodable { let name: String? }
private struct TMDBImage: Decodable { let file_path: String? }
private struct TMDBImages: Decodable { let logos: [TMDBImage]? }
private struct TMDBCastMember: Decodable {
    let id: Int?; let name: String?; let character: String?; let profile_path: String?
}
private struct TMDBCredits: Decodable { let cast: [TMDBCastMember]? }
private struct TMDBVideo: Decodable { let key: String?; let site: String?; let type: String? }
private struct TMDBVideos: Decodable { let results: [TMDBVideo]? }
private struct TMDBRecommendation: Decodable {
    let id: Int?; let title: String?; let name: String?; let overview: String?
    let poster_path: String?; let backdrop_path: String?
    let release_date: String?; let first_air_date: String?; let vote_average: Double?
}
private struct TMDBRecommendations: Decodable { let results: [TMDBRecommendation]? }
private struct TMDBContentRating: Decodable { let iso_3166_1: String?; let rating: String? }
private struct TMDBContentRatings: Decodable { let results: [TMDBContentRating]? }
private struct TMDBReleaseDateEntry: Decodable { let certification: String? }
private struct TMDBReleaseDateCountry: Decodable {
    let iso_3166_1: String?; let release_dates: [TMDBReleaseDateEntry]?
}
private struct TMDBReleaseDates: Decodable { let results: [TMDBReleaseDateCountry]? }

private struct TMDBExternalIds: Decodable { let imdb_id: String? }

/// One row of `combined_credits` or `discover`. `media_type` is absent on discover results,
/// where the endpoint already fixed the type.
private struct TMDBMediaItem: Decodable {
    let id: Int?
    let media_type: String?
    let title: String?
    let name: String?
    let overview: String?
    let poster_path: String?
    let backdrop_path: String?
    let release_date: String?
    let first_air_date: String?
    let vote_average: Double?
    let character: String?

    var sortDate: String? { release_date?.nilIfBlank ?? first_air_date?.nilIfBlank }

    var preview: MetaPreview? {
        preview(type: media_type == "tv" ? .series : .movie)
    }

    func preview(type: ContentType) -> MetaPreview? {
        guard let id, let displayName = (title ?? name)?.nilIfBlank else { return nil }
        return MetaPreview(
            id: "tmdb:\(id)",
            type: type,
            rawType: type.apiString(),
            name: displayName,
            poster: poster_path.map { "\(TMDBClient.imageBase)/w500\($0)" },
            background: backdrop_path.map { "\(TMDBClient.imageBase)/original\($0)" },
            description: overview?.nilIfBlank,
            releaseInfo: sortDate.map { String($0.prefix(4)) },
            imdbRating: vote_average.flatMap { $0 > 0 ? Float($0) : nil }
        )
    }
}

private struct TMDBCombinedCredits: Decodable { let cast: [TMDBMediaItem]? }
private struct TMDBDiscoverResponse: Decodable { let results: [TMDBMediaItem]? }

private struct TMDBPerson: Decodable {
    let name: String?
    let biography: String?
    let profile_path: String?
    let birthday: String?
    let deathday: String?
    let place_of_birth: String?
    let known_for_department: String?
    let combined_credits: TMDBCombinedCredits?
}

private struct TMDBDetails: Decodable {
    let overview: String?
    let vote_average: Double?
    let runtime: Int?
    let episode_run_time: [Int]?
    let backdrop_path: String?
    let poster_path: String?
    let genres: [TMDBGenre]?
    let networks: [TMDBNamed]?
    let production_companies: [TMDBNamed]?
    let images: TMDBImages?
    let credits: TMDBCredits?
    let videos: TMDBVideos?
    let recommendations: TMDBRecommendations?
    let content_ratings: TMDBContentRatings?
    let release_dates: TMDBReleaseDates?
    let belongs_to_collection: TMDBCollectionRef?

    func certification(for country: String) -> String? {
        if let rating = content_ratings?.results?
            .first(where: { $0.iso_3166_1 == country })?.rating?.nilIfBlank {
            return rating
        }
        return release_dates?.results?
            .first(where: { $0.iso_3166_1 == country })?
            .release_dates?.compactMap { $0.certification?.nilIfBlank }.first
    }
}

// MARK: - MDBList (port of MDBListApi)

/// Aggregated ratings shown on the detail hero.
struct MDBListRatings: Hashable, Sendable {
    var imdb: Double?
    var tmdb: Double?
    var tomatoes: Double?
    var audience: Double?
    var metacritic: Double?
    var trakt: Double?
    var letterboxd: Double?
    var mal: Double?

    var isEmpty: Bool {
        [imdb, tmdb, tomatoes, audience, metacritic, trakt, letterboxd, mal].allSatisfy { $0 == nil }
    }
}

actor MDBListClient {
    static let shared = MDBListClient()
    private var cache: [String: MDBListRatings] = [:]

    func ratings(imdbId: String, apiKey: String) async -> MDBListRatings? {
        guard !apiKey.isEmpty, !imdbId.isEmpty else { return nil }
        if let hit = cache[imdbId] { return hit }

        guard let response = try? await IntegrationHTTP.get(
            "https://api.mdblist.com/?apikey=\(apiKey)&i=\(imdbId)",
            as: MDBListResponse.self
        ) else { return nil }

        var ratings = MDBListRatings()
        for entry in response.ratings ?? [] {
            guard let source = entry.source?.lowercased(), let value = entry.value else { continue }
            switch source {
            case "imdb": ratings.imdb = value
            case "tmdb": ratings.tmdb = value
            case "tomatoes": ratings.tomatoes = value
            case "audience": ratings.audience = value
            case "metacritic": ratings.metacritic = value
            case "trakt": ratings.trakt = value
            case "letterboxd": ratings.letterboxd = value
            case "myanimelist", "mal": ratings.mal = value
            default: break
            }
        }
        cache[imdbId] = ratings
        return ratings
    }
}

private struct MDBListRatingEntry: Decodable { let source: String?; let value: Double? }
private struct MDBListResponse: Decodable { let ratings: [MDBListRatingEntry]? }

// MARK: - Trakt (port of TraktAuthService / TraktScrobbleService)

/// Device-code OAuth plus scrobbling and watched sync.
///
/// The Android build bakes Nuvio's own Trakt client into BuildConfig. A third-party client
/// cannot ship those credentials, so the viewer registers their own Trakt application and
/// pastes the id/secret in Settings — the flow is otherwise identical.
actor TraktClient {
    static let shared = TraktClient()
    private let base = "https://api.trakt.tv"
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "Trakt")

    struct DeviceCode: Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let expiresIn: Int
        let interval: Int
    }

    struct Tokens: Sendable {
        let accessToken: String
        let refreshToken: String
    }

    private func headers(clientId: String, token: String? = nil) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "trakt-api-version": "2",
            "trakt-api-key": clientId
        ]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    // MARK: Auth

    func startDeviceAuth(clientId: String) async throws -> DeviceCode {
        struct Request: Encodable { let client_id: String }
        struct Response: Decodable {
            let device_code: String; let user_code: String; let verification_url: String
            let expires_in: Int; let interval: Int
        }
        let response = try await IntegrationHTTP.post(
            "\(base)/oauth/device/code",
            headers: headers(clientId: clientId),
            json: Request(client_id: clientId),
            as: Response.self
        )
        return DeviceCode(
            deviceCode: response.device_code,
            userCode: response.user_code,
            verificationURL: response.verification_url,
            expiresIn: response.expires_in,
            interval: response.interval
        )
    }

    /// Polls until the viewer approves the code on trakt.tv, or the code expires.
    func pollForToken(
        deviceCode: String, clientId: String, clientSecret: String, interval: Int, expiresIn: Int
    ) async -> Tokens? {
        struct Request: Encodable {
            let code: String; let client_id: String; let client_secret: String
        }
        struct Response: Decodable { let access_token: String; let refresh_token: String }

        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(max(interval, 5)))
            if Task.isCancelled { return nil }
            if let response = try? await IntegrationHTTP.post(
                "\(base)/oauth/device/token",
                headers: headers(clientId: clientId),
                json: Request(code: deviceCode, client_id: clientId, client_secret: clientSecret),
                as: Response.self
            ) {
                return Tokens(accessToken: response.access_token, refreshToken: response.refresh_token)
            }
        }
        return nil
    }

    func username(clientId: String, token: String) async -> String? {
        struct User: Decodable { let username: String? }
        struct Settings: Decodable { let user: User? }
        let settings = try? await IntegrationHTTP.get(
            "\(base)/users/settings",
            headers: headers(clientId: clientId, token: token),
            as: Settings.self
        )
        return settings?.user?.username
    }

    // MARK: Scrobble

    enum ScrobbleAction: String { case start, pause, stop }

    /// Trakt treats a `stop` above 80% as a completed watch, which is what marks episodes
    /// watched on the account.
    func scrobble(
        action: ScrobbleAction,
        imdbId: String,
        type: ContentType,
        season: Int?,
        episode: Int?,
        progressPercent: Double,
        clientId: String,
        token: String
    ) async {
        struct Ids: Encodable { let imdb: String }
        struct Show: Encodable { let ids: Ids }
        struct EpisodeRef: Encodable { let season: Int; let number: Int }
        struct MovieRef: Encodable { let ids: Ids }
        struct Payload: Encodable {
            var movie: MovieRef?
            var show: Show?
            var episode: EpisodeRef?
            let progress: Double
        }

        var payload = Payload(progress: min(max(progressPercent, 0), 100))
        if type == .series, let season, let episode {
            payload.show = Show(ids: Ids(imdb: imdbId))
            payload.episode = EpisodeRef(season: season, number: episode)
        } else {
            payload.movie = MovieRef(ids: Ids(imdb: imdbId))
        }

        _ = try? await IntegrationHTTP.post(
            "\(base)/scrobble/\(action.rawValue)",
            headers: headers(clientId: clientId, token: token),
            json: payload,
            as: EmptyResponse.self
        )
    }


    // MARK: Mutations

    /// Endpoints ported from the Android client's `TraktApi`, not guessed: `sync/watchlist`,
    /// `sync/history` and their `/remove` twins, with the DTO shapes from `TraktSyncDtos.kt`.
    ///
    /// Upstream has no `sync/collection` call at all, so neither does this — a collection write
    /// would be a feature the app being ported does not have.
    enum SyncList: Sendable {
        case watchlist
        case history

        var path: String {
            switch self {
            case .watchlist: return "sync/watchlist"
            case .history: return "sync/history"
            }
        }
    }

    /// Trakt answers a write with 201 whether or not it recognised the title, and reports the
    /// misses in `not_found`. A caller that only checks the status code reports success for a
    /// write that changed nothing, which is the failure this whole path exists to stop.
    struct SyncOutcome: Sendable, Equatable {
        var accepted: Int
        var notFound: Int

        var didChangeAnything: Bool { accepted > 0 }
        var isClean: Bool { accepted > 0 && notFound == 0 }
    }

    func write(
        _ list: SyncList,
        removing: Bool,
        imdbId: String,
        type: ContentType,
        season: Int? = nil,
        episode: Int? = nil,
        clientId: String,
        token: String
    ) async throws -> SyncOutcome {
        struct Ids: Encodable { let imdb: String }
        struct EpisodeRef: Encodable { let number: Int }
        struct SeasonRef: Encodable { let number: Int; var episodes: [EpisodeRef]? }
        struct MovieRef: Encodable { let ids: Ids }
        struct ShowRef: Encodable { let ids: Ids; var seasons: [SeasonRef]? }
        struct Payload: Encodable {
            var movies: [MovieRef]?
            var shows: [ShowRef]?
        }

        var payload = Payload()
        if type == .series {
            var show = ShowRef(ids: Ids(imdb: imdbId), seasons: nil)
            // A season and episode narrow the write to that episode; without them the whole show
            // is the subject, which is what "add this series to the watchlist" means.
            if let season, let episode {
                show.seasons = [SeasonRef(number: season, episodes: [EpisodeRef(number: episode)])]
            }
            payload.shows = [show]
        } else {
            payload.movies = [MovieRef(ids: Ids(imdb: imdbId))]
        }

        struct Counts: Decodable {
            let movies: Int?
            let shows: Int?
            let seasons: Int?
            let episodes: Int?
            var total: Int { (movies ?? 0) + (shows ?? 0) + (seasons ?? 0) + (episodes ?? 0) }
        }
        struct Ignored: Decodable {}
        struct NotFound: Decodable {
            let movies: [Ignored]?
            let shows: [Ignored]?
            let seasons: [Ignored]?
            let episodes: [Ignored]?
            var total: Int {
                (movies?.count ?? 0) + (shows?.count ?? 0)
                    + (seasons?.count ?? 0) + (episodes?.count ?? 0)
            }
        }
        struct Response: Decodable {
            let added: Counts?
            let deleted: Counts?
            let existing: Counts?
            let not_found: NotFound?
        }

        let path = removing ? "\(list.path)/remove" : list.path
        let response = try await IntegrationHTTP.post(
            "\(base)/\(path)",
            headers: headers(clientId: clientId, token: token),
            json: payload,
            as: Response.self
        )
        // `existing` counts as accepted: asking Trakt to add something already on the list is
        // the outcome the viewer wanted, not a failure to report to them.
        let accepted = (response.added?.total ?? 0)
            + (response.deleted?.total ?? 0)
            + (response.existing?.total ?? 0)
        return SyncOutcome(accepted: accepted, notFound: response.not_found?.total ?? 0)
    }

    // MARK: Sync

    struct PlaybackItem: Sendable {
        let imdbId: String
        let type: ContentType
        let season: Int?
        let episode: Int?
        let progress: Double
        let pausedAt: Date?
        /// The playback session, which is what `DELETE /sync/playback/{id}` addresses. Without
        /// it a row removed from Continue Watching comes back on the next sync.
        var sessionId: Int?
    }

    struct LibraryList: Sendable, Identifiable {
        let id: String
        let title: String
        let items: [MetaPreview]
    }

    /// Removes one remote resume point. See `SimklClient.deletePlayback` — same endpoint, same
    /// reason: without it the next sync adopts back what the viewer just removed.
    func deletePlayback(sessionId: Int, clientId: String, token: String) async throws {
        try await IntegrationHTTP.delete(
            "\(base)/sync/playback/\(sessionId)",
            headers: headers(clientId: clientId, token: token)
        )
    }

    /// Trakt's resume points, used when watch progress is sourced from Trakt.
    func playbackProgress(clientId: String, token: String) async -> [PlaybackItem] {
        struct Ids: Decodable { let imdb: String? }
        struct Movie: Decodable { let ids: Ids? }
        struct Show: Decodable { let ids: Ids? }
        struct Episode: Decodable { let season: Int?; let number: Int? }
        struct Item: Decodable {
            let id: Int?
            let progress: Double?
            let paused_at: String?
            let type: String?
            let movie: Movie?
            let show: Show?
            let episode: Episode?
        }

        guard let items = try? await IntegrationHTTP.get(
            "\(base)/sync/playback?limit=100",
            headers: headers(clientId: clientId, token: token),
            as: [Item].self
        ) else { return [] }

        return items.compactMap { item in
            let isEpisode = item.type == "episode"
            guard let imdb = (isEpisode ? item.show?.ids?.imdb : item.movie?.ids?.imdb) else { return nil }
            return PlaybackItem(
                imdbId: imdb,
                type: isEpisode ? .series : .movie,
                season: item.episode?.season,
                episode: item.episode?.number,
                progress: item.progress ?? 0,
                pausedAt: item.paused_at.flatMap { VideoDateParser.parse($0) },
                sessionId: item.id
            )
        }
    }

    /// The user's Trakt collection, used when the library is sourced from Trakt.
    func collection(type: ContentType, clientId: String, token: String) async -> [MetaPreview] {
        await libraryEntries(path: "sync/collection", type: type, clientId: clientId, token: token)
    }

    /// The account watchlist is distinct from the collection on Android's Library screen.
    func watchlist(type: ContentType, clientId: String, token: String) async -> [MetaPreview] {
        await libraryEntries(path: "sync/watchlist", type: type, clientId: clientId, token: token)
    }

    func libraryLists(clientId: String, token: String) async -> [LibraryList] {
        async let collectionMovies = collection(type: .movie, clientId: clientId, token: token)
        async let collectionShows = collection(type: .series, clientId: clientId, token: token)
        async let watchlistMovies = watchlist(type: .movie, clientId: clientId, token: token)
        async let watchlistShows = watchlist(type: .series, clientId: clientId, token: token)
        let collection = await collectionMovies + collectionShows
        let watchlist = await watchlistMovies + watchlistShows
        return [
            LibraryList(id: "collection", title: "Collection", items: collection),
            LibraryList(id: "watchlist", title: "Watchlist", items: watchlist)
        ].filter { !$0.items.isEmpty }
    }

    /// One Trakt list by id, which is what a collection source names.
    ///
    /// Distinct from `collection` and `watchlist` above: those are the signed-in viewer's own two
    /// fixed lists, this is any list on Trakt. A public list needs no token, so one is optional —
    /// a collection built on another device should still resolve before you sign in here.
    func listItems(
        listId: Int,
        type: ContentType,
        sortBy: String,
        sortHow: String,
        clientId: String,
        token: String? = nil
    ) async -> [MetaPreview] {
        struct Ids: Decodable { let imdb: String?; let trakt: Int? }
        struct Entry: Decodable { let title: String?; let year: Int?; let ids: Ids? }
        struct Item: Decodable { let movie: Entry?; let show: Entry? }

        let path = type == .series ? "shows" : "movies"
        let sort = "\(TraktListSort.normalize(sortBy))/\(TraktSortHow.normalize(sortHow))"
        guard let items = try? await IntegrationHTTP.get(
            "\(base)/lists/\(listId)/items/\(path)/\(sort)",
            headers: headers(clientId: clientId, token: token),
            as: [Item].self
        ) else { return [] }

        return items.compactMap { item in
            let entry = type == .series ? item.show : item.movie
            guard let entry, let title = entry.title, let imdb = entry.ids?.imdb else { return nil }
            return MetaPreview(
                id: imdb,
                type: type,
                rawType: type.apiString(),
                name: title,
                releaseInfo: entry.year.map(String.init),
                imdbId: imdb
            )
        }
    }

    /// Trakt's own "related" titles, for the More like this row when the viewer sources it here.
    ///
    /// Public data: the client id is enough, no token. Trakt accepts an IMDb id wherever it takes
    /// a slug, so nothing has to be resolved first.
    func related(imdbId: String, type: ContentType, clientId: String) async -> [MetaPreview] {
        struct Ids: Decodable { let imdb: String? }
        struct Entry: Decodable { let title: String?; let year: Int?; let ids: Ids? }

        let path = type == .series ? "shows" : "movies"
        guard let items = try? await IntegrationHTTP.get(
            "\(base)/\(path)/\(imdbId)/related",
            headers: headers(clientId: clientId, token: nil),
            as: [Entry].self
        ) else { return [] }

        return items.compactMap { entry in
            guard let title = entry.title, let imdb = entry.ids?.imdb else { return nil }
            return MetaPreview(
                id: imdb,
                type: type,
                rawType: type.apiString(),
                name: title,
                releaseInfo: entry.year.map(String.init),
                imdbId: imdb
            )
        }
    }

    private func libraryEntries(path prefix: String, type: ContentType, clientId: String, token: String) async -> [MetaPreview] {
        struct Ids: Decodable { let imdb: String?; let trakt: Int? }
        struct Entry: Decodable { let title: String?; let year: Int?; let ids: Ids? }
        struct Item: Decodable { let movie: Entry?; let show: Entry? }

        let path = type == .series ? "shows" : "movies"
        guard let items = try? await IntegrationHTTP.get(
            "\(base)/\(prefix)/\(path)",
            headers: headers(clientId: clientId, token: token),
            as: [Item].self
        ) else { return [] }

        return items.compactMap { item in
            let entry = type == .series ? item.show : item.movie
            guard let entry, let title = entry.title, let imdb = entry.ids?.imdb else { return nil }
            return MetaPreview(
                id: imdb,
                type: type,
                rawType: type.apiString(),
                name: title,
                releaseInfo: entry.year.map(String.init),
                imdbId: imdb
            )
        }
    }

    // MARK: Comments

    struct Comment: Hashable, Sendable, Identifiable {
        var id: Int
        var author: String
        var avatar: String?
        var body: String
        var likes: Int
        var replies: Int
        var isSpoiler: Bool
        var isReview: Bool
        var userRating: Int?
        var createdAt: Date?
    }

    /// Comments and reviews for one title. Public data, so it needs the client id but no token.
    /// Trakt keys comments on its own slugs, and an IMDb id is a valid lookup id for those.
    func comments(
        imdbId: String,
        type: ContentType,
        clientId: String,
        page: Int = 1,
        sort: String = "likes"
    ) async -> [Comment] {
        struct User: Decodable {
            struct Images: Decodable {
                struct Avatar: Decodable { let full: String? }
                let avatar: Avatar?
            }
            let username: String?
            let name: String?
            let images: Images?
        }
        struct Entry: Decodable {
            let id: Int?
            let comment: String?
            let spoiler: Bool?
            let review: Bool?
            let replies: Int?
            let likes: Int?
            let user_rating: Int?
            let created_at: String?
            let user: User?
        }

        guard !clientId.isEmpty else { return [] }
        let path = type == .series ? "shows" : "movies"
        guard let entries = try? await IntegrationHTTP.get(
            "\(base)/\(path)/\(imdbId)/comments/\(sort)?page=\(max(1, page))&limit=25&extended=images",
            headers: headers(clientId: clientId),
            as: [Entry].self
        ) else { return [] }

        return entries.compactMap { entry in
            guard let id = entry.id, let body = entry.comment?.nilIfBlank else { return nil }
            let author = entry.user?.username?.nilIfBlank
                ?? entry.user?.name?.nilIfBlank
                ?? "Someone"
            return Comment(
                id: id,
                author: author,
                avatar: entry.user?.images?.avatar?.full?.nilIfBlank,
                body: body,
                likes: entry.likes ?? 0,
                replies: entry.replies ?? 0,
                isSpoiler: entry.spoiler ?? false,
                isReview: entry.review ?? false,
                userRating: entry.user_rating,
                createdAt: entry.created_at.flatMap { VideoDateParser.parse($0) }
            )
        }
    }
}

// MARK: - Skip intro (AniSkip / Anime-Skip)

struct SkipSegment: Hashable, Sendable {
    enum Kind: String, Sendable { case intro, outro, recap, mixed }
    var kind: Kind
    var start: Double
    var end: Double

    var id: String { "\(kind.rawValue):\(start):\(end)" }
}

actor SkipIntroClient {
    static let shared = SkipIntroClient()
    private var cache: [String: [SkipSegment]] = [:]
    /// One id mapping serves every episode of a series, so it is kept for the session.
    private var armCache: [String: [ArmEntry]] = [:]
    /// Anime-Skip's own show ids, per AniList id. Misses are cached too, so a title it has never
    /// heard of is asked about once rather than on every episode.
    private var animeSkipShowCache: [String: [String]] = [:]

    /// One season's worth of the anime id mappings, as ARM returns them.
    struct ArmEntry: Decodable, Sendable {
        let myanimelist: Int?
        let anilist: Int?
    }

    /// AniSkip is keyed by MyAnimeList id; the ARM service maps IMDb ids across to MAL.
    func segments(malId: Int, episode: Int, episodeLength: Double) async -> [SkipSegment] {
        let key = "\(malId)-\(episode)"
        if let hit = cache[key] { return hit }

        let types = ["op", "ed", "recap", "mixed-op", "mixed-ed"]
            .map { "types[]=\($0)" }
            .joined(separator: "&")
        let url = "https://api.aniskip.com/v2/skip-times/\(malId)/\(episode)"
            + "?\(types)&episodeLength=\(Int(episodeLength))"

        guard let response = try? await IntegrationHTTP.get(url, as: AniSkipResponse.self) else { return [] }
        let segments = Self.segments(from: response)
        cache[key] = segments
        return segments
    }

    /// AniSkip answers in camelCase. Decoded as snake_case it did not fail — the fields simply
    /// came back nil, every result was dropped, and a title with marks looked exactly like a
    /// title without any. Which is why the shape is now pinned by a test against a real payload.
    struct AniSkipResponse: Decodable, Sendable {
        struct Interval: Decodable, Sendable {
            let startTime: Double?
            let endTime: Double?
        }
        struct Result: Decodable, Sendable {
            let interval: Interval?
            let skipType: String?
        }
        let found: Bool?
        let results: [Result]?
    }

    nonisolated static func segments(from response: AniSkipResponse) -> [SkipSegment] {
        guard response.found == true, let results = response.results else { return [] }
        return results.compactMap { result -> SkipSegment? in
            guard let start = result.interval?.startTime,
                  let end = result.interval?.endTime,
                  end > start else { return nil }
            let kind: SkipSegment.Kind
            switch result.skipType {
            case "op", "mixed-op": kind = .intro
            case "ed", "mixed-ed": kind = .outro
            case "recap": kind = .recap
            default: kind = .mixed
            }
            return SkipSegment(kind: kind, start: start, end: end)
        }
    }

    /// Picks the MAL id for a season out of ARM's per-season array. Separated from the request
    /// so the indexing — one-based seasons against a zero-based dense array, with nulls for
    /// seasons MAL has no title for — can be checked without a network.
    nonisolated static func malId(fromSeasonEntries entries: [Int?], season: Int) -> Int? {
        if season >= 1, season <= entries.count, let mal = entries[season - 1] { return mal }
        return entries.compactMap { $0 }.first
    }

    /// The same indexing for AniList, which is what Anime-Skip is keyed by.
    nonisolated static func anilistId(fromSeasonEntries entries: [Int?], season: Int) -> Int? {
        malId(fromSeasonEntries: entries, season: season)
    }

    // MARK: Merging providers

    /// Fills each category — opening, ending, recap — from the first provider that has it.
    ///
    /// The alternative, and what this replaces, is to take whichever provider answers first and
    /// stop. That loses segments the moment a provider is partially populated, which is common:
    /// IntroDB has an intro but no outro for *One Piece*, so an early return meant AniSkip was
    /// never asked and the outro simply did not exist as far as the player was concerned.
    ///
    /// `results` must be given in priority order. `.mixed` belongs to no category and is dropped,
    /// as upstream drops it — it is the fallback for a skip type nobody recognises, and an
    /// unrecognised type has no reliable meaning to offer a viewer.
    nonisolated static func merge(_ results: [[SkipSegment]]) -> [SkipSegment] {
        var chosen: [SkipSegment.Kind: SkipSegment] = [:]
        for provider in results {
            for segment in provider where segment.kind != .mixed {
                if chosen[segment.kind] == nil { chosen[segment.kind] = segment }
            }
        }
        // Chronological, so the button appears in the order the segments play.
        return chosen.values.sorted { $0.start < $1.start }
    }

    /// IntroDB covers everything AniSkip does not — ordinary series rather than anime — and is
    /// where the Android app gets intro, recap and outro marks for the rest of the catalogue.
    ///
    /// The Android build reads its base URL from a private `local.properties`, which is why this
    /// used to ask the viewer for it and did nothing until they supplied one. That was a wrong
    /// reading of a build convention: the service publishes an OpenAPI document at
    /// `api.introdb.app/openapi.json` describing this very route, and it answers without a key.
    /// `SkipIntroSettingsStore.introDbApiUrl` now only overrides the default.
    static let introDbDefaultBaseURL = "https://api.introdb.app"

    func introDbSegments(baseURL: String, imdbId: String, season: Int, episode: Int) async -> [SkipSegment] {
        let key = "introdb-\(imdbId)-\(season)-\(episode)"
        if let hit = cache[key] { return hit }

        struct Segment: Decodable {
            let start_sec: Double?
            let end_sec: Double?
            let start_ms: Double?
            let end_ms: Double?

            var range: (start: Double, end: Double)? {
                guard let start = start_sec ?? start_ms.map({ $0 / 1000 }),
                      let end = end_sec ?? end_ms.map({ $0 / 1000 }),
                      end > start else { return nil }
                return (start, end)
            }
        }
        struct Response: Decodable {
            let intro: Segment?
            let recap: Segment?
            let outro: Segment?
        }

        let override = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = override.isEmpty ? Self.introDbDefaultBaseURL : override
        guard let encoded = imdbId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return [] }

        let url = "\(base)/segments?imdb_id=\(encoded)&season=\(season)&episode=\(episode)"
        guard let response = try? await IntegrationHTTP.get(url, as: Response.self) else { return [] }

        let segments = [
            (response.intro, SkipSegment.Kind.intro),
            (response.recap, SkipSegment.Kind.recap),
            (response.outro, SkipSegment.Kind.outro)
        ].compactMap { entry -> SkipSegment? in
            guard let range = entry.0?.range else { return nil }
            return SkipSegment(kind: entry.1, start: range.start, end: range.end)
        }
        cache[key] = segments
        return segments
    }

    // MARK: Anime-Skip

    /// The third provider, and the only one that needs anything of the viewer: a client id from
    /// anime-skip.com. Upstream gates it the same way, so with no id this is simply absent and
    /// the other two carry the feature.
    ///
    /// Two GraphQL round trips — the show, then its episodes — because Anime-Skip is keyed by its
    /// own show ids and only maps in from AniList.
    func animeSkipSegments(
        anilistId: Int,
        episode: Int,
        season: Int?,
        episodeLength: Double,
        clientId: String
    ) async -> [SkipSegment] {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        for showId in await animeSkipShowIds(anilistId: anilistId, clientId: trimmed) {
            let query = "{ findEpisodesByShowId(showId: \"\(showId)\") "
                + "{ season number timestamps { at type { name } } } }"
            guard let response = try? await IntegrationHTTP.post(
                Self.animeSkipEndpoint,
                headers: ["X-Client-ID": trimmed],
                json: AnimeSkipRequest(query: query),
                as: AnimeSkipResponse.self
            ) else { continue }

            let segments = Self.segments(
                from: response.data?.findEpisodesByShowId ?? [],
                episode: episode,
                season: season,
                episodeLength: episodeLength
            )
            if !segments.isEmpty { return segments }
        }
        return []
    }

    static let animeSkipEndpoint = "https://api.anime-skip.com/graphql"

    struct AnimeSkipRequest: Encodable, Sendable {
        let query: String
    }

    struct AnimeSkipResponse: Decodable, Sendable {
        struct Show: Decodable, Sendable { let id: String }
        struct TimestampType: Decodable, Sendable { let name: String }
        struct Timestamp: Decodable, Sendable {
            let at: Double
            let type: TimestampType
        }
        struct Episode: Decodable, Sendable {
            /// Strings on the wire, not numbers — GraphQL ids rather than integers.
            let season: String?
            let number: String?
            let timestamps: [Timestamp]?
        }
        struct DataBlock: Decodable, Sendable {
            let findShowsByExternalId: [Show]?
            let findEpisodesByShowId: [Episode]?
        }
        let data: DataBlock?
    }

    /// Anime-Skip publishes **points in time, not ranges**: a timestamp marks where a section
    /// begins, and it runs until the next one. The final timestamp has no successor, so it is
    /// closed with the episode's own duration — upstream uses `Double.MAX_VALUE` there, which
    /// would offer to skip the entire remainder of the file.
    nonisolated static func segments(
        from episodes: [AnimeSkipResponse.Episode],
        episode: Int,
        season: Int?,
        episodeLength: Double
    ) -> [SkipSegment] {
        guard let match = episodes.first(where: { candidate in
            candidate.number.flatMap(Int.init) == episode
                && (season == nil || candidate.season.flatMap(Int.init) == season)
        }), let timestamps = match.timestamps else { return [] }

        let sorted = timestamps.sorted { $0.at < $1.at }
        return sorted.enumerated().compactMap { index, timestamp in
            guard let kind = animeSkipKind(timestamp.type.name) else { return nil }
            let end = index + 1 < sorted.count ? sorted[index + 1].at : episodeLength
            guard end > timestamp.at else { return nil }
            return SkipSegment(kind: kind, start: timestamp.at, end: end)
        }
    }

    /// Anime-Skip names its section types in prose, and the names carry the "new"/"mixed"
    /// qualifiers that AniSkip encodes in its skip type. Anything unrecognised is dropped rather
    /// than guessed at.
    nonisolated static func animeSkipKind(_ name: String) -> SkipSegment.Kind? {
        switch name.lowercased() {
        case "intro", "new intro", "mixed intro": return .intro
        case "credits", "new credits", "mixed credits": return .outro
        case "recap": return .recap
        default: return nil
        }
    }

    private func animeSkipShowIds(anilistId: Int, clientId: String) async -> [String] {
        let key = String(anilistId)
        if let hit = animeSkipShowCache[key] { return hit }

        let query = "{ findShowsByExternalId(service: ANILIST, serviceId: \"\(anilistId)\") { id } }"
        let response = try? await IntegrationHTTP.post(
            Self.animeSkipEndpoint,
            headers: ["X-Client-ID": clientId],
            json: AnimeSkipRequest(query: query),
            as: AnimeSkipResponse.self
        )
        let ids = response?.data?.findShowsByExternalId?.map(\.id) ?? []
        // A miss is worth remembering: without this, a title Anime-Skip has never heard of costs
        // a round trip on every single episode.
        animeSkipShowCache[key] = ids
        return ids
    }

    // MARK: ARM id mapping

    /// Maps an IMDb id to the anime ids the two anime providers are keyed by.
    ///
    /// The route matters and the shape matters. `/ids?source=imdb` — which this used to call —
    /// answers 400 for every IMDb id; the mapping lives at `/imdb?id=`, and it answers with an
    /// **array, one entry per season**, because a single IMDb entry covers an anime that MAL
    /// splits into a separate title per season. Taking element zero would give season one's
    /// opening for every season of a long-running show.
    func armEntries(imdbId: String) async -> [ArmEntry] {
        let key = "arm-\(imdbId)"
        if let hit = armCache[key] { return hit }

        guard let encoded = imdbId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let fetched = try? await IntegrationHTTP.get(
                "https://arm.haglund.dev/api/v2/imdb?id=\(encoded)&include=myanimelist,anilist",
                as: [ArmEntry].self
              )
        else { return [] }
        armCache[key] = fetched
        return fetched
    }

    func malId(imdbId: String, season: Int) async -> Int? {
        let entries = await armEntries(imdbId: imdbId)
        return Self.malId(fromSeasonEntries: entries.map(\.myanimelist), season: season)
    }
}

// MARK: - Simkl

/// Second tracking service alongside Trakt. Simkl authenticates with a PIN the viewer types on
/// simkl.com rather than a device code and uses its own start/pause/stop scrobble endpoints.
/// The five list states Simkl keeps, in its own wire vocabulary. Same set the library
/// projection already reads, named once so a read and a write cannot drift apart.
enum SimklListStatus: String, Sendable, CaseIterable {
    case watching
    case planToWatch = "plantowatch"
    case hold
    case completed
    case dropped
}

actor SimklClient {
    static let shared = SimklClient()
    private let base = "https://api.simkl.com"
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "Simkl")

    struct PinCode: Sendable {
        let userCode: String
        let verificationURL: String
        let expiresIn: Int
        let interval: Int
    }

    struct LibraryList: Sendable, Identifiable {
        let id: String
        let title: String
        let items: [MetaPreview]
    }

    /// Simkl returns ids as either JSON strings or numbers depending on the source database.
    /// Keeping that tolerance at the boundary prevents an otherwise valid list from being
    /// discarded because one anime happened to carry a numeric MAL id.
    private enum FlexibleID: Decodable, Sendable {
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode(Int64.self) { self = .string(String(value)); return }
            if let value = try? container.decode(Double.self) {
                self = .string(value.rounded() == value ? String(Int64(value)) : String(value))
                return
            }
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported Simkl id")
            )
        }

        var value: String {
            switch self { case .string(let value): return value }
        }
    }

    private struct LibraryPayload: Decodable, Sendable {
        struct Media: Decodable, Sendable {
            let title: String?
            let poster: String?
            let year: Int?
            let runtime: Int?
            let ids: [String: FlexibleID]?
        }

        struct Entry: Decodable, Sendable {
            let status: String?
            let anime_type: String?
            let added_to_watchlist_at: String?
            let last_watched_at: String?
            let show: Media?
            let movie: Media?
        }

        let shows: [Entry]
        let movies: [Entry]
        let anime: [Entry]

        private enum CodingKeys: String, CodingKey { case shows, movies, anime }

        init(from decoder: Decoder) throws {
            if let array = try? decoder.unkeyedContainer(), array.isAtEnd {
                shows = []; movies = []; anime = []
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shows = try container.decodeIfPresent([Entry].self, forKey: .shows) ?? []
            movies = try container.decodeIfPresent([Entry].self, forKey: .movies) ?? []
            anime = try container.decodeIfPresent([Entry].self, forKey: .anime) ?? []
        }
    }

    struct PlaybackItem: Sendable {
        let contentId: String
        let type: ContentType
        let title: String
        let poster: String?
        let season: Int?
        let episode: Int?
        let progress: Double
        let durationSeconds: Double
        let pausedAt: Date?
        /// As Trakt's: the session `DELETE /sync/playback/{id}` addresses.
        var sessionId: Int?
    }

    private struct PlaybackPayload: Decodable, Sendable {
        struct Episode: Decodable, Sendable {
            let season: Int?
            let number: Int?
            let tvdb_season: Int?
            let tvdb_number: Int?
        }
        struct Entry: Decodable, Sendable {
            let id: Int?
            let progress: Double?
            let paused_at: String?
            let watched_at: String?
            let episode: Episode?
            let show: LibraryPayload.Media?
            let anime: LibraryPayload.Media?
            let movie: LibraryPayload.Media?
        }
        let entries: [Entry]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            entries = try container.decode([Entry].self)
        }
    }


    // MARK: Mutations

    /// Ported from the Android client's `SimklMutationService`: `/sync/add-to-list` with a `to`
    /// field per item, `/sync/history` and `/sync/history/remove`. Note upstream's own detail —
    /// `removeFromList` is `removeFromHistory`; Simkl has no separate list-removal call.
    ///
    /// Simkl keys items by whatever id it recognises, so every id we hold is sent rather than
    /// IMDb alone. A show with only a MAL id is exactly the anime case that would otherwise be
    /// silently dropped.
    func write(
        list status: SimklListStatus?,
        removing: Bool,
        ids: [String: String],
        title: String?,
        year: Int?,
        type: ContentType,
        season: Int? = nil,
        episode: Int? = nil,
        videoId: String? = nil,
        animePreference: SimklAnimeIdPreference = .imdb,
        clientId: String,
        token: String
    ) async throws {
        struct EpisodeItem: Encodable {
            var number: Int
        }
        struct SeasonItem: Encodable {
            var number: Int
            var episodes: [EpisodeItem]
        }
        struct Item: Encodable {
            var to: String?
            var title: String?
            var year: Int?
            var ids: [String: String]?
            var episodes: [EpisodeItem]?
            var seasons: [SeasonItem]?
            var use_tvdb_anime_seasons: Bool?
        }
        struct Payload: Encodable {
            var movies: [Item]?
            var shows: [Item]?
        }

        var item = Item(
            to: status?.rawValue,
            title: title?.nilIfBlank,
            year: year,
            ids: ids.isEmpty ? nil : ids
        )

        // An episode write has to name the episode. Sending only the show's ids marks the whole
        // series, which is what this did before and is not what "watched" meant.
        //
        // Anime is where the shape matters. Simkl accepts season coordinates *or* an absolute
        // number against a per-season entry, and mixing them is not extra information — it is a
        // contradiction Simkl resolves by matching whichever id it recognises first, which lands
        // the episode on the wrong season of the wrong entry. See `SimklAnimeAddressing`.
        if type == .series, season != nil || episode != nil || videoId != nil {
            let resolved = SimklAnimeAddressing.resolve(
                videoId: videoId, ids: ids, season: season, episode: episode
            )
            item.ids = resolved.ids.isEmpty ? nil : resolved.ids
            if let season = resolved.season {
                item.seasons = [SeasonItem(number: season, episodes: [.init(number: resolved.episode)])]
                item.use_tvdb_anime_seasons = true
            } else {
                item.episodes = [EpisodeItem(number: resolved.episode)]
            }
        }
        var payload = Payload()
        if type == .movie { payload.movies = [item] } else { payload.shows = [item] }

        let path: String
        if removing {
            path = "sync/history/remove"
        } else if status == nil {
            path = "sync/history"
        } else {
            path = "sync/add-to-list"
        }

        _ = try await IntegrationHTTP.post(
            "\(base)/\(path)",
            headers: headers(clientId: clientId, token: token),
            json: payload,
            as: EmptyResponse.self
        )
    }

    private func headers(clientId: String, token: String? = nil) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "simkl-api-key": clientId
        ]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    /// The id a library row is keyed on.
    ///
    /// `preference` only changes the anime case, which is the only one where "the same show"
    /// is genuinely ambiguous — see `SimklAnimeIdPreference`.
    static func canonicalContentId(
        _ ids: [String: String],
        preference: SimklAnimeIdPreference = .imdb
    ) -> String? {
        for key in preference.preferredKeys {
            guard let value = ids[key]?.nilIfBlank else { continue }
            return key == "imdb" ? value : "\(key):\(value)"
        }
        for key in ["tmdb", "tvdb", "mal", "kitsu"] {
            if let value = ids[key]?.nilIfBlank { return "\(key):\(value)" }
        }
        if let value = (ids["simkl"] ?? ids["simkl_id"])?.nilIfBlank { return "simkl:\(value)" }
        return nil
    }

    private static func canonicalContentId(
        _ ids: [String: FlexibleID],
        preference: SimklAnimeIdPreference = .imdb
    ) -> String? {
        canonicalContentId(ids.mapValues(\.value), preference: preference)
    }

    private static func posterURL(_ path: String?) -> String? {
        guard let normalized = path?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .nilIfBlank else { return nil }
        return "https://wsrv.nl/?url=https://simkl.in/posters/\(normalized)_m.webp&q=90"
    }

    // MARK: Auth

    func startPinAuth(clientId: String) async throws -> PinCode {
        struct Response: Decodable {
            let user_code: String
            let verification_url: String
            let expires_in: Int?
            let interval: Int?
        }
        let response = try await IntegrationHTTP.get(
            "\(base)/oauth/pin?client_id=\(clientId)",
            headers: headers(clientId: clientId),
            as: Response.self
        )
        return PinCode(
            userCode: response.user_code,
            verificationURL: response.verification_url,
            expiresIn: response.expires_in ?? 900,
            interval: response.interval ?? 5
        )
    }

    /// Polls until the viewer enters the PIN on simkl.com. The endpoint answers `result: "KO"`
    /// while it is still pending, so a successful decode is not by itself an approval.
    func pollForToken(
        userCode: String, clientId: String, interval: Int, expiresIn: Int
    ) async -> String? {
        struct Response: Decodable { let result: String?; let access_token: String? }

        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(max(interval, 5)))
            if Task.isCancelled { return nil }
            if let response = try? await IntegrationHTTP.get(
                "\(base)/oauth/pin/\(userCode)?client_id=\(clientId)",
                headers: headers(clientId: clientId),
                as: Response.self
            ), let token = response.access_token?.nilIfBlank {
                return token
            }
        }
        return nil
    }

    func username(clientId: String, token: String) async -> String? {
        struct User: Decodable { let name: String? }
        struct Account: Decodable { let user: User? }
        let account = try? await IntegrationHTTP.post(
            "\(base)/users/settings",
            headers: headers(clientId: clientId, token: token),
            json: EmptyBody(),
            as: Account.self
        )
        return account?.user?.name?.nilIfBlank
    }

    // MARK: Library

    /// Mirrors Android's Simkl library projection. All statuses are fetched in one snapshot and
    /// exposed as stable rows rather than pretending Simkl is merely a write-only scrobbler.
    func libraryLists(
        clientId: String,
        token: String,
        animePreference: SimklAnimeIdPreference = .imdb
    ) async throws -> [LibraryList] {
        guard !clientId.isEmpty, !token.isEmpty else { return [] }
        var components = URLComponents(string: "\(base)/sync/all-items")!
        components.queryItems = [
            URLQueryItem(name: "extended", value: "full_anime_seasons"),
            URLQueryItem(name: "episode_watched_at", value: "yes"),
            URLQueryItem(name: "episode_tvdb_id", value: "yes"),
            URLQueryItem(name: "include_all_episodes", value: "yes"),
            URLQueryItem(name: "language", value: "en")
        ]
        let payload = try await IntegrationHTTP.get(
            components.url!.absoluteString,
            headers: headers(clientId: clientId, token: token),
            as: LibraryPayload.self
        )

        return Self.projectLibrary(payload, preference: animePreference)
    }

    /// Fixture entry point for the same tolerant decoder used by the live endpoint. Keeping the
    /// projection testable matters here because Simkl mixes numeric and string ids and returns a
    /// bare empty array for an account with no library.
    nonisolated static func decodeLibrarySnapshot(
        _ data: Data,
        preference: SimklAnimeIdPreference = .imdb
    ) throws -> [LibraryList] {
        projectLibrary(try JSONDecoder().decode(LibraryPayload.self, from: data), preference: preference)
    }

    private nonisolated static func projectLibrary(
        _ payload: LibraryPayload,
        preference: SimklAnimeIdPreference = .imdb
    ) -> [LibraryList] {
        struct Status { let id: String; let title: String }
        let statuses = [
            Status(id: "watching", title: "Watching"),
            Status(id: "plantowatch", title: "Plan to Watch"),
            Status(id: "hold", title: "On Hold"),
            Status(id: "completed", title: "Completed"),
            Status(id: "dropped", title: "Dropped")
        ]
        let entries: [(LibraryPayload.Entry, ContentType)] =
            payload.shows.map { ($0, .series) }
            + payload.movies.map { ($0, .movie) }
            + payload.anime.map { ($0, $0.anime_type == "movie" ? .movie : .series) }

        return statuses.compactMap { status in
            let matching = entries
                .filter { $0.0.status == status.id }
                .sorted { lhs, rhs in
                    let left = (lhs.0.added_to_watchlist_at ?? lhs.0.last_watched_at)
                        .flatMap(VideoDateParser.parse) ?? .distantPast
                    let right = (rhs.0.added_to_watchlist_at ?? rhs.0.last_watched_at)
                        .flatMap(VideoDateParser.parse) ?? .distantPast
                    return left > right
                }
            var seen = Set<String>()
            let items = matching.compactMap { entry, type -> MetaPreview? in
                guard entry.status == status.id, let media = entry.movie ?? entry.show,
                      let title = media.title?.nilIfBlank else { return nil }
                let ids = media.ids ?? [:]
                let imdb = ids["imdb"]?.value.nilIfBlank
                // Only the anime list is projected through the preference: it is the one place
                // where a franchise and a season are both defensible answers to "which title is
                // this". Shows and films keep IMDb.
                let canonical = Self.canonicalContentId(
                    ids, preference: type == .movie ? .imdb : preference
                )
                guard let canonical else { return nil }
                let rowKey = "\(type.apiString())|\(canonical)"
                guard seen.insert(rowKey).inserted else { return nil }
                return MetaPreview(
                    id: canonical,
                    type: type,
                    rawType: type.apiString(),
                    name: title,
                    poster: Self.posterURL(media.poster),
                    releaseInfo: media.year.map(String.init),
                    status: status.title,
                    imdbId: imdb
                )
            }
            guard !items.isEmpty else { return nil }
            return LibraryList(id: status.id, title: status.title, items: items)
        }
    }

    /// Removes one remote resume point.
    ///
    /// Both services spell it the same way, and without it removing a row from Continue Watching
    /// is undone by the next sync — the local record goes, the remote one is adopted straight
    /// back, and the row reappears looking like a bug in the removal.
    func deletePlayback(sessionId: Int, clientId: String, token: String) async throws {
        try await IntegrationHTTP.delete(
            "\(base)/sync/playback/\(sessionId)",
            headers: headers(clientId: clientId, token: token)
        )
    }

    /// Resume points used by Continue Watching when Simkl is the selected progress source.
    func playbackProgress(clientId: String, token: String) async throws -> [PlaybackItem] {
        let response = try await IntegrationHTTP.get(
            "\(base)/sync/playback",
            headers: headers(clientId: clientId, token: token),
            as: PlaybackPayload.self
        )
        return response.entries.compactMap { entry -> PlaybackItem? in
            guard let media = entry.movie ?? entry.anime ?? entry.show,
                  let title = media.title?.nilIfBlank else { return nil }
            let ids = media.ids ?? [:]
            let canonical = Self.canonicalContentId(ids)
            guard let canonical else { return nil }
            let isMovie = entry.movie != nil || (entry.anime != nil && entry.episode == nil)
            let season = entry.episode?.tvdb_season ?? entry.episode?.season
            let episode = entry.episode?.tvdb_number ?? entry.episode?.number
            guard isMovie || episode != nil else { return nil }
            return PlaybackItem(
                contentId: canonical,
                type: isMovie ? .movie : .series,
                title: title,
                poster: Self.posterURL(media.poster),
                season: season,
                episode: episode,
                progress: min(100, max(0, entry.progress ?? 0)),
                durationSeconds: Double(max(0, media.runtime ?? 0) * 60),
                pausedAt: (entry.paused_at ?? entry.watched_at).flatMap(VideoDateParser.parse),
                sessionId: entry.id
            )
        }
    }

    // MARK: Progress

    enum ScrobbleAction: String, Sendable { case start, pause, stop }

    /// Same wire contract as Android's `buildSimklScrobbleBody`: a movie is flat, while a
    /// series supplies the episode coordinates beside the parent show identity.
    func scrobble(
        action: ScrobbleAction,
        imdbId: String?,
        contentId: String,
        type: ContentType,
        season: Int?,
        episode: Int?,
        progressPercent: Double,
        clientId: String,
        token: String
    ) async {
        guard !clientId.isEmpty, !token.isEmpty else { return }
        let ids = Self.trackingIds(imdbId: imdbId, contentId: contentId)
        guard !ids.isEmpty else { return }
        do {
            _ = try await IntegrationHTTP.post(
                "\(base)/scrobble/\(action.rawValue)",
                headers: headers(clientId: clientId, token: token),
                json: ScrobbleBody(
                    ids: ids,
                    type: type,
                    season: season,
                    episode: episode,
                    progressPercent: progressPercent
                ),
                as: EmptyResponse.self
            )
        } catch {
            log.error("Simkl scrobble/\(action.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct EmptyBody: Encodable {}

    private struct ScrobbleBody: Encodable {
        struct Media: Encodable { let ids: [String: String] }
        struct Episode: Encodable { let season: Int?; let number: Int }

        let progress: Double
        let movie: Media?
        let show: Media?
        let episode: Episode?

        init(
            ids: [String: String],
            type: ContentType,
            season: Int?,
            episode: Int?,
            progressPercent: Double
        ) {
            progress = min(100, max(0, (progressPercent * 100).rounded() / 100))
            let media = Media(ids: ids)
            movie = type == .movie ? media : nil
            show = type == .movie ? nil : media
            self.episode = type == .movie ? nil : episode.map {
                Episode(season: season, number: $0)
            }
        }
    }

    private nonisolated static func trackingIds(
        imdbId: String?, contentId: String
    ) -> [String: String] {
        if let imdbId = imdbId?.nilIfBlank { return ["imdb": imdbId] }
        let value = contentId.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("tt") { return ["imdb": value] }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              ["tmdb", "tvdb", "mal", "simkl", "kitsu", "anidb", "anilist"]
                .contains(parts[0].lowercased()),
              !parts[1].isEmpty else { return [:] }
        return [parts[0].lowercased(): parts[1]]
    }

}
