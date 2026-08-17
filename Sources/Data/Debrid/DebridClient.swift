import Foundation
import os

/// Result of asking a provider whether a torrent is already in its cache.
enum DebridCacheState: String, Hashable, Sendable {
    case checking, cached, notCached, unknown
}

struct DebridCacheResult: Hashable, Sendable {
    var provider: DebridProvider
    var state: DebridCacheState
    var fileName: String?
    var fileSize: Int64?
}

enum DebridError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case transport(String)
    case noPlayableFile
    case notCached

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No debrid provider is configured."
        case .http(let code, let detail): return "Debrid error \(code) — \(detail)"
        case .transport(let detail): return detail
        case .noPlayableFile: return "The torrent contains no playable video file."
        case .notCached: return "This torrent is not in your debrid cache yet."
        }
    }
}

/// Turns torrent sources into direct HTTP links via Real-Debrid, Premiumize or TorBox, and
/// answers instant-availability queries for the providers that still expose one.
actor DebridClient {
    static let shared = DebridClient()

    private let session: URLSession
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "Debrid")

    /// Video extensions used to pick the right file out of a multi-file torrent.
    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "avi", "m4v", "mov", "ts", "m2ts", "wmv", "flv", "webm", "mpg", "mpeg"
    ]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 60
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Request helper

    private func request(
        _ url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: url) else { throw DebridError.transport("Malformed debrid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
                throw DebridError.http(http.statusCode, detail)
            }
            return data
        } catch let error as DebridError {
            throw error
        } catch {
            throw DebridError.transport(error.localizedDescription)
        }
    }

    private static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    // MARK: - Account validation

    /// Used by the settings screen to confirm a pasted key actually works.
    func validate(credential: DebridCredential) async -> Result<String, Error> {
        do {
            switch credential.provider {
            case .realDebrid:
                let data = try await request(
                    "https://api.real-debrid.com/rest/1.0/user",
                    headers: ["Authorization": "Bearer \(credential.apiKey)"]
                )
                let user = try JSONDecoder().decode(RealDebridUser.self, from: data)
                return .success("\(user.username) · \(user.type ?? "free")")

            case .premiumize:
                let data = try await request(
                    "https://www.premiumize.me/api/account/info?apikey=\(credential.apiKey)"
                )
                let info = try JSONDecoder().decode(PremiumizeAccount.self, from: data)
                guard info.status == "success" else { return .failure(DebridError.notConfigured) }
                return .success(info.customer_id.map { "Customer \($0)" } ?? "Connected")

            case .torbox:
                let data = try await request(
                    "https://api.torbox.app/v1/api/user/me",
                    headers: ["Authorization": "Bearer \(credential.apiKey)"]
                )
                let envelope = try JSONDecoder().decode(TorboxEnvelope<TorboxUser>.self, from: data)
                guard let user = envelope.data else { return .failure(DebridError.notConfigured) }
                return .success("\(user.email ?? "Connected") · plan \(user.plan ?? 0)")
            }
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Cache checking

    /// Batch instant-availability lookup. Real-Debrid retired its endpoint, so it reports
    /// `.unknown` rather than pretending to know.
    func checkCache(
        infoHashes: [String],
        credentials: [DebridCredential]
    ) async -> [String: DebridCacheResult] {
        guard !infoHashes.isEmpty, !credentials.isEmpty else { return [:] }
        var merged: [String: DebridCacheResult] = [:]

        for credential in credentials where credential.provider.supportsCacheCheck {
            let partial: [String: DebridCacheResult]
            switch credential.provider {
            case .premiumize:
                partial = await premiumizeCacheCheck(infoHashes, apiKey: credential.apiKey)
            case .torbox:
                partial = await torboxCacheCheck(infoHashes, apiKey: credential.apiKey)
            case .realDebrid:
                partial = [:]
            }
            // A hit from any provider wins — the resolver will pick a service that has it.
            for (hash, result) in partial where result.state == .cached || merged[hash] == nil {
                merged[hash] = result
            }
        }
        return merged
    }

    private func premiumizeCacheCheck(_ hashes: [String], apiKey: String) async -> [String: DebridCacheResult] {
        let items = hashes.map { ("items[]", $0) }
        guard let data = try? await request(
            "https://www.premiumize.me/api/cache/check?apikey=\(apiKey)",
            method: "POST",
            body: Self.formBody(items),
            contentType: "application/x-www-form-urlencoded"
        ), let decoded = try? JSONDecoder().decode(PremiumizeCacheCheck.self, from: data) else { return [:] }

        var results: [String: DebridCacheResult] = [:]
        for (index, hash) in hashes.enumerated() {
            let cached = decoded.response?.indices.contains(index) == true ? decoded.response![index] : false
            results[hash.lowercased()] = DebridCacheResult(
                provider: .premiumize,
                state: cached ? .cached : .notCached,
                fileName: decoded.filename?.indices.contains(index) == true ? decoded.filename![index] : nil,
                fileSize: decoded.filesize?.indices.contains(index) == true
                    ? decoded.filesize![index].flatMap { Int64($0) } : nil
            )
        }
        return results
    }

    private func torboxCacheCheck(_ hashes: [String], apiKey: String) async -> [String: DebridCacheResult] {
        let payload = ["hashes": hashes]
        guard let body = try? JSONEncoder().encode(payload),
              let data = try? await request(
                  "https://api.torbox.app/v1/api/torrents/checkcached?format=object",
                  method: "POST",
                  headers: ["Authorization": "Bearer \(apiKey)"],
                  body: body,
                  contentType: "application/json"
              ),
              let decoded = try? JSONDecoder().decode(
                  TorboxEnvelope<[String: TorboxCachedItem]>.self, from: data
              ) else { return [:] }

        var results: [String: DebridCacheResult] = [:]
        for hash in hashes {
            let entry = decoded.data?[hash] ?? decoded.data?[hash.lowercased()]
            results[hash.lowercased()] = DebridCacheResult(
                provider: .torbox,
                state: entry != nil ? .cached : .notCached,
                fileName: entry?.name,
                fileSize: entry?.size
            )
        }
        return results
    }

    // MARK: - Link resolution

    /// Turns a magnet/infoHash into a direct HTTP URL, picking the file that best matches
    /// `preferredFileName` (or the largest video when there is no hint).
    func resolvePlayableLink(
        infoHash: String,
        magnetURI: String?,
        fileIndex: Int?,
        preferredFileName: String?,
        credential: DebridCredential
    ) async throws -> String {
        let magnet = magnetURI ?? "magnet:?xt=urn:btih:\(infoHash)"
        switch credential.provider {
        case .realDebrid:
            return try await resolveRealDebrid(
                magnet: magnet, fileIndex: fileIndex,
                preferredFileName: preferredFileName, apiKey: credential.apiKey
            )
        case .premiumize:
            return try await resolvePremiumize(
                magnet: magnet, preferredFileName: preferredFileName, apiKey: credential.apiKey
            )
        case .torbox:
            return try await resolveTorbox(
                magnet: magnet, preferredFileName: preferredFileName, apiKey: credential.apiKey
            )
        }
    }

    private func resolveRealDebrid(
        magnet: String, fileIndex: Int?, preferredFileName: String?, apiKey: String
    ) async throws -> String {
        let auth = ["Authorization": "Bearer \(apiKey)"]
        let base = "https://api.real-debrid.com/rest/1.0"

        let addData = try await request(
            "\(base)/torrents/addMagnet", method: "POST", headers: auth,
            body: Self.formBody([("magnet", magnet)]),
            contentType: "application/x-www-form-urlencoded"
        )
        let added = try JSONDecoder().decode(RealDebridAddTorrent.self, from: addData)
        let torrentId = added.id

        // Torrent has to be inspected before files can be selected.
        var info = try await realDebridInfo(id: torrentId, auth: auth, base: base)
        let selection = pickFile(
            names: info.files?.map(\.path) ?? [],
            sizes: info.files?.map(\.bytes) ?? [],
            fileIndex: fileIndex,
            preferredFileName: preferredFileName
        )
        guard let selection, let files = info.files else {
            _ = try? await request("\(base)/torrents/delete/\(torrentId)", method: "DELETE", headers: auth)
            throw DebridError.noPlayableFile
        }

        _ = try await request(
            "\(base)/torrents/selectFiles/\(torrentId)", method: "POST", headers: auth,
            body: Self.formBody([("files", String(files[selection].id))]),
            contentType: "application/x-www-form-urlencoded"
        )

        // Cached torrents flip to `downloaded` almost immediately; anything slower is not cached.
        for attempt in 0..<12 {
            info = try await realDebridInfo(id: torrentId, auth: auth, base: base)
            if info.status == "downloaded", let link = info.links?.first {
                let unrestricted = try await request(
                    "\(base)/unrestrict/link", method: "POST", headers: auth,
                    body: Self.formBody([("link", link)]),
                    contentType: "application/x-www-form-urlencoded"
                )
                let resolved = try JSONDecoder().decode(RealDebridUnrestrict.self, from: unrestricted)
                return resolved.download
            }
            if ["magnet_error", "error", "virus", "dead"].contains(info.status ?? "") { break }
            try? await Task.sleep(for: .milliseconds(attempt < 4 ? 400 : 1_000))
        }

        _ = try? await request("\(base)/torrents/delete/\(torrentId)", method: "DELETE", headers: auth)
        throw DebridError.notCached
    }

    private func realDebridInfo(id: String, auth: [String: String], base: String) async throws -> RealDebridTorrentInfo {
        let data = try await request("\(base)/torrents/info/\(id)", headers: auth)
        return try JSONDecoder().decode(RealDebridTorrentInfo.self, from: data)
    }

    private func resolvePremiumize(
        magnet: String, preferredFileName: String?, apiKey: String
    ) async throws -> String {
        let data = try await request(
            "https://www.premiumize.me/api/transfer/directdl?apikey=\(apiKey)",
            method: "POST",
            body: Self.formBody([("src", magnet)]),
            contentType: "application/x-www-form-urlencoded"
        )
        let result = try JSONDecoder().decode(PremiumizeDirectDownload.self, from: data)
        guard result.status == "success", let content = result.content, !content.isEmpty else {
            throw DebridError.notCached
        }
        let selection = pickFile(
            names: content.map { $0.path ?? "" },
            sizes: content.map { $0.size ?? 0 },
            fileIndex: nil,
            preferredFileName: preferredFileName
        )
        guard let selection, let link = content[selection].link else { throw DebridError.noPlayableFile }
        return link
    }

    private func resolveTorbox(
        magnet: String, preferredFileName: String?, apiKey: String
    ) async throws -> String {
        let auth = ["Authorization": "Bearer \(apiKey)"]
        let boundary = "nuvio-\(UUID().uuidString)"

        var body = Data()
        for (name, value) in [("magnet", magnet), ("add_only_if_cached", "true"), ("allow_zip", "false")] {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let createData = try await request(
            "https://api.torbox.app/v1/api/torrents/createtorrent",
            method: "POST", headers: auth, body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        let created = try JSONDecoder().decode(TorboxEnvelope<TorboxCreateTorrent>.self, from: createData)
        guard let torrentId = created.data?.torrent_id else { throw DebridError.notCached }

        let listData = try await request(
            "https://api.torbox.app/v1/api/torrents/mylist?id=\(torrentId)&bypass_cache=true",
            headers: auth
        )
        let torrent = try JSONDecoder().decode(TorboxEnvelope<TorboxTorrentData>.self, from: listData)
        guard let files = torrent.data?.files, !files.isEmpty else { throw DebridError.noPlayableFile }

        let selection = pickFile(
            names: files.map { $0.short_name ?? $0.name ?? "" },
            sizes: files.map { $0.size ?? 0 },
            fileIndex: nil,
            preferredFileName: preferredFileName
        )
        guard let selection, let fileId = files[selection].id else { throw DebridError.noPlayableFile }

        let linkData = try await request(
            "https://api.torbox.app/v1/api/torrents/requestdl?token=\(apiKey)&torrent_id=\(torrentId)&file_id=\(fileId)&redirect=false",
            headers: auth
        )
        let link = try JSONDecoder().decode(TorboxEnvelope<String>.self, from: linkData)
        guard let url = link.data else { throw DebridError.noPlayableFile }
        return url
    }

    // MARK: - File selection

    /// Picks the index of the file to play: an explicit index when the addon gave one, else the
    /// closest filename match, else the largest video file.
    private func pickFile(
        names: [String],
        sizes: [Int64],
        fileIndex: Int?,
        preferredFileName: String?
    ) -> Int? {
        guard !names.isEmpty else { return nil }

        let videoIndices = names.indices.filter { index in
            let ext = (names[index] as NSString).pathExtension.lowercased()
            return Self.videoExtensions.contains(ext)
        }
        let candidates = videoIndices.isEmpty ? Array(names.indices) : videoIndices

        if let fileIndex, candidates.contains(fileIndex) { return fileIndex }

        if let preferredFileName, !preferredFileName.isEmpty {
            let needle = (preferredFileName as NSString).lastPathComponent.lowercased()
            if let exact = candidates.first(where: {
                (names[$0] as NSString).lastPathComponent.lowercased() == needle
            }) { return exact }
        }

        return candidates.max { lhs, rhs in
            (sizes.indices.contains(lhs) ? sizes[lhs] : 0) < (sizes.indices.contains(rhs) ? sizes[rhs] : 0)
        }
    }
}

// MARK: - Wire types

private struct RealDebridUser: Decodable {
    let username: String
    let type: String?
}

private struct RealDebridAddTorrent: Decodable {
    let id: String
}

private struct RealDebridTorrentFile: Decodable {
    let id: Int
    let path: String
    let bytes: Int64
}

private struct RealDebridTorrentInfo: Decodable {
    let status: String?
    let files: [RealDebridTorrentFile]?
    let links: [String]?
}

private struct RealDebridUnrestrict: Decodable {
    let download: String
}

private struct PremiumizeAccount: Decodable {
    let status: String?
    let customer_id: Int?
}

private struct PremiumizeCacheCheck: Decodable {
    let status: String?
    let response: [Bool]?
    let filename: [String?]?
    let filesize: [String?]?
}

private struct PremiumizeDirectDownloadItem: Decodable {
    let path: String?
    let size: Int64?
    let link: String?
}

private struct PremiumizeDirectDownload: Decodable {
    let status: String?
    let content: [PremiumizeDirectDownloadItem]?
}

private struct TorboxEnvelope<T: Decodable>: Decodable {
    let success: Bool?
    let detail: String?
    let data: T?
}

private struct TorboxUser: Decodable {
    let email: String?
    let plan: Int?
}

private struct TorboxCachedItem: Decodable {
    let name: String?
    let size: Int64?
}

private struct TorboxCreateTorrent: Decodable {
    let torrent_id: Int?
}

private struct TorboxTorrentFile: Decodable {
    let id: Int?
    let name: String?
    let short_name: String?
    let size: Int64?
}

private struct TorboxTorrentData: Decodable {
    let files: [TorboxTorrentFile]?
}
