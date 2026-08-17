import Foundation
import os

// MARK: - Errors

enum StremioError: LocalizedError {
    case invalidURL(String)
    case http(Int, String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid addon URL: \(url)"
        case .http(let code, let url): return "HTTP \(code) — \(url)"
        case .decoding(let detail): return "Malformed addon response — \(detail)"
        case .transport(let detail): return detail
        }
    }
}

// MARK: - URL construction (port of the *RepositoryImpl url builders)

enum StremioURL {
    static let manifestSuffix = "/manifest.json"

    /// Port of `AddonRepositoryImpl.canonicalizeUrl` — strips a trailing `/manifest.json`
    /// from the path while preserving the query string configurable addons rely on.
    static func canonicalize(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingTrailingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let queryStart = trimmed.firstIndex(of: "?") else {
            return stripManifest(trimmed)
        }
        let path = String(trimmed[trimmed.startIndex..<queryStart])
        let query = String(trimmed[queryStart...])
        return stripManifest(path) + query
    }

    private static func stripManifest(_ path: String) -> String {
        var clean = path.trimmingTrailingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean.lowercased().hasSuffix(manifestSuffix) {
            clean = String(clean.dropLast(manifestSuffix.count))
                .trimmingTrailingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return clean
    }

    /// Splits a canonical base URL into `(path, query)` the way every builder below expects.
    private static func split(_ baseUrl: String) -> (path: String, query: String) {
        let trimmed = baseUrl.trimmingTrailingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let queryStart = trimmed.firstIndex(of: "?") else { return (trimmed, "") }
        let path = String(trimmed[trimmed.startIndex..<queryStart])
            .trimmingTrailingCharacters(in: CharacterSet(charactersIn: "/"))
        return (path, String(trimmed[queryStart...]))
    }

    static func manifest(baseUrl: String) -> String {
        let (path, query) = split(baseUrl)
        return "\(path)/manifest.json\(query)"
    }

    /// Strips the season/episode suffix off a video id to get the content id its meta lives under.
    ///
    ///     tt1234567:1:5  → tt1234567
    ///     mal:63375:1:5  → mal:63375
    ///     kitsu:12345:2  → kitsu:12345
    ///
    /// Prefixed ids keep two segments, IMDb-style and bare numeric ids keep one — otherwise
    /// `kitsu:12345` would be shortened to `kitsu`.
    static func metaId(forVideoId videoId: String) -> String {
        let parts = videoId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return videoId }
        let trailingNumeric = parts.reversed().prefix { Int($0) != nil }.count
        let first = parts[0]
        let minimum = (first.hasPrefix("tt") || Int(first) != nil) ? 1 : 2
        let drop = min(trailingNumeric, max(0, parts.count - minimum))
        guard drop > 0 else { return videoId }
        return parts.dropLast(drop).joined(separator: ":")
    }

    /// Port of `CatalogRepositoryImpl.buildCatalogUrl`.
    static func catalog(
        baseUrl: String,
        type: String,
        catalogId: String,
        skip: Int = 0,
        extraArgs: [(String, String)] = []
    ) -> String {
        let (path, query) = split(baseUrl)
        let catalogPath: String
        if extraArgs.isEmpty {
            catalogPath = skip > 0
                ? "\(path)/catalog/\(type)/\(catalogId)/skip=\(skip).json"
                : "\(path)/catalog/\(type)/\(catalogId).json"
        } else {
            var args = extraArgs
            if skip > 0, !args.contains(where: { $0.0 == "skip" }) {
                args.append(("skip", String(skip)))
            }
            let encoded = args
                .map { "\(javaURLEncode($0.0))=\(javaURLEncode($0.1))" }
                .joined(separator: "&")
            catalogPath = "\(path)/catalog/\(type)/\(catalogId)/\(encoded).json"
        }
        return catalogPath + query
    }

    static func meta(baseUrl: String, type: String, id: String) -> String {
        let (path, query) = split(baseUrl)
        return "\(path)/meta/\(javaURLEncode(type))/\(javaURLEncode(id)).json\(query)"
    }

    static func stream(baseUrl: String, type: String, videoId: String) -> String {
        let (path, query) = split(baseUrl)
        return "\(path)/stream/\(javaURLEncode(type))/\(javaURLEncode(videoId)).json\(query)"
    }

