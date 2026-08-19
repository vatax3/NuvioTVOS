import Foundation

// MARK: - Models

/// Files already stored at a debrid provider. Kept distinct from Stremio streams because a
/// cloud item can contain several playable files and its URL is obtained only when selected.
enum CloudLibraryItemType: String, CaseIterable, Hashable, Sendable {
    case torrent, usenet, webDownload, file

    var label: String {
        switch self {
        case .torrent: return "Torrents"
        case .usenet: return "Usenet"
        case .webDownload: return "Downloads"
        case .file: return "Files"
        }
    }
}

struct CloudLibraryFile: Hashable, Identifiable, Sendable {
    var id: String?
    var name: String
    var sizeBytes: Int64?
    var mimeType: String?
    var isPlayable: Bool
    /// Premiumize returns this eagerly for many files; TorBox gives it on demand.
    var playbackURL: String?

    var stableKey: String { id ?? name }
    var identifier: String { stableKey }
}

struct CloudLibraryItem: Hashable, Identifiable, Sendable {
    var provider: DebridProvider
    var id: String
    var type: CloudLibraryItemType
    var name: String
    var status: String?
    var sizeBytes: Int64?
    var progressFraction: Double?
    var files: [CloudLibraryFile]

    var stableKey: String { "\(provider.rawValue):\(type.rawValue):\(id)" }
    var playableFiles: [CloudLibraryFile] { files.filter(\.isPlayable) }
}

struct CloudLibraryProviderState: Identifiable, Sendable {
    var provider: DebridProvider
    var items: [CloudLibraryItem] = []
    var errorMessage: String?

    var id: String { provider.rawValue }
}

struct CloudLibraryConfiguration: Sendable {
    var isEnabled: Bool
    var credentials: [DebridCredential]
}

enum CloudLibraryError: LocalizedError {
    case disabled
    case missingCredentials
    case notPlayable
    case malformedResponse
    case service(String)

    var errorDescription: String? {
        switch self {
        case .disabled: return "Cloud library is disabled in Debrid settings."
        case .missingCredentials: return "The connected debrid account is no longer configured."
        case .notPlayable: return "This file is not a supported video file."
        case .malformedResponse: return "The debrid service returned an unreadable response."
        case .service(let message): return message
        }
    }
}

// MARK: - Provider client

