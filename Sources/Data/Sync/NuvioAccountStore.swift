import Foundation
import Observation
import os

/// Nuvio account: server configuration, session, and the QR "TV login" flow.
///
/// Port of `AuthManager`'s TV-login path. The device asks the backend for a short code, shows
/// the phone URL, polls until the phone approves, then exchanges the code for a real Supabase
/// session. Endpoints, RPC names and parameter names all match the Android client so this talks
/// to the same backend and the same rows.
@Observable
@MainActor
final class NuvioAccountStore {
    enum LoginState: Equatable {
        case idle
        case starting
        /// Waiting on the phone. `code` and `url` are what the screen shows.
        case pending(code: String, url: String, expiresAt: Date)
        case exchanging
        case signedIn
        case failed(String)
    }

    private(set) var configuration: NuvioServerConfiguration
    private(set) var session: NuvioSession?
    private(set) var loginState: LoginState = .idle
    /// The account whose rows this device writes to — differs from `session.userId` when this
    /// device was linked to someone else's account.
    private(set) var syncOwnerId: String?

    private let configurationFile = JSONFileStore<NuvioServerConfiguration>(
        filename: "nuvio-server.json", scope: .global, durability: .critical
    )
    private let sessionFile = JSONFileStore<NuvioSession>(
        filename: "nuvio-session.json", scope: .global, durability: .critical
    )
    private let secureSession = KeychainCodableStore<NuvioSession>(key: "nuvio.account.session")
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "NuvioAccount")

    private var loginTask: Task<Void, Never>?
    /// Ties a polling session to this device so another device cannot claim the code.
    private var deviceNonce = UUID().uuidString

    init() {
        configuration = configurationFile.load() ?? .nuvioDefault
        session = secureSession.load()
        if session == nil, let legacySession = sessionFile.load() {
            session = legacySession
            secureSession.save(legacySession)
            sessionFile.delete()
        }
        if session != nil { loginState = .signedIn }

        let configuration = self.configuration
        let session = self.session
        Task { await NuvioBackend.shared.configure(configuration, session: session) }
    }

    var isConfigured: Bool { configuration.isConfigured }
    var isSignedIn: Bool { session != nil }

    var accountLabel: String {
        session?.email?.nilIfBlank ?? session?.userId.map { String($0.prefix(8)) } ?? "Signed in"
    }

    // MARK: Configuration

    func save(configuration new: NuvioServerConfiguration) {
        configuration = new
        configurationFile.save(new)
        let session = self.session
        Task { await NuvioBackend.shared.configure(new, session: session) }
    }

    // MARK: TV login

    /// Starts the QR flow and polls to completion. Cancelling replaces any run in flight.
    func startTvLogin(deviceName: String) {
        guard configuration.isConfigured else {
            loginState = .failed("Add a backend URL and publishable key first.")
            return
        }
        loginTask?.cancel()
        deviceNonce = UUID().uuidString
        loginState = .starting

        loginTask = Task { [deviceNonce] in
            do {
                let start = try await NuvioBackend.shared.rpc(
                    "start_tv_login_session",
                    parameters: [
                        "p_device_nonce": .string(deviceNonce),
                        "p_redirect_base_url": .string(configuration.tvLoginWebBaseUrl),
                        "p_device_name": .string(deviceName)
                    ],
                    // No session yet; the anon key authorises this RPC.
                    as: [TvLoginStartResult].self,
                    authenticated: false
                )
                guard let first = start.first else {
                    loginState = .failed("The server returned no login session.")
                    return
                }
                let expiresAt = VideoDateParser.parse(first.expires_at) ?? Date().addingTimeInterval(600)
                loginState = .pending(code: first.code, url: first.web_url, expiresAt: expiresAt)

                await poll(
                    code: first.code,
                    nonce: deviceNonce,
                    interval: max(2, first.poll_interval_seconds ?? 3),
                    expiresAt: expiresAt
                )
            } catch {
                guard !Task.isCancelled else { return }
                // A missing `p_device_name` means an older server signature; retry without it.
                if error.localizedDescription.lowercased().contains("device_name") {
                    await startTvLoginLegacy(deviceNonce: deviceNonce)
                    return
                }
                loginState = .failed(error.localizedDescription)
            }
        }
    }

    /// The Android client keeps this fallback for servers predating the device-name parameter.
    private func startTvLoginLegacy(deviceNonce: String) async {
        do {
            let start = try await NuvioBackend.shared.rpc(
                "start_tv_login_session",
                parameters: [
                    "p_device_nonce": .string(deviceNonce),
                    "p_redirect_base_url": .string(configuration.tvLoginWebBaseUrl)
                ],
                as: [TvLoginStartResult].self,
                authenticated: false
            )
            guard let first = start.first else {
                loginState = .failed("The server returned no login session.")
                return
            }
            let expiresAt = VideoDateParser.parse(first.expires_at) ?? Date().addingTimeInterval(600)
            loginState = .pending(code: first.code, url: first.web_url, expiresAt: expiresAt)
            await poll(
                code: first.code, nonce: deviceNonce,
                interval: max(2, first.poll_interval_seconds ?? 3), expiresAt: expiresAt
            )
        } catch {
            guard !Task.isCancelled else { return }
            loginState = .failed(error.localizedDescription)
        }
    }

    private func poll(code: String, nonce: String, interval: Int, expiresAt: Date) async {
        var pollInterval = interval
        while !Task.isCancelled, Date() < expiresAt {
            try? await Task.sleep(for: .seconds(pollInterval))
            if Task.isCancelled { return }

            do {
                let results = try await NuvioBackend.shared.rpc(
                    "poll_tv_login_session",
                    parameters: [
                        "p_code": .string(code),
                        "p_device_nonce": .string(nonce)
                    ],
                    as: [TvLoginPollResult].self,
                    authenticated: false
                )
                guard let result = results.first else { continue }
                if let suggested = result.poll_interval_seconds { pollInterval = max(2, suggested) }

                switch result.status.lowercased() {
                case "approved", "ready", "complete", "completed":
                    await exchange(code: code, nonce: nonce)
                    return
                case "expired":
                    loginState = .failed("The code expired. Start again.")
                    return
                case "denied", "rejected", "cancelled", "canceled":
                    loginState = .failed("The sign-in was declined on the other device.")
                    return
                default:
                    continue  // still pending
                }
            } catch {
                // A transient poll failure is normal on a TV's network; keep waiting.
                log.debug("poll failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !Task.isCancelled {
            loginState = .failed("The code expired. Start again.")
        }
    }

    private func exchange(code: String, nonce: String) async {
        loginState = .exchanging
        do {
            let result = try await NuvioBackend.shared.invokeFunction(
                "tv-logins-exchange",
                payload: ["code": .string(code), "device_nonce": .string(nonce)],
                as: NuvioBackend.TokenResponse.self
            )
            let newSession = result.session(fallbackRefreshToken: "")
            guard !newSession.refreshToken.isEmpty else {
                loginState = .failed("The server did not return a refresh token.")
                return
            }
            apply(session: newSession)
            loginState = .signedIn
            await resolveSyncOwner()
        } catch {
            loginState = .failed(error.localizedDescription)
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        if !isSignedIn { loginState = .idle }
    }

    // MARK: Email & password
    //
    // The official deployment turns this off in favour of TV login, but a self-hosted server can
    // enable it, and typing a password is less painful than it sounds with a paired keyboard.

    func signIn(email: String, password: String) async {
        guard configuration.isConfigured else {
            loginState = .failed("Add a backend URL and publishable key first.")
            return
        }
        loginState = .exchanging
        do {
            let result = try await NuvioBackend.shared.authRequest(
                "token?grant_type=password",
                payload: ["email": .string(email), "password": .string(password)],
                as: NuvioBackend.TokenResponse.self
            )
            apply(session: result.session(fallbackRefreshToken: ""))
            loginState = .signedIn
            await resolveSyncOwner()
        } catch {
            loginState = .failed(error.localizedDescription)
        }
    }

    // MARK: Session lifecycle

    private func apply(session newSession: NuvioSession) {
        session = newSession
        secureSession.save(newSession)
        sessionFile.delete()
        Task { await NuvioBackend.shared.updateSession(newSession) }
    }

    /// Refreshes when the stored token is stale, so the first sync of a session does not fail.
    func ensureFreshSession() async {
        guard let current = session, current.isExpired else { return }
        do {
            let refreshed = try await NuvioBackend.shared.refreshSession()
            apply(session: refreshed)
        } catch {
            log.error("refresh failed: \(error.localizedDescription, privacy: .public)")
            // A refresh token the server has revoked means the session is genuinely over.
            if case NuvioBackendError.http(let status, _) = error, status == 400 || status == 401 {
                signOut()
                loginState = .failed("Your session expired. Sign in again.")
            }
        }
    }

    /// `get_sync_owner` resolves the account whose rows this device shares, which is the linked
    /// owner rather than this device's own user when the account was claimed by another device.
    func resolveSyncOwner() async {
        guard isSignedIn else { return }
        do {
            syncOwnerId = try await NuvioBackend.shared.rpc(
                "get_sync_owner", as: String.self
            )
        } catch {
            // Fall back to this device's own id, which is what the Android client does.
            syncOwnerId = session?.userId
            log.debug("get_sync_owner failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func signOut() {
        loginTask?.cancel()
        loginTask = nil
        session = nil
        syncOwnerId = nil
        secureSession.delete()
        sessionFile.delete()
        loginState = .idle
        Task { await NuvioBackend.shared.updateSession(nil) }
    }

    // MARK: Wire types

    private struct TvLoginStartResult: Decodable {
        let code: String
        let web_url: String
        let expires_at: String
        let poll_interval_seconds: Int?
    }

    private struct TvLoginPollResult: Decodable {
        let status: String
        let expires_at: String?
        let poll_interval_seconds: Int?
    }
}

// MARK: - Client identity

/// Stable per-install id sent as `p_origin_client_id`, which is how the server suppresses
/// echoing a device's own mutations back to it. Format matches the Android generator so any
/// server-side validation accepts it.
enum SyncClientIdentity {
    private static let key = "nuvio.sync_client_instance_id"
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    static var current: String {
        if let stored = UserDefaults.standard.string(forKey: key), isValid(stored) {
            return stored
        }
        let generated = "nuvio-tv-" + String((0..<32).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private static func isValid(_ candidate: String) -> Bool {
        candidate.hasPrefix("nuvio-tv-") && candidate.count == "nuvio-tv-".count + 32
    }
}