    static func subtitles(
        baseUrl: String,
        type: String,
        videoId: String,
        extraArgs: [(String, String)] = []
    ) -> String {
        let (path, query) = split(baseUrl)
        let base = "\(path)/subtitles/\(javaURLEncode(type))/\(javaURLEncode(videoId))"
        guard !extraArgs.isEmpty else { return "\(base).json\(query)" }
        let encoded = extraArgs
            .map { "\(javaURLEncode($0.0))=\(javaURLEncode($0.1))" }
            .joined(separator: "&")
        return "\(base)/\(encoded).json\(query)"
    }

    /// Reproduces `URLEncoder.encode(value, "UTF-8").replace("+", "%20")`.
    static func javaURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ".-*_")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private extension String {
    func trimmingTrailingCharacters(in set: CharacterSet) -> String {
        var result = self
        while let last = result.unicodeScalars.last, set.contains(last) {
            result.removeLast()
        }
        return result
    }
}

// MARK: - Wire DTOs

struct AddonManifestDTO: Decodable {
    var id: String?
    var name: String?
    var version: String?
    var description: String?
    var logo: String?
    var background: String?
    var catalogs: [CatalogDescriptorDTO]?
    var resources: [AnyJSON]?
    var types: [String]?
    var idPrefixes: [String]?
    var behaviorHints: AddonBehaviorHintsDTO?
    var stremioAddonsConfig: StremioAddonsConfigDTO?
    var language: String?
    var configVersion: FlexibleInt64?
    var timestamp: FlexibleInt64?

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, logo, background, catalogs, resources
        case types, idPrefixes, behaviorHints, stremioAddonsConfig, language, configVersion
        case timestamp = "_timestamp"
    }
}

struct CatalogDescriptorDTO: Decodable {
    var type: String?
    var id: String?
    var name: String?
    var extra: [AnyJSON]?
    var pageSize: FlexibleInt?
    var showInHome: FlexibleBool?
    var extraSupported: [String]?
    var extraRequired: [String]?
}

struct AddonBehaviorHintsDTO: Decodable {
    var configurable: Bool?
    var configurationRequired: Bool?
    var newEpisodeNotifications: Bool?
}

struct StremioAddonsConfigDTO: Decodable {
    var issuer: String?
    var signature: String?
}

struct CatalogResponseDTO: Decodable {
    var metas: [Failable<MetaPreviewDTO>]?
}

struct MetaLinkDTO: Decodable {
    var name: String?
    var category: String?
    var url: String?
}

struct MetaTrailerDTO: Decodable {
    var source: String?
    var type: String?
    var name: String?
    var ytId: String?
    var lang: String?
}

struct MetaBehaviorHintsDTO: Decodable {
    var defaultVideoId: String?
    var hasScheduledVideos: Bool?
}

struct TrailerStreamDTO: Decodable {
    var ytId: String?
}

struct MetaPreviewDTO: Decodable {
    var id: String?
    var type: String?
    var name: String?
    var poster: String?
    var posterShape: String?
    var background: String?
    var logo: String?
    var description: String?
    var releaseInfo: String?
    var imdbRating: FlexibleScalar?
    var genres: [String]?
    var runtime: String?
    var status: String?
    var released: String?
    var country: String?
    var imdbId: String?
    var slug: String?
    var landscapePoster: String?
    var rawPosterUrl: String?
    @FlexibleStringArray var director: [String]
    @FlexibleStringArray var writer: [String]
    @FlexibleStringArray var writers: [String]
    var links: [MetaLinkDTO]?
    var trailers: [MetaTrailerDTO]?
    var behaviorHints: MetaBehaviorHintsDTO?
    var trailerStreams: [TrailerStreamDTO]?

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, description
        case releaseInfo, imdbRating, genres, runtime, status, released, country
        case slug, landscapePoster, director, writer, writers, links, trailers
        case behaviorHints, trailerStreams
        case imdbId = "imdb_id"
        case rawPosterUrl = "_rawPosterUrl"
    }
}

struct VideoDTO: Decodable {
    var id: String?
    var name: String?
    var title: String?
    var released: String?
    var thumbnail: String?
    var season: FlexibleInt?
    var episode: FlexibleInt?
    var number: FlexibleInt?
    var overview: String?
    var description: String?
    var runtime: String?
    var available: FlexibleBool?
    /// Some addons never implement `/stream` and instead attach the playable links straight to
    /// the video entry in their meta response. `fetchInlineStreams` is the fallback that reads
    /// them, matching `StreamRepositoryImpl.fetchInlineStreamsFromMeta`.
    var streams: [Failable<StreamDTO>]?
}

