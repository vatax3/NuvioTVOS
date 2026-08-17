import Foundation
import os

/// Which Nuvio backend this install talks to.
///
/// The official app reads its Supabase URL and publishable key from `local.properties` at build
/// time, so they are not in the public source and cannot be redistributed by a third-party
/// client — the same situation as the Trakt client id. The app also ships a first-class custom
/// server path (`FEATURE_CUSTOM_SERVER_CONNECTIONS_ENABLED`), which is what this uses: the
/// viewer supplies a backend URL and publishable key, either Nuvio's own or a self-hosted
/// instance carrying the same schema.
struct NuvioServerConfiguration: Codable, Hashable, Sendable {
    var backendUrl: String
    var publishableKey: String
    /// `false` disables the QR flow; a self-hosted instance may not have the edge function.
    var supportsTvLogin: Bool = true
    var supportsEmailPassword: Bool = true

    var isConfigured: Bool {
        !normalizedBackendUrl.isEmpty && !publishableKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var normalizedBackendUrl: String {
        var trimmed = backendUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return "" }
        if !trimmed.lowercased().hasPrefix("http") { trimmed = "https://" + trimmed }
        return trimmed
    }

    /// Where the phone finishes a TV login. The official deployment serves this from the site
    /// root; a self-hosted Supabase serves it from the project domain.
    var tvLoginWebBaseUrl: String { "\(normalizedBackendUrl)/tv-login" }

    var avatarPublicBaseUrl: String {
        "\(normalizedBackendUrl)/storage/v1/object/public/avatars"
    }
}

// MARK: - Discovery

/// Port of `ServerDiscoveryService`: a server publishes `/.well-known/nuvio` and the viewer only
/// has to type its domain. Same document version, service check and self-hosted requirement as
/// the Android client — the official backend is deliberately not discoverable (its own code
/// throws `OFFICIAL_SERVER` for it), so this path is for self-hosted instances.
enum NuvioServerDiscovery {
    struct Document: Decodable {
        let version: Int
        let service: String
        let self_hosted: Bool
        let backend_url: String
        let publishable_key: String
        let capabilities: Capabilities

        struct Capabilities: Decodable {
            let email_password_auth: Bool?
            let tv_login: Bool?
        }
    }

    enum Failure: LocalizedError {
        case invalidURL
        case connectionFailed
        case http(Int)
        case invalidDocument
        case unsupportedVersion
        case wrongService
        case notSelfHosted
        case missingConfiguration
        case noSupportedAuth

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "That is not a valid address."
            case .connectionFailed: return "Could not reach that server."
            case .http(let status): return "The server answered \(status)."
            case .invalidDocument: return "That server did not return a Nuvio discovery document."
            case .unsupportedVersion: return "That server uses a discovery format this app does not know."
            case .wrongService: return "That address is not a Nuvio server."
            case .notSelfHosted:
                return "Only self-hosted servers can be discovered. Nuvio's own backend is not configurable this way."
            case .missingConfiguration: return "The discovery document is missing a backend URL or key."
            case .noSupportedAuth: return "That server offers no sign-in method this app supports."
            }
        }
    }

    /// `example.com` → `https://example.com/.well-known/nuvio`, preserving any base path.
    static func discoveryURL(for input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.invalidURL }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil else {
            throw Failure.invalidURL
        }
        let suffix = "/.well-known/nuvio"
        var basePath = components.path
        if basePath.hasSuffix(suffix) { basePath.removeLast(suffix.count) }
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath.isEmpty ? suffix : basePath + suffix
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw Failure.invalidURL }
        return url
    }

    static func discover(_ input: String) async throws -> NuvioServerConfiguration {
        let url = try discoveryURL(for: input)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NuvioTVOS/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.connectionFailed
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        // A document larger than this is not a discovery document.
        guard data.count <= 64 * 1024 else { throw Failure.invalidDocument }
        // An https request that ended up on http was downgraded somewhere.
        if url.scheme?.lowercased() == "https", response.url?.scheme?.lowercased() != "https" {
            throw Failure.connectionFailed
        }

        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            throw Failure.invalidDocument
        }
        guard document.version == 1 else { throw Failure.unsupportedVersion }
        guard document.service.lowercased() == "nuvio" else { throw Failure.wrongService }
        guard document.self_hosted else { throw Failure.notSelfHosted }

        let key = document.publishable_key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              let backend = URL(string: document.backend_url.trimmingCharacters(in: .whitespaces)),
              let backendScheme = backend.scheme?.lowercased(),
              backendScheme == "http" || backendScheme == "https" else {
            throw Failure.missingConfiguration
        }

        let emailPassword = document.capabilities.email_password_auth ?? false
        let tvLogin = document.capabilities.tv_login ?? false
        guard emailPassword || tvLogin else { throw Failure.noSupportedAuth }

        return NuvioServerConfiguration(
            backendUrl: backend.absoluteString,
            publishableKey: key,
            supportsTvLogin: tvLogin,
            supportsEmailPassword: emailPassword
        )
    }
}

