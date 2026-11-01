import Foundation

/// Hands out a usable MDBList access token, refreshing it when it has expired.
///
/// The one thing standing between the client and every caller. MDBList's access tokens expire
/// where Simkl's do not and Trakt's last long enough that we never built this for it, so a caller
/// that reads `mdbListAccessToken` straight off the store works until it silently stops — the
/// first failure being a watchlist change that reports success and did nothing.
///
/// Two rules, and the second is the one worth stating:
///
/// - refresh *before* the expiry rather than after a 401, because half the writes here answer 200
///   with a body saying nothing changed, and a 401 is not reliably what an expired token produces;
/// - **a refresh the server refuses clears the session.** Leaving a dead token in place would keep
///   the account looking connected on the Tracking screen for as long as nobody pressed anything.
///   A refresh that merely did not complete — offline, timed out, cancelled — keeps it: the next
///   call tries again, where clearing it would sign the viewer out over a network blip.
@MainActor
enum MDBListSession {
    /// Refresh this far before the stated expiry. A token that dies mid-request is the failure
    /// this margin exists to avoid, and MDBList's tokens last an hour.
    static let refreshMargin: TimeInterval = 120

    /// - Returns: a token good for the next call, or `nil` if the viewer is not connected or the
    ///   session could not be renewed.
    static func token(_ settings: TrackingSettingsStore) async -> String? {
        guard let token = settings.mdbListAccessToken.nilIfBlank else { return nil }
        let expiry = settings.mdbListTokenExpiry
        // Zero means a session stored before the expiry was recorded; treat it as current rather
        // than forcing a refresh that would sign a working account out.
        guard needsRefresh(expiry: expiry, now: Date()) else { return token }
        return await renew(settings)
    }

    static func renew(_ settings: TrackingSettingsStore) async -> String? {
        guard let refreshToken = settings.mdbListRefreshToken.nilIfBlank,
              let clientId = settings.mdbListClientId.nilIfBlank
        else {
            settings.clearMDBListSession()
            return nil
        }
        switch await MDBListClient.shared.refresh(refreshToken: refreshToken, clientId: clientId) {
        case .renewed(let tokens):
            store(tokens, in: settings)
            return tokens.accessToken
        case .rejected:
            settings.clearMDBListSession()
            return nil
        case .unavailable:
            return nil
        }
    }

    static func store(_ tokens: MDBListClient.Tokens, in settings: TrackingSettingsStore) {
        settings.mdbListAccessToken = tokens.accessToken
        settings.mdbListRefreshToken = tokens.refreshToken
        settings.mdbListTokenExpiry = Date().timeIntervalSince1970 + Double(tokens.expiresIn)
    }

    /// When the stored session is due for renewal, given the clock. Pure, and `nonisolated` so
    /// the margin can be tested without a keychain or a main actor.
    nonisolated static func needsRefresh(expiry: Double, now: Date) -> Bool {
        expiry > 0 && now.timeIntervalSince1970 + refreshMargin >= expiry
    }
}