struct AppExtrasCastMemberDTO: Decodable {
    var name: String?
    var character: String?
    var photo: String?
    var tmdbId: Int?
}

struct AppExtrasDTO: Decodable {
    var cast: [AppExtrasCastMemberDTO]?
    var directors: [AppExtrasCastMemberDTO]?
    var writers: [AppExtrasCastMemberDTO]?
    var certification: String?
}

struct MetaDTO: Decodable {
    var id: String?
    var type: String?
    var name: String?
    var poster: String?
    var posterShape: String?
    var background: String?
    var logo: String?
    var landscapePoster: String?
    var description: String?
    var releaseInfo: String?
    var released: String?
    var status: String?
    var imdbRating: FlexibleScalar?
    var imdbId: String?
    var slug: String?
    var genres: [String]?
    var runtime: String?
    @FlexibleStringArray var director: [String]
    @FlexibleStringArray var writer: [String]
    @FlexibleStringArray var writers: [String]
    @FlexibleStringArray var cast: [String]
    var videos: [VideoDTO]?
    var country: String?
    var awards: String?
    var language: String?
    var links: [MetaLinkDTO]?
    var trailers: [MetaTrailerDTO]?
    var behaviorHints: MetaBehaviorHintsDTO?
    var trailerStreams: [TrailerStreamDTO]?
    var appExtras: AppExtrasDTO?

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, landscapePoster
        case description, releaseInfo, released, status, imdbRating, slug, genres
        case runtime, director, writer, writers, cast, videos, country, awards
        case language, links, trailers, behaviorHints, trailerStreams
        case imdbId = "imdb_id"
        case appExtras = "app_extras"
    }
}

struct MetaResponseDTO: Decodable {
    var meta: MetaDTO?
}

struct ProxyHeadersDTO: Decodable {
    var request: [String: String]?
    var response: [String: String]?
}

struct StreamBehaviorHintsDTO: Decodable {
    var notWebReady: Bool?
    var bingeGroup: String?
    var countryWhitelist: [String]?
    var proxyHeaders: ProxyHeadersDTO?
    var videoHash: String?
    var videoSize: FlexibleInt64?
    var filename: String?
}

struct StreamDTO: Decodable {
    var name: String?
    var title: String?
    var description: String?
    var url: String?
    var ytId: String?
    var infoHash: String?
    var fileIdx: FlexibleInt?
    var externalUrl: String?
    var sources: [String]?
    var behaviorHints: StreamBehaviorHintsDTO?
}

struct StreamResponseDTO: Decodable {
    var streams: [Failable<StreamDTO>]?
}

struct SubtitleDTO: Decodable {
    var id: String?
    var url: String?
    var lang: String?
}

struct SubtitleResponseDTO: Decodable {
    var subtitles: [Failable<SubtitleDTO>]?
}

// MARK: - Client