// MARK: - Session

struct NuvioSession: Codable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userId: String?
    var email: String?

    /// Refreshed a minute early so a long request cannot start on a token about to die.
    var isExpired: Bool { Date().addingTimeInterval(60) >= expiresAt }
}

// MARK: - Errors

enum NuvioBackendError: LocalizedError {
    case notConfigured
    case notSignedIn
    case http(Int, String)
    case decoding(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No Nuvio backend is configured."
        case .notSignedIn:
            return "Not signed in."
        case .http(let status, let body):
            // Supabase puts a human-readable reason in the body; surface it rather than a code.
            let detail = NuvioBackend.humanReadableError(from: body) ?? body
            return "Server returned \(status): \(detail.prefix(200))"
        case .decoding(let detail):
            return "Unexpected response: \(detail)"
        case .message(let text):
            return text
        }
    }
}

// MARK: - Client

/// Thin Supabase client: PostgREST RPC, table selects, token refresh and the TV-login edge
/// function. Deliberately hand-rolled — the Kotlin app uses the supabase-kt SDK, but the only
/// surface the sync layer needs is JSON over three endpoint shapes.
actor NuvioBackend {
    static let shared = NuvioBackend()

    private let log = Logger(subsystem: "com.nuvio.tvos", category: "NuvioBackend")
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    private var configuration = NuvioServerConfiguration(backendUrl: "", publishableKey: "")
    private var currentSession: NuvioSession?
    /// Serialises refreshes so a burst of expired-token requests triggers exactly one.
    private var refreshTask: Task<NuvioSession, Error>?

    func configure(_ configuration: NuvioServerConfiguration, session: NuvioSession?) {
        self.configuration = configuration
        self.currentSession = session
    }

    func updateSession(_ session: NuvioSession?) {
        currentSession = session
    }

    // MARK: Endpoints

    private func url(_ path: String) throws -> URL {
        guard configuration.isConfigured,
              let url = URL(string: configuration.normalizedBackendUrl + path) else {
            throw NuvioBackendError.notConfigured
        }
        return url
    }

    private func headers(authenticated: Bool) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "apikey": configuration.publishableKey,
            "User-Agent": "NuvioTVOS/1.0"
        ]
        // Supabase wants the anon key as the bearer when there is no user session.
        let bearer = (authenticated ? currentSession?.accessToken : nil) ?? configuration.publishableKey
        headers["Authorization"] = "Bearer \(bearer)"
        return headers
    }

    // MARK: Requests

    /// One request, retried once after a token refresh if the server rejected the JWT.
    private func send(
        path: String,
        method: String = "POST",
        body: Data? = nil,
        authenticated: Bool,
        allowRefresh: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers(authenticated: authenticated) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if (200..<300).contains(status) { return data }

        let bodyText = String(data: data, encoding: .utf8) ?? ""
        // 401/403 with an expired-JWT reason is the one case worth a silent retry.
        if allowRefresh, authenticated, status == 401 || status == 403,
           bodyText.lowercased().contains("jwt") || bodyText.lowercased().contains("token") {
            _ = try await refreshSession()
            return try await send(
                path: path, method: method, body: body,
                authenticated: authenticated, allowRefresh: false
            )
        }
        throw NuvioBackendError.http(status, bodyText)
    }

    /// Calls a PostgREST function. Nuvio's sync surface is entirely RPC.
    @discardableResult
    func rpc<T: Decodable>(
        _ name: String,
        parameters: [String: AnyJSONValue] = [:],
        as type: T.Type,
        authenticated: Bool = true
    ) async throws -> T {
        let body = try JSONEncoder().encode(parameters)
        let data = try await send(
            path: "/rest/v1/rpc/\(name)", body: body, authenticated: authenticated
        )
        if T.self == EmptyDecodable.self { return EmptyDecodable() as! T }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NuvioBackendError.decoding(
                "\(name): \(error.localizedDescription) — \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"
            )
        }
    }

    @discardableResult
    func rpcVoid(_ name: String, parameters: [String: AnyJSONValue] = [:]) async throws -> Bool {
        _ = try await send(
            path: "/rest/v1/rpc/\(name)",
            body: try JSONEncoder().encode(parameters),
            authenticated: true
        )
        return true
    }

    /// Table read, used for the addon and plugin tables the Android app selects directly.
    func select<T: Decodable>(
        table: String,
        filters: [String: String],
        as type: T.Type
    ) async throws -> T {
        var components = URLComponents(string: configuration.normalizedBackendUrl + "/rest/v1/\(table)")
        components?.queryItems = filters.map { URLQueryItem(name: $0.key, value: "eq.\($0.value)") }
            + [URLQueryItem(name: "select", value: "*")]
        guard configuration.isConfigured, let url = components?.url else {
            throw NuvioBackendError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers(authenticated: true) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NuvioBackendError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A Supabase edge function; `tv-logins-exchange` is the only one used.
    func invokeFunction<T: Decodable>(
        _ name: String,
        payload: [String: AnyJSONValue],
        as type: T.Type
    ) async throws -> T {
        let data = try await send(
            path: "/functions/v1/\(name)",
            body: try JSONEncoder().encode(payload),
            authenticated: false
        )
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NuvioBackendError.decoding(
                "\(name): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"
            )
        }
    }

    /// GoTrue endpoints under `/auth/v1`. Used for password grants; the TV-login path goes
    /// through the edge function instead.
    func authRequest<T: Decodable>(
        _ path: String,
        payload: [String: AnyJSONValue],
        as type: T.Type
    ) async throws -> T {
        let data = try await send(
            path: "/auth/v1/\(path)",
            body: try JSONEncoder().encode(payload),
            authenticated: false,
            allowRefresh: false
        )
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NuvioBackendError.decoding(
                "\(path): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"
            )
        }
    }

    // MARK: Token refresh

    /// Exchanges the refresh token for a new session. Callers await the same in-flight task.
    func refreshSession() async throws -> NuvioSession {
        if let refreshTask { return try await refreshTask.value }
        guard let existing = currentSession, !existing.refreshToken.isEmpty else {
            throw NuvioBackendError.notSignedIn
        }

        let task = Task<NuvioSession, Error> {
            defer { refreshTask = nil }
            let body = try JSONEncoder().encode(["refresh_token": existing.refreshToken])
            let data = try await send(
                path: "/auth/v1/token?grant_type=refresh_token",
                body: body,
                authenticated: false,
                allowRefresh: false
            )
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            let session = response.session(fallbackRefreshToken: existing.refreshToken)
            currentSession = session
            return session
        }
        refreshTask = task
        return try await task.value
    }

    // MARK: Wire types

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let token_type: String?
        let expires_in: Double?
        let user: UserPayload?

        struct UserPayload: Decodable {
            let id: String?
            let email: String?
        }

        func session(fallbackRefreshToken: String) -> NuvioSession {
            NuvioSession(
                accessToken: access_token,
                refreshToken: refresh_token?.nilIfBlank ?? fallbackRefreshToken,
                // Supabase access tokens are one hour by default; trust the response when given.
                expiresAt: Date().addingTimeInterval(expires_in ?? 3600),
                userId: user?.id,
                email: user?.email
            )
        }
    }

    /// Pulls the readable half out of a Supabase error body.
    static func humanReadableError(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["message", "error_description", "msg", "error", "hint", "details"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

struct EmptyDecodable: Decodable {}

// MARK: - JSON parameter values

/// RPC parameters are heterogeneous JSON, so they are built from this rather than a dictionary
/// of `Any` that `JSONEncoder` cannot take.
enum AnyJSONValue: Codable, Hashable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyJSONValue])
    case object([String: AnyJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AnyJSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: AnyJSONValue].self) { self = .object(value) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .int64(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }

    /// Convenience for optional fields: absent rather than explicitly null where that matters.
    static func optionalString(_ value: String?) -> AnyJSONValue {
        value?.nilIfBlank.map { .string($0) } ?? .null
    }

    static func optionalInt(_ value: Int?) -> AnyJSONValue {
        value.map { .int($0) } ?? .null
    }
}
