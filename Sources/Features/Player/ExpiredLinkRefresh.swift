import Foundation

/// Fetching a source again when its link has likely expired — upstream's
/// `PlayerRuntimeControllerExpiredLinkRefresh` and `PlaybackUrlCredentials` (1.2.0-beta.1).
///
/// Two links are refreshed rather than retried: one reopened from the reuse-last-link cache, which
/// may have expired since it was saved, and one whose URL carries expiring credentials, which can
/// be stale when picked from cached results or expire during playback. Retrying the same URL could
/// only fail the same way.
enum ExpiredLinkRefresh {
    static let pollCount = 30
    static let pollInterval: Duration = .milliseconds(500)

    private static let credentialQueryKeys: Set<String> = [
        "accesskey", "accesssignature", "accesssig", "access_token", "accesstoken", "auth",
        "authkey", "authsig", "authsignature", "auth_token", "authtoken", "e", "exp",
        "expiration", "expire", "expires", "expiresat", "expiresin", "expires_in", "expiry",
        "hmac", "jwt", "keypairid", "policy", "sig", "signature", "signed", "st", "t", "token"
    ]
    private static let credentialKeyFragments = ["token", "signature", "expires", "expiry"]

    /// `hasLikelyExpiringPlaybackCredentials`: the query carries a key that usually holds a
    /// signed or expiring credential.
    static func hasLikelyExpiringCredentials(_ url: String) -> Bool {
        guard let questionMark = url.firstIndex(of: "?") else { return false }
        let query = url[url.index(after: questionMark)...].split(separator: "#", maxSplits: 1).first ?? ""
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return query.split(whereSeparator: { $0 == "&" || $0 == ";" }).contains { parameter in
            guard let equals = parameter.firstIndex(of: "=") else { return false }
            let rawKey = parameter[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard !rawKey.isEmpty else { return false }
            let compactKey = rawKey.replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".", with: "")
            return credentialQueryKeys.contains(rawKey) || credentialQueryKeys.contains(compactKey)
                || credentialKeyFragments.contains { rawKey.contains($0) || compactKey.contains($0) }
        }
    }

    /// What is known about the source behind the failed link, to find it among fresh results.
    struct Identity: Equatable {
        var addonName: String?
        var streamName: String?
        var infoHash: String?
        var filename: String?
        var bingeGroup: String?
    }

    /// `findCachedSourceRefreshCandidate`: the best match from the same addon that has a fresh
    /// link or can be resolved into one.
    static func candidate(in streams: [Stream], failedURL: String, expected: Identity) -> Stream? {
        guard let addonName = expected.addonName?.nilIfBlank else { return nil }
        var best: (score: Int, stream: Stream)?
        for stream in streams where stream.addonName == addonName {
            let url = stream.streamURL()
            let hasFreshURL = url.map { !$0.isEmpty && $0 != failedURL } ?? false
            let canResolve = url == nil && stream.isTorrent
            guard hasFreshURL || canResolve else { continue }

            var score = 100
            if let hash = expected.infoHash?.nilIfBlank,
               stream.effectiveInfoHash?.caseInsensitiveCompare(hash) == .orderedSame {
                score += 60
            }
            let name = stream.name?.nilIfBlank ?? stream.addonName
            if let expectedName = expected.streamName?.nilIfBlank, name == expectedName { score += 40 }
            if let filename = expected.filename?.nilIfBlank, stream.behaviorHints?.filename == filename { score += 30 }
            if let group = expected.bingeGroup?.nilIfBlank, stream.behaviorHints?.bingeGroup == group { score += 20 }
            if let url, hasLikelyExpiringCredentials(url) { score += 5 }
            if best.map({ score > $0.score }) ?? true { best = (score, stream) }
        }
        return best?.stream
    }
}