actor StremioClient {
    static let shared = StremioClient()

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "StremioClient")

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 45
            config.requestCachePolicy = .useProtocolCachePolicy
            config.urlCache = URLCache(
                memoryCapacity: 16 * 1024 * 1024,
                diskCapacity: 128 * 1024 * 1024,
                diskPath: "nuvio-stremio"
            )
            config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
            self.session = URLSession(configuration: config)
        }
    }

    static let userAgent = "Nuvio/1.0 (tvOS) StremioAddonClient"

    /// `DecodingError.localizedDescription` drops the coding path, which is the only useful
    /// part when an addon returns an unexpected shape.
    private static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(let type, let context):
            return "type mismatch, expected \(type) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "null value for \(type) at \(path(context))"
        case .dataCorrupted(let context):
            return "corrupted data at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    private func get<T: Decodable>(_ urlString: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: urlString) else { throw StremioError.invalidURL(urlString) }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw StremioError.http(http.statusCode, urlString)
            }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                let detail = Self.describe(error)
                log.error("Decode failed for \(urlString, privacy: .public): \(detail, privacy: .public)")
                throw StremioError.decoding(detail)
            }
        } catch let error as StremioError {
            throw error
        } catch {
            throw StremioError.transport(error.localizedDescription)
        }
    }

    // MARK: Manifest

    func fetchManifest(rawUrl: String) async throws -> Addon {
        let base = StremioURL.canonicalize(rawUrl)
        let dto = try await get(StremioURL.manifest(baseUrl: base), as: AddonManifestDTO.self)
        return StremioMapper.addon(from: dto, baseUrl: base)
    }

    // MARK: Catalog

    func fetchCatalog(
        addon: Addon,
        type: String,
        catalogId: String,
        skip: Int = 0,
        extraArgs: [(String, String)] = []
    ) async throws -> [MetaPreview] {
        let url = StremioURL.catalog(
            baseUrl: addon.baseUrl, type: type, catalogId: catalogId,
            skip: skip, extraArgs: extraArgs
        )
        let dto = try await get(url, as: CatalogResponseDTO.self)
        return (dto.metas ?? []).compacted().compactMap {
            StremioMapper.preview(from: $0, addonBaseUrl: addon.baseUrl)
        }
    }

    // MARK: Meta

    func fetchMeta(addon: Addon, type: String, id: String) async throws -> Meta? {
        let url = StremioURL.meta(baseUrl: addon.baseUrl, type: type, id: id)
        let dto = try await get(url, as: MetaResponseDTO.self)
        guard let meta = dto.meta else { return nil }
        return StremioMapper.meta(from: meta)
    }

    // MARK: Streams

    func fetchStreams(addon: Addon, type: String, videoId: String) async throws -> [Stream] {
        let url = StremioURL.stream(baseUrl: addon.baseUrl, type: type, videoId: videoId)
        let dto = try await get(url, as: StreamResponseDTO.self)
        var seen: [String: Int] = [:]
        return (dto.streams ?? []).compacted().compactMap { item -> Stream? in
            var stream = StremioMapper.stream(
                from: item,
                addonName: addon.displayName,
                addonLogo: addon.logo
            )
            let key = stream.stableKey
            let count = seen[key, default: 0]
            seen[key] = count + 1
            stream.occurrence = count
            return stream
        }
    }

    /// Fallback for addons whose `/stream` endpoint answers empty: their playable links live on
    /// the matching video inside `/meta`. Port of `fetchInlineStreamsFromMeta`.
    func fetchInlineStreams(addon: Addon, type: String, videoId: String) async throws -> [Stream] {
        let url = StremioURL.meta(
            baseUrl: addon.baseUrl, type: type, id: StremioURL.metaId(forVideoId: videoId)
        )
        let dto = try await get(url, as: MetaResponseDTO.self)
        guard let videos = dto.meta?.videos else { return [] }
        // Only the requested video's streams — a series meta carries every episode's.
        guard let match = videos.first(where: { $0.id == videoId }) else { return [] }
        var seen: [String: Int] = [:]
        return (match.streams ?? []).compacted().compactMap { item -> Stream? in
            var stream = StremioMapper.stream(
                from: item,
                addonName: addon.displayName,
                addonLogo: addon.logo
            )
            let key = stream.stableKey
            let count = seen[key, default: 0]
            seen[key] = count + 1
            stream.occurrence = count
            return stream
        }
    }

    // MARK: Subtitles

    func fetchSubtitles(
        addon: Addon,
        type: String,
        videoId: String,
        extraArgs: [(String, String)] = []
    ) async throws -> [Subtitle] {
        let url = StremioURL.subtitles(
            baseUrl: addon.baseUrl, type: type, videoId: videoId, extraArgs: extraArgs
        )
        let dto = try await get(url, as: SubtitleResponseDTO.self)
        return (dto.subtitles ?? []).compacted().compactMap { item -> Subtitle? in
            guard let url = item.url?.nilIfBlank else { return nil }
            return Subtitle(
                id: item.id ?? url,
                url: url,
                lang: item.lang ?? "unknown",
                addonName: addon.displayName
            )
        }
    }
}

// MARK: - Mapping

