import Foundation
import os

// MARK: - Shared HTTP helper

private enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }()

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
        guard let response = try? await HTTP.get(
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

        guard let found = try? await HTTP.get(
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

        guard let details = try? await HTTP.get(
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
        guard let details = try? await HTTP.get(
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
        guard let response = try? await HTTP.get(
            "\(base)/discover/\(mediaType)?api_key=\(apiKey)&language=\(language)"
                + "&sort_by=popularity.desc&page=\(max(1, page))&\(filter.queryItem)",
            as: TMDBDiscoverResponse.self
        ) else { return [] }
        return (response.results ?? []).compactMap { $0.preview(type: type) }
    }

    /// Resolves a TMDB id to an IMDb id so an addon can serve the detail page. Nuvio's own
    /// screens are keyed on IMDb ids; TMDB-sourced rows would otherwise be dead ends.
    func imdbId(tmdbId: Int, type: ContentType, apiKey: String) async -> String? {
        guard !apiKey.isEmpty else { return nil }
        let mediaType = type == .series ? "tv" : "movie"
        let response = try? await HTTP.get(
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

        guard let response = try? await HTTP.get(
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
        let response = try await HTTP.post(
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
            if let response = try? await HTTP.post(
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
        let settings = try? await HTTP.get(
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

        _ = try? await HTTP.post(
            "\(base)/scrobble/\(action.rawValue)",
            headers: headers(clientId: clientId, token: token),
            json: payload,
            as: EmptyResponse.self
        )
    }

    // MARK: Sync

    struct PlaybackItem: Sendable {
        let imdbId: String
        let type: ContentType
        let season: Int?
        let episode: Int?
        let progress: Double
        let pausedAt: Date?
    }

    struct LibraryList: Sendable, Identifiable {
        let id: String
        let title: String
        let items: [MetaPreview]
    }

    /// Trakt's resume points, used when watch progress is sourced from Trakt.
    func playbackProgress(clientId: String, token: String) async -> [PlaybackItem] {
        struct Ids: Decodable { let imdb: String? }
        struct Movie: Decodable { let ids: Ids? }
        struct Show: Decodable { let ids: Ids? }
        struct Episode: Decodable { let season: Int?; let number: Int? }
        struct Item: Decodable {
            let progress: Double?
            let paused_at: String?
            let type: String?
            let movie: Movie?
            let show: Show?
            let episode: Episode?
        }

        guard let items = try? await HTTP.get(
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
                pausedAt: item.paused_at.flatMap { VideoDateParser.parse($0) }
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

    private func libraryEntries(path prefix: String, type: ContentType, clientId: String, token: String) async -> [MetaPreview] {
        struct Ids: Decodable { let imdb: String?; let trakt: Int? }
        struct Entry: Decodable { let title: String?; let year: Int?; let ids: Ids? }
        struct Item: Decodable { let movie: Entry?; let show: Entry? }

        let path = type == .series ? "shows" : "movies"
        guard let items = try? await HTTP.get(
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
        guard let entries = try? await HTTP.get(
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

        guard let response = try? await HTTP.get(url, as: AniSkipResponse.self) else { return [] }
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
        guard let response = try? await HTTP.get(url, as: Response.self) else { return [] }

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
            guard let response = try? await HTTP.post(
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
        let response = try? await HTTP.post(
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
              let fetched = try? await HTTP.get(
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
/// simkl.com rather than a device code, and has no live scrobble endpoint — progress is reported
/// as a check-in when playback starts and a history write when it finishes.
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

    private func headers(clientId: String, token: String? = nil) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "simkl-api-key": clientId
        ]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    // MARK: Auth

    func startPinAuth(clientId: String) async throws -> PinCode {
        struct Response: Decodable {
            let user_code: String
            let verification_url: String
            let expires_in: Int?
            let interval: Int?
        }
        let response = try await HTTP.get(
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
            if let response = try? await HTTP.get(
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
        let account = try? await HTTP.post(
            "\(base)/users/settings",
            headers: headers(clientId: clientId, token: token),
            json: EmptyBody(),
            as: Account.self
        )
        return account?.user?.name?.nilIfBlank
    }

    // MARK: Progress

    /// Announces what is playing now. Simkl expires a check-in on its own, so there is no
    /// matching "stop" call to make.
    func checkin(
        imdbId: String,
        type: ContentType,
        season: Int?,
        episode: Int?,
        clientId: String,
        token: String
    ) async {
        await send(path: "sync/checkin", imdbId: imdbId, type: type, season: season, episode: episode,
                   clientId: clientId, token: token)
    }

    /// Writes the title (or single episode) into the watched history, which is what actually
    /// marks it watched on the account.
    func markWatched(
        imdbId: String,
        type: ContentType,
        season: Int?,
        episode: Int?,
        clientId: String,
        token: String
    ) async {
        await send(path: "sync/history", imdbId: imdbId, type: type, season: season, episode: episode,
                   clientId: clientId, token: token)
    }

    private func send(
        path: String,
        imdbId: String,
        type: ContentType,
        season: Int?,
        episode: Int?,
        clientId: String,
        token: String
    ) async {
        guard !clientId.isEmpty, !token.isEmpty else { return }
        do {
            _ = try await HTTP.post(
                "\(base)/\(path)",
                headers: headers(clientId: clientId, token: token),
                json: SyncBody(imdbId: imdbId, type: type, season: season, episode: episode),
                as: EmptyResponse.self
            )
        } catch {
            log.error("Simkl \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct EmptyBody: Encodable {}

    /// Simkl's sync payload: movies as a flat list, shows as a nested season/episode tree.
    private struct SyncBody: Encodable {
        struct Ids: Encodable { let imdb: String }
        struct Episode: Encodable { let number: Int }
        struct Season: Encodable { let number: Int; let episodes: [Episode]? }
        struct Show: Encodable { let ids: Ids; let seasons: [Season]? }
        struct Movie: Encodable { let ids: Ids }

        let movies: [Movie]?
        let shows: [Show]?

        init(imdbId: String, type: ContentType, season: Int?, episode: Int?) {
            let ids = Ids(imdb: imdbId)
            if type == .series {
                movies = nil
                let seasons: [Season]? = season.map { seasonNumber in
                    [Season(
                        number: seasonNumber,
                        episodes: episode.map { [Episode(number: $0)] }
                    )]
                }
                shows = [Show(ids: ids, seasons: seasons)]
            } else {
                movies = [Movie(ids: ids)]
                shows = nil
            }
        }
    }
}
