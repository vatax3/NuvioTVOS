import Foundation
import os

/// MDBList as a third tracking account, alongside Trakt and Simkl.
///
/// Port of the `data/mdblist` package upstream added between 1.0.0 and 1.1.0-beta.2 — thirty-five
/// files and the largest single addition of that window. **Deliberately not a line-for-line port**,
/// and the part left out is the bulk of it: upstream holds a durable snapshot of watched rows,
/// resume points and list contents, and keeps it current by polling `/sync/last_activities` for a
/// watermark and replaying `/sync/journal` deltas against it, with a full resync when the journal
/// answers 409.
///
/// That machinery serves their cached-snapshot design. Ours fetches when a screen appears — the
/// decision recorded in the parity audit for Trakt and Simkl both — so there is no snapshot for a
/// journal to be applied to, and the delta engine would be bookkeeping for a cache we do not keep.
/// What is ported is everything a viewer can see: the account, the lists, the resume points, the
/// watched marks, the writes and the scrobble.
///
/// Authentication is OAuth **device authorization**, the same shape as Trakt's, with one
/// difference that matters: MDBList's client id is registered by the viewer rather than shipped,
/// so it lives in Settings next to the Trakt and Simkl ones. Upstream reads theirs from a build
/// secret, which is blank in public source — as with Premiumize, the viewer supplying their own is
/// the only version of this that can work here.
actor MDBListClient {
    static let shared = MDBListClient()
    private let base = "https://api.mdblist.com"
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "MDBList")

    /// Ratings only. One title's scores do not change between two screens of one session, and the
    /// ratings row is drawn on every detail screen and every focused poster.
    private var ratingsCache: [String: MDBListRatings] = [:]

    // MARK: - Wire shapes

    struct DeviceCode: Sendable {
        let deviceCode: String
        let userCode: String
        /// Where the viewer types the code. Shown on the television and encoded into the QR.
        let verificationURL: String
        /// The same page with the code already filled in, when MDBList supplies one.
        let verificationURLComplete: String
        let expiresIn: Int
        let interval: Int
    }

    struct Tokens: Sendable {
        let accessToken: String
        let refreshToken: String
        /// Seconds from issue. MDBList's access tokens expire, unlike Simkl's, so the refresh is
        /// not optional here.
        let expiresIn: Int
    }

    /// One of the viewer's own lists, plus the watchlist, which MDBList addresses separately.
    struct List: Sendable, Identifiable, Hashable {
        /// `nil` for the watchlist — it has no id because there is only one.
        let listId: Int?
        let name: String
        let isPrivate: Bool
        let mediaType: String?

        var id: String { listId.map { "mdblist:list:\($0)" } ?? Self.watchlistKey }
        static let watchlistKey = "mdblist:watchlist"
        var isWatchlist: Bool { listId == nil }

        /// The one list every account has, for writes that do not go through a list the viewer
        /// picked. Its name is only used where a name is drawn, and those paths read the fetched
        /// list rather than this.
        static let watchlist = List(listId: nil, name: "Watchlist", isPrivate: true, mediaType: nil)

        /// `/watchlist/items` or `/lists/{id}/items`.
        var itemsPath: String {
            listId.map { "/lists/\($0)/items" } ?? "/watchlist/items"
        }
    }

    struct ListContents: Sendable, Identifiable {
        let list: List
        let items: [MetaPreview]
        var id: String { list.id }
    }

    /// A resume point. MDBList reports progress as a percentage rather than a position, so the
    /// seconds are derived from the runtime it sends alongside — and without a runtime there is no
    /// position to resume to, which is why it is optional.
    struct PlaybackEntry: Sendable {
        let contentId: String
        let contentType: ContentType
        let season: Int?
        let episode: Int?
        let progressPercent: Double
        let runtimeMinutes: Int?
        let updatedAt: Date?
        /// MDBList's own row id, needed to delete the resume point.
        let playbackId: Int?
    }

    struct WatchedEntry: Sendable {
        let contentId: String
        let contentType: ContentType
        let season: Int?
        let episode: Int?
        let watchedAt: Date?
    }

    enum ScrobbleAction: String, Sendable { case start, pause, stop }

    /// Upstream's `MdbListItemType`, reduced to the two an addon can open.
    private static func itemType(_ type: ContentType) -> String {
        type == .movie ? "movie" : "show"
    }

    // MARK: - Ids

    /// Which of the three statements about a row's type to believe, or none.
    ///
    /// Order matters and is not arbitrary: the row's own field is the most specific, the group key
    /// it arrived under is MDBList saying the same thing about a batch, and the list's declared
    /// type is a property of the list rather than of this row. `nil` is a real answer — see
    /// `preview(from:declaredType:list:)`.
    static func resolvedType(row: String?, group: String?, list: String?) -> ContentType? {
        let declared = row?.nilIfBlank?.lowercased()
            ?? group?.nilIfBlank?.lowercased()
            ?? list?.nilIfBlank?.lowercased()
        guard let declared else { return nil }
        return declared == "movie" ? .movie : .series
    }

    /// The ids MDBList answers with, flattened, and the Stremio id chosen from them.
    ///
    /// Same preference order as everywhere else in the app — IMDb first because almost every
    /// addon declares `tt` — and reusing `SimklClient.canonicalContentId` was tempting and wrong:
    /// MDBList publishes a `trakt` id that Simkl never does, and its own `mdblist` id resolves
    /// nowhere at all, so it must never become a content id.
    static func contentId(from ids: [String: String]) -> String? {
        if let imdb = ids["imdb"]?.nilIfBlank { return imdb }
        for key in ["tmdb", "tvdb", "trakt"] {
            if let value = ids[key]?.nilIfBlank { return "\(key):\(value)" }
        }
        return nil
    }

    private struct FlexibleValue: Decodable, Sendable {
        let text: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { text = value.nilIfBlank; return }
            if let value = try? container.decode(Int64.self) { text = String(value); return }
            if let value = try? container.decode(Double.self) {
                text = value.rounded() == value ? String(Int64(value)) : String(value)
                return
            }
            text = nil
        }
    }

    private struct IdsPayload: Decodable, Sendable {
        let imdb: FlexibleValue?
        let tmdb: FlexibleValue?
        let tvdb: FlexibleValue?
        let trakt: FlexibleValue?

        var flattened: [String: String] {
            var out: [String: String] = [:]
            if let value = imdb?.text { out["imdb"] = value }
            if let value = tmdb?.text { out["tmdb"] = value }
            if let value = tvdb?.text { out["tvdb"] = value }
            if let value = trakt?.text { out["trakt"] = value }
            return out
        }
    }

    /// One row of a list. MDBList spells the same field several ways depending on which endpoint
    /// answered — `ids.imdb` on the sync routes, a flat `imdb_id` on the list routes — so both are
    /// read rather than one being assumed.
    private struct ListEntry: Decodable, Sendable {
        let title: String?
        let year: Int?
        let poster: String?
        let backdrop: String?
        let mediatype: String?
        let media_type: String?
        let ids: IdsPayload?
        let imdb_id: String?
        let tmdb_id: FlexibleValue?
        let tvdb_id: FlexibleValue?
        let description: String?
        let genres: [String]?

        var flattenedIds: [String: String] {
            var out = ids?.flattened ?? [:]
            if out["imdb"] == nil, let value = imdb_id?.nilIfBlank { out["imdb"] = value }
            if out["tmdb"] == nil, let value = tmdb_id?.text { out["tmdb"] = value }
            if out["tvdb"] == nil, let value = tvdb_id?.text { out["tvdb"] = value }
            return out
        }
    }

    // MARK: - Requests

    private func headers(token: String?) -> [String: String] {
        var headers = ["Accept": "application/json"]
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    fileprivate func get<T: Decodable>(
        _ path: String, query: [String: String] = [:], token: String, as type: T.Type
    ) async throws -> T {
        var components = URLComponents(string: base + path)
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url?.absoluteString else {
            throw StremioError.invalidURL(base + path)
        }
        return try await IntegrationHTTP.get(url, headers: headers(token: token), as: type)
    }

    // MARK: - Device authorisation

    /// `POST /oauth/device-authorization/`. Asks for the `write` scope outright: every write this
    /// client makes needs it, and a read-only token would fail at the first watchlist change
    /// rather than at sign-in, which is the worse place to discover it.
    func startDeviceAuth(clientId: String) async throws -> DeviceCode {
        struct Response: Decodable {
            let device_code: String?
            let user_code: String?
            let verification_uri: String?
            let verification_uri_complete: String?
            let expires_in: Int?
            let interval: Int?
        }
        let (status, data) = try await IntegrationHTTP.postForm(
            "\(base)/oauth/device-authorization/",
            fields: ["client_id": clientId, "scope": "write"]
        )
        guard (200..<300).contains(status),
              let payload = try? JSONDecoder().decode(Response.self, from: data),
              let deviceCode = payload.device_code?.nilIfBlank,
              let userCode = payload.user_code?.nilIfBlank,
              let verification = Self.verificationURL(payload.verification_uri)
        else { throw StremioError.http(status, "\(base)/oauth/device-authorization/") }

        let complete = Self.verificationURL(payload.verification_uri_complete)
            ?? "\(verification)?user_code=\(userCode.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? userCode)"
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verification,
            verificationURLComplete: complete,
            expiresIn: payload.expires_in ?? 600,
            interval: min(max(payload.interval ?? 5, 1), 3_600)
        )
    }

    /// Only an `https` URL on mdblist.com, and never one carrying credentials.
    ///
    /// Upstream checks the same four things. It is worth keeping because this string is put on
    /// screen as a QR code for someone to scan on their phone: a redirect host substituted into a
    /// response would be a scannable link to somewhere else entirely.
    static func verificationURL(_ value: String?) -> String? {
        guard let value = value?.nilIfBlank,
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host == "mdblist.com",
              components.user == nil, components.password == nil
        else { return nil }
        return components.url?.absoluteString
    }

    /// Polls `/oauth/token/` until the viewer approves the code, honouring MDBList's own pacing.
    ///
    /// `slow_down` widens the interval rather than being treated as a failure — polling through it
    /// is how a client gets rate-limited off the flow entirely.
    func pollForToken(
        deviceCode: String, clientId: String, interval: Int, expiresIn: Int
    ) async -> Tokens? {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var wait = max(interval, 1)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(wait))
            if Task.isCancelled { return nil }
            guard let (status, data) = try? await IntegrationHTTP.postForm(
                "\(base)/oauth/token/",
                fields: [
                    "client_id": clientId,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": deviceCode,
                    "scope": "write"
                ]
            ) else { continue }

            if (200..<300).contains(status), let tokens = Self.tokens(from: data) { return tokens }
            switch Self.errorCode(in: data) {
            case "slow_down": wait = min(wait + 5, 3_600)
            case "authorization_pending", nil: break
            // `access_denied` and `expired_token` are answers, not hiccups: continuing to poll
            // after either would keep the code on screen until it timed out on its own.
            default: return nil
            }
        }
        return nil
    }

    func refresh(refreshToken: String, clientId: String) async -> Tokens? {
        guard let (status, data) = try? await IntegrationHTTP.postForm(
            "\(base)/oauth/token/",
            fields: [
                "client_id": clientId,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ]
        ), (200..<300).contains(status) else { return nil }
        // MDBList may answer a refresh without reissuing the refresh token, in which case the one
        // just used is still the current one. Losing it here would sign the viewer out silently at
        // the next expiry.
        return Self.tokens(from: data, fallbackRefreshToken: refreshToken)
    }

    /// `POST /oauth/revoke_token/`. Best effort: the local session is cleared either way, and a
    /// viewer who has signed out must not be left signed in because the network was down.
    func revoke(refreshToken: String, clientId: String) async {
        _ = try? await IntegrationHTTP.postForm(
            "\(base)/oauth/revoke_token/",
            fields: [
                "client_id": clientId,
                "token": refreshToken,
                "token_type_hint": "refresh_token"
            ]
        )
    }

    static func tokens(from data: Data, fallbackRefreshToken: String? = nil) -> Tokens? {
        struct Response: Decodable {
            let access_token: String?
            let refresh_token: String?
            let token_type: String?
            let scope: String?
            let expires_in: Int?
        }
        guard let payload = try? JSONDecoder().decode(Response.self, from: data),
              let access = payload.access_token?.nilIfBlank,
              let refresh = payload.refresh_token?.nilIfBlank ?? fallbackRefreshToken?.nilIfBlank
        else { return nil }
        if let type = payload.token_type, type.caseInsensitiveCompare("Bearer") != .orderedSame {
            return nil
        }
        // A token issued without `write` cannot do what this account was connected for, and
        // finding that out at the first watchlist change would look like the write failing.
        if let scope = payload.scope,
           !scope.split(whereSeparator: \.isWhitespace).contains("write") {
            return nil
        }
        return Tokens(accessToken: access, refreshToken: refresh, expiresIn: payload.expires_in ?? 3_600)
    }

    static func errorCode(in data: Data) -> String? {
        struct Payload: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.error?.nilIfBlank
    }

    func username(token: String) async -> String? {
        struct Response: Decodable { let username: String?; let name: String? }
        let payload = try? await get("/user", token: token, as: Response.self)
        return payload?.username?.nilIfBlank ?? payload?.name?.nilIfBlank
    }

    // MARK: - Lists

    /// `GET /lists/user`. The watchlist is prepended rather than returned by MDBList: it lives at
    /// its own path and has no id, but to the viewer it is the first list.
    func lists(token: String) async -> [List] {
        struct Payload: Decodable {
            let id: Int?
            let name: String?
            let `private`: Bool?
            let mediatype: String?
            let media_type: String?
        }
        let watchlist = List(
            listId: nil,
            name: L10n.text("library.mdblist_watchlist", fallback: "Watchlist"),
            isPrivate: true,
            mediaType: nil
        )
        guard let payload = try? await get(
            "/lists/user", query: ["unified": "false", "sort": "ranked"],
            token: token, as: [Payload].self
        ) else { return [watchlist] }

        return [watchlist] + payload.compactMap { entry in
            guard let id = entry.id, id > 0, let name = entry.name?.nilIfBlank else { return nil }
            return List(
                listId: id,
                name: name,
                isPrivate: entry.private ?? false,
                mediaType: (entry.mediatype ?? entry.media_type)?.nilIfBlank?.lowercased()
            )
        }
    }

    /// The contents of one list, paged to the end.
    ///
    /// MDBList returns a list's items under `movies` and `shows` keys when `unified=false` and as
    /// one array when `unified=true`; both shapes are decoded, because the watchlist and the
    /// static lists do not agree on which they use.
    func items(in list: List, token: String) async -> [MetaPreview] {
        struct Page: Decodable {
            let movies: [ListEntry]?
            let shows: [ListEntry]?
            let items: [ListEntry]?
            let next_cursor: String?
            let nextCursor: String?

            /// Each row with the type MDBList stated for it, which for the grouped shape is the
            /// *key it arrived under* and nothing on the row itself.
            ///
            /// Merging the two groups and reading `mediatype` off each row was the first version
            /// of this and it dropped the entire watchlist: `unified=false` answers
            /// `{movies: […], shows: […]}` with no per-row type, so every row looked untyped.
            var typed: [(entry: ListEntry, declared: String?)] {
                (items ?? []).map { ($0, nil) }
                    + (movies ?? []).map { ($0, "movie") }
                    + (shows ?? []).map { ($0, "show") }
            }
            var cursor: String? { (next_cursor ?? nextCursor)?.nilIfBlank }
        }

        var query = [
            "limit": "1000",
            "sort": "rank",
            "order": "asc",
            "unified": "true",
            "append_to_response": "poster,description,genres"
        ]
        var collected: [MetaPreview] = []
        var seen = Set<String>()
        var visitedCursors = Set<String>()

        // Bounded rather than `while true`: a service that keeps handing back a cursor would
        // otherwise page for as long as the screen is open.
        for _ in 0..<Self.maximumPages {
            // Either shape: a bare array when the endpoint does not paginate, an object when it
            // does. Trying the array first costs one failed decode on the paging path.
            let entries: [(entry: ListEntry, declared: String?)]
            var cursor: String?
            if let page = try? await get(
                list.itemsPath, query: query, token: token, as: Page.self
            ) {
                entries = page.typed
                cursor = page.cursor
            } else if let array = try? await get(
                list.itemsPath, query: query, token: token, as: [ListEntry].self
            ) {
                entries = array.map { ($0, nil) }
            } else {
                break
            }

            for (entry, declared) in entries {
                guard let preview = Self.preview(from: entry, declaredType: declared, list: list)
                else { continue }
                guard seen.insert(preview.rowKey).inserted else { continue }
                collected.append(preview)
            }
            guard let cursor, visitedCursors.insert(cursor).inserted else { break }
            query["cursor"] = cursor
        }
        return collected
    }

    /// Upstream's `repeat(1_000)`, kept as a named bound.
    static let maximumPages = 1_000

    /// A list row as the rails draw it.
    ///
    /// Three places the type can come from, in descending order of how much MDBList meant it: the
    /// row's own `mediatype`, the group key it arrived under, and the list's declared type — a
    /// single-type static list being a statement about everything in it. A row with none of the
    /// three is dropped rather than guessed at, because opening a series as a film asks the wrong
    /// addon and finds nothing.
    private static func preview(
        from entry: ListEntry, declaredType: String?, list: List
    ) -> MetaPreview? {
        guard let name = entry.title?.nilIfBlank,
              let id = contentId(from: entry.flattenedIds)
        else { return nil }
        guard let type = resolvedType(
            row: entry.mediatype ?? entry.media_type, group: declaredType, list: list.mediaType
        ) else { return nil }
        return MetaPreview(
            id: id,
            type: type,
            rawType: type.apiString(),
            name: name,
            poster: entry.poster?.nilIfBlank,
            background: entry.backdrop?.nilIfBlank ?? entry.poster?.nilIfBlank,
            description: entry.description?.nilIfBlank,
            releaseInfo: entry.year.map(String.init),
            genres: entry.genres ?? [],
            imdbId: entry.flattenedIds["imdb"]
        )
    }

    // MARK: - Watched and resume points

    /// `GET /sync/playback`. What Continue Watching reads when MDBList is the progress source.
    func playback(token: String) async -> [PlaybackEntry] {
        struct Entry: Decodable {
            let id: Int?
            let type: String?
            let progress: Double?
            let updated_at: String?
            let season: Int?
            let episode: Int?
            let runtime: Int?
            let ids: IdsPayload?
            let movie: MediaPayload?
            let show: MediaPayload?
        }
        struct MediaPayload: Decodable {
            let ids: IdsPayload?
            let runtime: Int?
        }
        struct Page: Decodable {
            let items: [Entry]?
            let playback: [Entry]?
            var all: [Entry] { (items ?? []) + (playback ?? []) }
        }

        let entries: [Entry]
        if let array = try? await get("/sync/playback", token: token, as: [Entry].self) {
            entries = array
        } else if let page = try? await get("/sync/playback", token: token, as: Page.self) {
            entries = page.all
        } else {
            return []
        }

        return entries.compactMap { entry in
            let ids = (entry.ids ?? entry.movie?.ids ?? entry.show?.ids)?.flattened ?? [:]
            guard let contentId = Self.contentId(from: ids) else { return nil }
            let isMovie = entry.type?.lowercased() == "movie" || entry.movie != nil
            return PlaybackEntry(
                contentId: contentId,
                contentType: isMovie ? .movie : .series,
                season: entry.season,
                episode: entry.episode,
                progressPercent: min(100, max(0, entry.progress ?? 0)),
                runtimeMinutes: entry.runtime ?? entry.movie?.runtime ?? entry.show?.runtime,
                updatedAt: Self.date(entry.updated_at),
                playbackId: entry.id
            )
        }
    }

    /// `DELETE /sync/playback/{id}`, the same spelling Trakt and Simkl use.
    func deletePlayback(id: Int, token: String) async -> Bool {
        (try? await IntegrationHTTP.delete(
            "\(base)/sync/playback/\(id)", headers: headers(token: token)
        )) != nil
    }

    static func date(_ value: String?) -> Date? {
        guard let value = value?.nilIfBlank else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

// MARK: - Watched marks, writes and the scrobble

extension MDBListClient {
    /// `GET /sync/watched`. Read for the watched state rather than for Continue Watching, which
    /// wants `/sync/playback` — a finished title has a watched row and no resume point.
    func watched(token: String) async -> [WatchedEntry] {
        struct Entry: Decodable {
            let type: String?
            let watched_at: String?
            let season: Int?
            let episode: Int?
            let ids: WatchedIds?
            let movie: WatchedMedia?
            let show: WatchedMedia?
        }
        struct WatchedIds: Decodable {
            let imdb: String?
            let tmdb: Int64?
            let tvdb: Int64?
            let trakt: Int64?

            var flattened: [String: String] {
                var out: [String: String] = [:]
                if let imdb = imdb?.nilIfBlank { out["imdb"] = imdb }
                if let tmdb { out["tmdb"] = String(tmdb) }
                if let tvdb { out["tvdb"] = String(tvdb) }
                if let trakt { out["trakt"] = String(trakt) }
                return out
            }
        }
        struct WatchedMedia: Decodable { let ids: WatchedIds? }
        struct Page: Decodable {
            let items: [Entry]?
            let watched: [Entry]?
            var all: [Entry] { (items ?? []) + (watched ?? []) }
        }

        let entries: [Entry]
        if let array = try? await get("/sync/watched", token: token, as: [Entry].self) {
            entries = array
        } else if let page = try? await get("/sync/watched", token: token, as: Page.self) {
            entries = page.all
        } else {
            return []
        }

        return entries.compactMap { entry in
            let ids = (entry.ids ?? entry.movie?.ids ?? entry.show?.ids)?.flattened ?? [:]
            guard let contentId = Self.contentId(from: ids) else { return nil }
            let isMovie = entry.type?.lowercased() == "movie" || entry.movie != nil
            return WatchedEntry(
                contentId: contentId,
                contentType: isMovie ? .movie : .series,
                season: entry.season,
                episode: entry.episode,
                watchedAt: Self.date(entry.watched_at)
            )
        }
    }

    // MARK: Membership

    /// Adds or removes one title from the watchlist or a static list.
    ///
    /// `POST …/items/add` and `…/items/remove`, which is the shape upstream's writer uses. The
    /// return value is whether MDBList accepted it, because the caller has to be able to say
    /// "saved on this Apple TV only" — see `TrackingWriteService`.
    func setMembership(
        inList list: List,
        contentId: String,
        contentType: ContentType,
        imdbId: String?,
        isMember: Bool,
        token: String
    ) async -> Bool {
        guard let ids = Self.requestIds(contentId: contentId, imdbId: imdbId) else { return false }
        let group = contentType == .movie ? "movies" : "shows"
        let body: [String: [[String: AnyJSON]]] = [group: [ids]]
        return await post(
            "\(list.itemsPath)/\(isMember ? "add" : "remove")", body: body, token: token
        )
    }

    /// `POST /sync/history` — a watched mark, or its removal.
    ///
    /// An episode is sent inside its show rather than on its own: MDBList keys episodes by their
    /// *own* TMDB or TVDB id, which a Stremio addon does not publish, so the only reliable address
    /// for one is the show plus season and episode numbers. That is upstream's `shows` group, and
    /// the reason their `episodes` group is unreachable from here.
    func setWatched(
        contentId: String,
        contentType: ContentType,
        imdbId: String?,
        season: Int?,
        episode: Int?,
        isWatched: Bool,
        watchedAt: Date,
        token: String
    ) async -> Bool {
        guard var ids = Self.requestIds(contentId: contentId, imdbId: imdbId) else { return false }
        let stamp = ISO8601DateFormatter().string(from: watchedAt)

        if contentType == .series, let season, let episode {
            ids["seasons"] = .array([
                .object([
                    "number": .number(Double(season)),
                    "episodes": .array([
                        .object(isWatched
                            ? ["number": .number(Double(episode)), "watched_at": .string(stamp)]
                            : ["number": .number(Double(episode))])
                    ])
                ])
            ])
            return await post(
                isWatched ? "/sync/history" : "/sync/history/remove",
                body: ["shows": [ids]], token: token
            )
        }

        if isWatched { ids["watched_at"] = .string(stamp) }
        let group = contentType == .movie ? "movies" : "shows"
        return await post(
            isWatched ? "/sync/history" : "/sync/history/remove",
            body: [group: [ids]], token: token
        )
    }

    // MARK: Scrobble

    /// `POST /scrobble/{start|pause|stop}`.
    ///
    /// MDBList takes a percentage where Trakt takes one too and Simkl takes seconds; the caller
    /// passes the percentage so the conversion stays where the runtime is known.
    func scrobble(
        _ action: ScrobbleAction,
        contentId: String,
        contentType: ContentType,
        imdbId: String?,
        season: Int?,
        episode: Int?,
        progressPercent: Double,
        token: String
    ) async -> Bool {
        guard var body = Self.scrobbleBody(
            contentId: contentId, contentType: contentType, imdbId: imdbId,
            season: season, episode: episode
        ) else { return false }
        body["progress"] = .number(min(100, max(0, progressPercent)))
        return await post("/scrobble/\(action.rawValue)", object: body, token: token)
    }

    /// `POST /scrobble/clear`. Removing a title from Continue Watching has to clear the session as
    /// well as the resume point, or the next sync puts the row straight back — the same defect
    /// `delete-playback` fixed for Simkl in 1.0.26.
    func clearScrobble(
        contentId: String,
        contentType: ContentType,
        imdbId: String?,
        season: Int?,
        episode: Int?,
        token: String
    ) async -> Bool {
        guard let body = Self.scrobbleBody(
            contentId: contentId, contentType: contentType, imdbId: imdbId,
            season: season, episode: episode
        ) else { return false }
        return await post("/scrobble/clear", object: body, token: token)
    }

    private static func scrobbleBody(
        contentId: String, contentType: ContentType, imdbId: String?, season: Int?, episode: Int?
    ) -> [String: AnyJSON]? {
        guard let ids = requestIds(contentId: contentId, imdbId: imdbId) else { return nil }
        var body: [String: AnyJSON] = [
            "type": .string(contentType == .movie ? "movie" : "show"),
            "ids": .object(ids)
        ]
        if contentType == .series, let season, let episode {
            body["season"] = .number(Double(season))
            body["episode"] = .number(Double(episode))
        }
        return body
    }

    // MARK: Ratings

    /// The aggregated scores, from whichever credential the viewer has.
    ///
    /// Upstream made this change in the same window — *"use connected account for ratings with api
    /// key override"* — and the ordering is the interesting half: **a pasted key wins over a
    /// connected account.** It reads backwards until you see it from the viewer's side. Both work;
    /// the key is the one they went and fetched on purpose, and it is the quota they chose to
    /// spend. Silently preferring the account would make the field they filled in do nothing.
    ///
    /// Before this, connecting an account did not help the ratings row at all: no key meant no
    /// scores, however signed in you were.
    func ratings(
        imdbId: String, contentType: ContentType, apiKey: String, token: String
    ) async -> MDBListRatings? {
        guard let imdbId = imdbId.nilIfBlank else { return nil }
        let cacheKey = "\(contentType == .movie ? "movie" : "show")|\(imdbId)"
        if let hit = ratingsCache[cacheKey] { return hit }

        struct Entry: Decodable { let source: String?; let value: Double? }
        struct Response: Decodable { let ratings: [Entry]? }

        var response: Response?
        if let apiKey = apiKey.nilIfBlank {
            response = try? await IntegrationHTTP.get(
                "\(base)/?apikey=\(apiKey)&i=\(imdbId)", as: Response.self
            )
        } else if let token = token.nilIfBlank {
            response = try? await get(
                "/imdb/\(contentType == .movie ? "movie" : "show")/\(imdbId)/",
                token: token, as: Response.self
            )
        }
        guard let response else { return nil }

        let ratings = Self.ratings(from: response.ratings.map { $0.map { ($0.source, $0.value) } } ?? [])
        ratingsCache[cacheKey] = ratings
        return ratings
    }

    /// MDBList publishes its scores as a list of named sources rather than as fields.
    static func ratings(from entries: [(String?, Double?)]) -> MDBListRatings {
        var ratings = MDBListRatings()
        for (source, value) in entries {
            guard let source = source?.lowercased(), let value else { continue }
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
        return ratings
    }

    // MARK: Plumbing

    /// The ids MDBList will accept for a write.
    ///
    /// A `trakt:` id is deliberately not sent even though MDBList publishes one: it identifies the
    /// title in *Trakt's* database, and sending it as an MDBList address is how a write lands on
    /// whatever MDBList happens to have under that number.
    static func requestIds(contentId: String, imdbId: String?) -> [String: AnyJSON]? {
        if let imdb = imdbId?.nilIfBlank ?? (contentId.hasPrefix("tt") ? contentId : nil) {
            return ["imdb": .string(imdb.split(separator: ":").first.map(String.init) ?? imdb)]
        }
        for prefix in ["tmdb", "tvdb"] where contentId.hasPrefix("\(prefix):") {
            let raw = String(contentId.dropFirst(prefix.count + 1))
            guard let number = Int(raw) else { return nil }
            return [prefix: .number(Double(number))]
        }
        return nil
    }

    private func post(
        _ path: String, body: [String: [[String: AnyJSON]]], token: String
    ) async -> Bool {
        await post(path, encodable: body, token: token)
    }

    private func post(
        _ path: String, object: [String: AnyJSON], token: String
    ) async -> Bool {
        await post(path, encodable: object, token: token)
    }

    private func post(_ path: String, encodable: Encodable, token: String) async -> Bool {
        do {
            _ = try await IntegrationHTTP.post(
                "https://api.mdblist.com" + path,
                headers: ["Accept": "application/json", "Authorization": "Bearer \(token)"],
                json: encodable,
                as: EmptyResponse.self
            )
            return true
        } catch {
            log.error("MDBList write to \(path, privacy: .public) failed: \(error, privacy: .public)")
            return false
        }
    }
}