enum StremioMapper {
    static func addon(from dto: AddonManifestDTO, baseUrl: String) -> Addon {
        let rawTypes = dto.types ?? []
        let types = rawTypes.map { ContentType.from($0) }
        let resources = parseResources(dto.resources ?? [], fallbackTypes: rawTypes, idPrefixes: dto.idPrefixes)
        let catalogs = (dto.catalogs ?? []).compactMap { catalog(from: $0) }
        let name = dto.name?.nilIfBlank ?? "Addon"

        return Addon(
            id: dto.id?.nilIfBlank ?? baseUrl,
            name: name,
            displayName: name,
            version: dto.version ?? "0.0.0",
            description: dto.description,
            logo: dto.logo,
            background: dto.background,
            baseUrl: baseUrl,
            catalogs: catalogs,
            types: types,
            rawTypes: rawTypes,
            resources: resources,
            idPrefixes: dto.idPrefixes ?? [],
            behaviorHints: dto.behaviorHints.map {
                AddonBehaviorHints(
                    configurable: $0.configurable,
                    configurationRequired: $0.configurationRequired,
                    newEpisodeNotifications: $0.newEpisodeNotifications
                )
            },
            stremioAddonsConfig: dto.stremioAddonsConfig.map {
                StremioAddonsConfig(issuer: $0.issuer, signature: $0.signature)
            },
            manifestLanguage: dto.language,
            configVersion: dto.configVersion?.value,
            timestamp: dto.timestamp?.value
        )
    }

    /// `resources` is either `["catalog", "meta"]` or a list of full objects.
    private static func parseResources(
        _ raw: [AnyJSON],
        fallbackTypes: [String],
        idPrefixes: [String]?
    ) -> [AddonResource] {
        raw.compactMap { entry in
            if let name = entry.stringValue, entry.objectValue == nil {
                return AddonResource(name: name, types: fallbackTypes, idPrefixes: idPrefixes)
            }
            guard let object = entry.objectValue,
                  let name = object["name"]?.stringValue else { return nil }
            let types = object["types"]?.arrayValue?.compactMap(\.stringValue) ?? fallbackTypes
            let prefixes = object["idPrefixes"]?.arrayValue?.compactMap(\.stringValue) ?? idPrefixes
            return AddonResource(name: name, types: types, idPrefixes: prefixes)
        }
    }

    static func catalog(from dto: CatalogDescriptorDTO) -> CatalogDescriptor? {
        guard let rawType = dto.type?.nilIfBlank, let id = dto.id?.nilIfBlank else { return nil }
        let extras = parseExtras(dto.extra ?? [])
        let explicitShowInHome = dto.showInHome?.value
        return CatalogDescriptor(
            type: ContentType.from(rawType),
            rawType: rawType,
            id: id,
            name: dto.name?.nilIfBlank ?? id.capitalized,
            extra: extras,
            pageSize: dto.pageSize?.value,
            showInHome: explicitShowInHome ?? true,
            hasExplicitShowInHome: explicitShowInHome != nil,
            extraSupported: dto.extraSupported ?? extras.map(\.name),
            extraRequired: dto.extraRequired ?? extras.filter(\.isRequired).map(\.name)
        )
    }

    /// `extra` is either `[{name, options, isRequired}]` or a bare `["search", "skip"]`.
    private static func parseExtras(_ raw: [AnyJSON]) -> [CatalogExtra] {
        raw.compactMap { entry in
            if let name = entry.stringValue, entry.objectValue == nil {
                return CatalogExtra(name: name)
            }
            guard let object = entry.objectValue,
                  let name = object["name"]?.stringValue else { return nil }
            return CatalogExtra(
                name: name,
                isRequired: object["isRequired"]?.boolValue ?? false,
                options: object["options"]?.arrayValue?.compactMap(\.stringValue),
                defaultValue: object["default"]?.stringValue,
                optionsLimit: object["optionsLimit"]?.intValue
            )
        }
    }

    static func preview(from dto: MetaPreviewDTO, addonBaseUrl: String?) -> MetaPreview? {
        guard let id = dto.id?.nilIfBlank, let name = dto.name?.nilIfBlank else { return nil }
        let rawType = dto.type?.nilIfBlank ?? "movie"
        let writers = dto.writer.isEmpty ? dto.writers : dto.writer
        return MetaPreview(
            id: id,
            type: ContentType.from(rawType),
            rawType: rawType,
            name: name,
            poster: dto.poster?.nilIfBlank,
            posterShape: PosterShape.from(dto.posterShape),
            background: dto.background?.nilIfBlank,
            logo: dto.logo?.nilIfBlank,
            description: dto.description?.nilIfBlank,
            releaseInfo: dto.releaseInfo?.nilIfBlank,
            imdbRating: dto.imdbRating?.doubleValue.map { Float($0) },
            genres: dto.genres ?? [],
            runtime: dto.runtime?.nilIfBlank,
            status: dto.status?.nilIfBlank,
            language: nil,
            released: dto.released?.nilIfBlank,
            country: dto.country?.nilIfBlank,
            imdbId: dto.imdbId?.nilIfBlank,
            slug: dto.slug?.nilIfBlank,
            landscapePoster: dto.landscapePoster?.nilIfBlank,
            rawPosterUrl: dto.rawPosterUrl?.nilIfBlank,
            director: dto.director,
            writer: writers,
            links: (dto.links ?? []).compactMap(link),
            behaviorHints: dto.behaviorHints.map {
                MetaBehaviorHints(defaultVideoId: $0.defaultVideoId, hasScheduledVideos: $0.hasScheduledVideos)
            },
            trailers: (dto.trailers ?? []).map(trailer),
            trailerYtIds: ytIds(trailers: dto.trailers, streams: dto.trailerStreams),
            sourceAddonBaseUrl: addonBaseUrl
        )
    }