/// tvOS counterpart of Android's `CloudLibraryRepository`. No secrets are retained here: the
/// settings snapshot is passed in for each refresh / resolution and the settings store keeps
/// keys in Keychain.
actor CloudLibraryClient {
    static let shared = CloudLibraryClient()

    private let session: URLSession
    private static let playableExtensions: Set<String> = [
        "3g2", "3gp", "avi", "divx", "flv", "m2ts", "m4v", "mkv", "mov", "mp4",
        "mpeg", "mpg", "mts", "ogm", "ogv", "ts", "webm", "wmv"
    ]

    init(session: URLSession = .shared) { self.session = session }

    func refresh(configuration: CloudLibraryConfiguration) async -> [CloudLibraryProviderState] {
        guard configuration.isEnabled else { return [] }
        let credentials = configuration.credentials.filter { $0.provider.supportsCloudLibrary }
        var states: [CloudLibraryProviderState] = []
        for credential in credentials {
            do {
                states.append(CloudLibraryProviderState(
                    provider: credential.provider,
                    items: try await listItems(credential: credential)
                ))
            } catch {
                states.append(CloudLibraryProviderState(
                    provider: credential.provider,
                    errorMessage: error.localizedDescription
                ))
            }
        }
        return states
    }

    func resolvePlayback(
        item: CloudLibraryItem,
        file: CloudLibraryFile,
        configuration: CloudLibraryConfiguration
    ) async throws -> String {
        guard configuration.isEnabled else { throw CloudLibraryError.disabled }
        guard file.isPlayable else { throw CloudLibraryError.notPlayable }
        guard let credential = configuration.credentials.first(where: { $0.provider == item.provider }) else {
            throw CloudLibraryError.missingCredentials
        }

        switch item.provider {
        case .premiumize:
            if let url = file.playbackURL?.nilIfBlank { return url }
            guard let fileId = file.id?.nilIfBlank else { throw CloudLibraryError.malformedResponse }
            let response: PremiumizeDetailDTO = try await request(
                "https://www.premiumize.me/api/item/details?id=\(fileId.urlQueryEscaped)",
                headers: ["Authorization": "Bearer \(credential.apiKey)"]
            )
            guard response.status?.lowercased() != "error", let link = response.link?.nilIfBlank else {
                throw CloudLibraryError.service(response.message ?? response.code ?? "Premiumize could not resolve this file.")
            }
            return link

        case .torbox:
            let endpoint: String
            let idName: String
            switch item.type {
            case .torrent: endpoint = "torrents/requestdl"; idName = "torrent_id"
            case .usenet: endpoint = "usenet/requestdl"; idName = "usenet_id"
            case .webDownload: endpoint = "webdl/requestdl"; idName = "web_id"
            case .file: throw CloudLibraryError.notPlayable
            }
            var components = URLComponents(string: "https://api.torbox.app/v1/api/\(endpoint)")!
            components.queryItems = [
                URLQueryItem(name: "token", value: credential.apiKey),
                URLQueryItem(name: idName, value: item.id),
                URLQueryItem(name: "file_id", value: file.id),
                URLQueryItem(name: "redirect", value: "false")
            ]
            guard let url = components.url else { throw CloudLibraryError.malformedResponse }
            let response: TorboxLinkEnvelope = try await request(
                url.absoluteString, headers: ["Authorization": "Bearer \(credential.apiKey)"]
            )
            guard response.success != false, let link = response.data?.nilIfBlank else {
                throw CloudLibraryError.service(response.detail ?? response.error ?? "TorBox could not resolve this file.")
            }
            return link

        case .realDebrid:
            throw CloudLibraryError.missingCredentials
        }
    }

    private func listItems(credential: DebridCredential) async throws -> [CloudLibraryItem] {
        switch credential.provider {
        case .premiumize:
            let response: PremiumizeItemsDTO = try await request(
                "https://www.premiumize.me/api/item/listall",
                headers: ["Authorization": "Bearer \(credential.apiKey)"]
            )
            guard response.status?.lowercased() != "error" else {
                throw CloudLibraryError.service(response.message ?? response.code ?? "Premiumize could not load the cloud library.")
            }
            return premiumizeItems(from: response.files ?? [])

        case .torbox:
            let headers = ["Authorization": "Bearer \(credential.apiKey)"]
            async let torrents: TorboxItemsEnvelope = request("https://api.torbox.app/v1/api/torrents/mylist", headers: headers)
            async let usenet: TorboxItemsEnvelope = request("https://api.torbox.app/v1/api/usenet/mylist", headers: headers)
            async let downloads: TorboxItemsEnvelope = request("https://api.torbox.app/v1/api/webdl/mylist", headers: headers)
            return try await cloudItems(from: torrents, provider: .torbox, type: .torrent)
                + cloudItems(from: usenet, provider: .torbox, type: .usenet)
                + cloudItems(from: downloads, provider: .torbox, type: .webDownload)

        case .realDebrid:
            return []
        }
    }

    private func request<T: Decodable>(_ address: String, headers: [String: String]) async throws -> T {
        guard let url = URL(string: address) else { throw CloudLibraryError.malformedResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = String(data: data.prefix(240), encoding: .utf8) ?? ""
            throw CloudLibraryError.service("Service error \(http.statusCode)\(detail.isEmpty ? "" : ": \(detail)")")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CloudLibraryError.malformedResponse }
    }

    private func premiumizeItems(from files: [PremiumizeFileDTO]) -> [CloudLibraryItem] {
        struct Mapped { let group: String; let id: String; let name: String; let file: CloudLibraryFile }
        let mapped: [Mapped] = files.compactMap { dto in
            let path = dto.path?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).nilIfBlank
            guard let name = dto.name?.nilIfBlank ?? path?.pathBasename.nilIfBlank else { return nil }
            let segments = path?.split(separator: "/").map(String.init) ?? []
            let isRoot = segments.count <= 1
            let itemName = isRoot ? name : (segments.first ?? name)
            let itemID = isRoot ? "file:\(dto.id?.nilIfBlank ?? path ?? name)" : "folder:\(itemName)"
            let file = CloudLibraryFile(
                id: dto.id?.nilIfBlank, name: name, sizeBytes: dto.size, mimeType: dto.mimeType,
                isPlayable: isPlayable(name: name, mimeType: dto.mimeType), playbackURL: dto.link
            )
            return Mapped(group: itemID, id: itemID, name: itemName, file: file)
        }
        return Dictionary(grouping: mapped, by: \.group).values.compactMap { group in
            guard let first = group.first else { return nil }
            let files = group.map(\.file).sorted {
                $0.isPlayable != $1.isPlayable ? $0.isPlayable : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return CloudLibraryItem(
                provider: .premiumize, id: first.id, type: .file, name: first.name, status: "Ready",
                sizeBytes: files.compactMap(\.sizeBytes).reduce(0, +), files: files
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func cloudItems(
        from envelope: TorboxItemsEnvelope, provider: DebridProvider, type: CloudLibraryItemType
    ) throws -> [CloudLibraryItem] {
        guard envelope.success != false else {
            throw CloudLibraryError.service(envelope.detail ?? envelope.error ?? "TorBox could not load the cloud library.")
        }
        return (envelope.data ?? []).compactMap { dto in
            guard let id = dto.id?.stringValue ?? dto.hash?.nilIfBlank else { return nil }
            let name = dto.name?.nilIfBlank ?? id
            let files = (dto.files ?? []).compactMap { file -> CloudLibraryFile? in
                let fileName = [file.shortName, file.name?.pathBasename, file.absolutePath?.pathBasename]
                    .compactMap { $0?.nilIfBlank }.first
                guard let fileName else { return nil }
                let mimeType = file.mimeType?.nilIfBlank ?? file.mimeTypeAlt?.nilIfBlank
                return CloudLibraryFile(
                    id: file.id?.stringValue, name: fileName, sizeBytes: file.size, mimeType: mimeType,
                    isPlayable: file.id?.stringValue != nil && isPlayable(name: fileName, mimeType: mimeType)
                )
            }
            let size = dto.size ?? dto.totalSize ?? files.compactMap(\.sizeBytes).reduce(0, +)
            let progress = dto.progress ?? dto.downloadProgress
            return CloudLibraryItem(
                provider: provider, id: id, type: type, name: name,
                status: dto.status?.nilIfBlank ?? dto.downloadState?.nilIfBlank ?? dto.state?.nilIfBlank,
                sizeBytes: size > 0 ? size : nil,
                progressFraction: progress.map { min(1, max(0, $0 > 1 ? $0 / 100 : $0)) }, files: files
            )
        }
    }

    private func isPlayable(name: String, mimeType: String?) -> Bool {
        mimeType?.lowercased().hasPrefix("video/") == true
            || Self.playableExtensions.contains(name.split(separator: ".").last?.lowercased() ?? "")
    }
}

// MARK: - Provider DTOs

private struct PremiumizeItemsDTO: Decodable {
    let status: String?; let message: String?; let code: String?; let files: [PremiumizeFileDTO]?
}
private struct PremiumizeDetailDTO: Decodable {
    let status: String?; let message: String?; let code: String?; let link: String?
}
private struct PremiumizeFileDTO: Decodable {
    let id: String?; let name: String?; let path: String?; let size: Int64?; let mimeType: String?; let link: String?
    enum CodingKeys: String, CodingKey { case id, name, path, size, link; case mimeType = "mime_type" }
}
private struct TorboxItemsEnvelope: Decodable {
    let success: Bool?; let data: [TorboxCloudItemDTO]?; let error: String?; let detail: String?
}
private struct TorboxLinkEnvelope: Decodable {
    let success: Bool?; let data: String?; let error: String?; let detail: String?
}
private struct TorboxCloudItemDTO: Decodable {
    let id: FlexibleScalar?; let hash: String?; let name: String?; let status: String?; let state: String?
    let downloadState: String?; let progress: Double?; let downloadProgress: Double?; let size: Int64?; let totalSize: Int64?
    let files: [TorboxCloudFileDTO]?
    enum CodingKeys: String, CodingKey {
        case id, hash, name, status, state, progress, size, files
        case downloadState = "download_state"; case downloadProgress = "download_progress"; case totalSize = "total_size"
    }
}
private struct TorboxCloudFileDTO: Decodable {
    let id: FlexibleScalar?; let name: String?; let shortName: String?; let absolutePath: String?
    let mimeType: String?; let mimeTypeAlt: String?; let size: Int64?
    enum CodingKeys: String, CodingKey {
        case id, name, size; case shortName = "short_name"; case absolutePath = "absolute_path"
        case mimeType = "mimetype"; case mimeTypeAlt = "mime_type"
    }
}

private extension String {
    var pathBasename: String { split(separator: "/").last.map(String.init) ?? self }
    var urlQueryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