    static func meta(from dto: MetaDTO) -> Meta? {
        guard let id = dto.id?.nilIfBlank, let name = dto.name?.nilIfBlank else { return nil }
        let rawType = dto.type?.nilIfBlank ?? "movie"
        let writers = dto.writer.isEmpty ? dto.writers : dto.writer
        let extras = dto.appExtras

        var castMembers: [MetaCastMember] = (extras?.cast ?? []).compactMap {
            guard let name = $0.name?.nilIfBlank else { return nil }
            return MetaCastMember(name: name, character: $0.character, photo: $0.photo, tmdbId: $0.tmdbId)
        }
        if castMembers.isEmpty {
            castMembers = dto.cast.map { MetaCastMember(name: $0) }
        }

        return Meta(
            id: id,
            type: ContentType.from(rawType),
            rawType: rawType,
            name: name,
            poster: dto.poster?.nilIfBlank,
            posterShape: PosterShape.from(dto.posterShape),
            background: dto.background?.nilIfBlank,
            logo: dto.logo?.nilIfBlank,
            description: dto.description?.nilIfBlank,
            releaseInfo: dto.releaseInfo?.nilIfBlank,
            status: dto.status?.nilIfBlank,
            imdbRating: dto.imdbRating?.doubleValue.map { Float($0) },
            genres: dto.genres ?? [],
            runtime: dto.runtime?.nilIfBlank,
            director: dto.director,
            writer: writers,
            cast: dto.cast,
            castMembers: castMembers,
            videos: (dto.videos ?? []).compactMap(video),
            ageRating: extras?.certification?.nilIfBlank,
            country: dto.country?.nilIfBlank,
            awards: dto.awards?.nilIfBlank,
            language: dto.language?.nilIfBlank,
            links: (dto.links ?? []).compactMap(link),
            trailerYtIds: ytIds(trailers: dto.trailers, streams: dto.trailerStreams),
            imdbId: dto.imdbId?.nilIfBlank,
            slug: dto.slug?.nilIfBlank,
            released: dto.released?.nilIfBlank,
            landscapePoster: dto.landscapePoster?.nilIfBlank,
            behaviorHints: dto.behaviorHints.map {
                MetaBehaviorHints(defaultVideoId: $0.defaultVideoId, hasScheduledVideos: $0.hasScheduledVideos)
            },
            trailers: (dto.trailers ?? []).map(trailer)
        )
    }

    static func video(from dto: VideoDTO) -> Video? {
        guard let id = dto.id?.nilIfBlank else { return nil }
        return Video(
            id: id,
            name: dto.name?.nilIfBlank,
            title: dto.title?.nilIfBlank,
            released: dto.released?.nilIfBlank,
            thumbnail: dto.thumbnail?.nilIfBlank,
            season: dto.season?.value,
            episode: dto.episode?.value ?? dto.number?.value,
            number: dto.number?.value,
            overview: dto.overview?.nilIfBlank,
            description: dto.description?.nilIfBlank,
            runtime: dto.runtime?.nilIfBlank,
            available: dto.available?.value
        )
    }

    static func stream(from dto: StreamDTO, addonName: String, addonLogo: String?) -> Stream {
        let hints = dto.behaviorHints.map {
            StreamBehaviorHints(
                notWebReady: $0.notWebReady,
                bingeGroup: $0.bingeGroup,
                countryWhitelist: $0.countryWhitelist,
                proxyHeaders: $0.proxyHeaders.map {
                    ProxyHeaders(request: $0.request, response: $0.response)
                },
                videoHash: $0.videoHash,
                videoSize: $0.videoSize?.value,
                filename: $0.filename
            )
        }
        let searchText = [dto.name, dto.title, dto.description, hints?.filename]
            .compactMap { $0 }
            .joined(separator: " ")
        let quality = QualityParser.parse(searchText)

        return Stream(
            name: dto.name?.nilIfBlank,
            title: dto.title?.nilIfBlank,
            description: dto.description?.nilIfBlank,
            url: dto.url?.nilIfBlank,
            ytId: dto.ytId?.nilIfBlank,
            infoHash: dto.infoHash?.nilIfBlank,
            fileIdx: dto.fileIdx?.value,
            externalUrl: dto.externalUrl?.nilIfBlank,
            behaviorHints: hints,
            addonName: addonName,
            addonLogo: addonLogo,
            sources: dto.sources,
            quality: quality.label,
            qualityValue: quality.value
        )
    }

    private static func link(from dto: MetaLinkDTO) -> MetaLink? {
        guard let name = dto.name?.nilIfBlank, let category = dto.category?.nilIfBlank else { return nil }
        return MetaLink(name: name, category: category, url: dto.url?.nilIfBlank)
    }

    private static func trailer(from dto: MetaTrailerDTO) -> MetaTrailer {
        MetaTrailer(source: dto.source, type: dto.type, name: dto.name, ytId: dto.ytId, lang: dto.lang)
    }

    private static func ytIds(trailers: [MetaTrailerDTO]?, streams: [TrailerStreamDTO]?) -> [String] {
        var ids: [String] = []
        for trailer in trailers ?? [] {
            if let id = trailer.ytId?.nilIfBlank ?? trailer.source?.nilIfBlank, !ids.contains(id) {
                ids.append(id)
            }
        }
        for stream in streams ?? [] {
            if let id = stream.ytId?.nilIfBlank, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }
}

// MARK: - Quality parsing

enum QualityParser {
    /// Ordered so the first match wins, matching the ranking the Android stream list uses.
    private static let ladder: [(pattern: String, label: String, value: Int)] = [
        ("2160p", "4K", 2160), ("4k", "4K", 2160), ("uhd", "4K", 2160),
        ("1440p", "1440p", 1440),
        ("1080p", "1080p", 1080), ("fullhd", "1080p", 1080), ("fhd", "1080p", 1080),
        ("720p", "720p", 720), ("hd", "720p", 720),
        ("480p", "480p", 480), ("sd", "480p", 480),
        ("360p", "360p", 360),
        ("240p", "240p", 240)
    ]

    static func parse(_ text: String) -> (label: String?, value: Int) {
        let haystack = text.lowercased()
        for entry in ladder where haystack.contains(entry.pattern) {
            return (entry.label, entry.value)
        }
        return (nil, -1)
    }

    /// Extra descriptors surfaced as chips on the stream rows.
    static func tags(_ text: String) -> [String] {
        let haystack = text.lowercased()
        var tags: [String] = []
        let checks: [(String, String)] = [
            ("dolby vision", "DV"), ("dovi", "DV"), ("hdr10+", "HDR10+"), ("hdr", "HDR"),
            ("atmos", "ATMOS"), ("truehd", "TrueHD"), ("dts-hd", "DTS-HD"), ("dts", "DTS"),
            ("remux", "REMUX"), ("bluray", "BluRay"), ("blu-ray", "BluRay"),
            ("web-dl", "WEB-DL"), ("webdl", "WEB-DL"), ("webrip", "WEBRip"),
            ("hdtv", "HDTV"), ("cam", "CAM"), ("x265", "x265"), ("hevc", "HEVC"),
            ("x264", "x264"), ("av1", "AV1"), ("10bit", "10bit")
        ]
        for (needle, tag) in checks where haystack.contains(needle) {
            if !tags.contains(tag) { tags.append(tag) }
        }
        return tags
    }

    /// Pulls a human-readable size out of the stream title, e.g. "💾 4.31 GB".
    static func size(_ text: String) -> String? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s?(GB|MB|GiB|MiB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range]).uppercased()
    }

    /// Seeder count, surfaced by most torrent addons as "👤 42".
    static func seeders(_ text: String) -> Int? {
        let pattern = #"(?:👤|seeders?|seeds?)[\s:]*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}
