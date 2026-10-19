import Foundation

// MARK: - Identity

/// Who this device is, in a party.
///
/// The display name and avatar are the profile's, so a party shows the household's own names
/// rather than device ids. The device id is what the backend keys membership on.
struct PartyIdentity: Equatable, Sendable {
    var deviceId: String
    var displayName: String
    var avatarUrl: String?
    var avatarColor: String?
}

// MARK: - What is being watched

/// The source of what the party is watching, as much of it as is worth sharing.
///
/// Deliberately not a whole `Stream`: this travels through a database and is read by other
/// people's devices, so it carries what identifies a release and nothing that identifies an
/// account.
struct PartySource: Codable, Equatable, Sendable {
    var infoHash: String?
    var fileIdx: Int?
    var filename: String?
    var videoSize: Int64?
    var bingeGroup: String?
    var addonId: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case infoHash = "info_hash"
        case fileIdx = "file_idx"
        case filename
        case videoSize = "video_size"
        case bingeGroup = "binge_group"
        case addonId = "addon_id"
        case name
    }
}

struct PartyMedia: Codable, Equatable, Sendable {
    var type: String
    var metaId: String
    var metaType: String
    var videoId: String?
    var season: Int?
    var episode: Int?
    var title: String = ""
    var episodeTitle: String?
    var description: String?
    var poster: String?
    var background: String?
    var logo: String?
    var source: PartySource?

    enum CodingKeys: String, CodingKey {
        case type
        case metaId = "meta_id"
        case metaType = "meta_type"
        case videoId = "video_id"
        case season, episode, title
        case episodeTitle = "episode_title"
        case description, poster, background, logo, source
    }

    /// Identifies *what* is playing, so a member who has moved to the next episode can be told
    /// apart from one still on this one. Everything that follows position is keyed on it.
    var key: String { PartyMedia.key(type: metaType, id: metaId, season: season, episode: episode) }

    static func key(type: String, id: String, season: Int?, episode: Int?) -> String {
        [
            type.lowercased(), id,
            season.map(String.init) ?? "", episode.map(String.init) ?? ""
        ].joined(separator: "|")
    }
}

/// A playable link shared into the party.
///
/// **This is the privacy-relevant one and it is stated rather than implied.** For us the URL is
/// usually a debrid link tied to the host's own account, so sharing it means the other members
/// stream through that account. Upstream shares it the same way; what we add is saying so in the
/// interface before anybody presses anything.
struct PartyStream: Codable, Equatable, Sendable {
    var mediaKey: String
    var url: String
    var headers: [String: String] = [:]
    var responseHeaders: [String: String] = [:]
    var name: String?
    var description: String?
    var addonName: String = ""
    var addonId: String = ""
    var addonLogo: String?
    var filename: String?
    var videoSize: Int64?
    var bingeGroup: String?
    var streamType: String?

    enum CodingKeys: String, CodingKey {
        case mediaKey = "media_key"
        case url, headers
        case responseHeaders = "response_headers"
        case name, description
        case addonName = "addon_name"
        case addonId = "addon_id"
        case addonLogo = "addon_logo"
        case filename
        case videoSize = "video_size"
        case bingeGroup = "binge_group"
        case streamType = "stream_type"
    }

    /// A URL worth sharing: reachable from another device. A loopback address is the host's own
    /// machine and means nothing to anybody else.
    static func isShareable(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased(),
              let scheme = URL(string: url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        if host == "localhost" || host == "::1" { return false }
        return !host.hasPrefix("127.") && !host.hasPrefix("0.0.0.0")
    }

    func asStream() -> Stream {
        Stream(
            name: name, title: nil, description: description, url: url,
            ytId: nil, infoHash: nil, fileIdx: nil, externalUrl: nil,
            behaviorHints: StreamBehaviorHints(
                bingeGroup: bingeGroup,
                proxyHeaders: ProxyHeaders(request: headers, response: responseHeaders),
                videoSize: videoSize,
                filename: filename
            ),
            addonName: addonName, addonLogo: addonLogo, sources: nil, quality: nil
        )
    }
}

// MARK: - Playback state on the wire

/// One device's claim about where playback is.
///
/// `at` is the **server's** clock, not ours — which is the whole reason `watch_party_clock`
/// exists. Two televisions in one house can be seconds apart, and a position timestamped against
/// a local clock would be corrected by exactly that error on arrival.
struct PartyPlayback: Codable, Equatable, Sendable {
    var seq: Int64
    var memberId: String?
    var paused: Bool
    var positionMs: Int64
    var rate: Double = 1
    var at: Int64
    var mediaKey: String?
    var waiting: Bool = false

    enum CodingKeys: String, CodingKey {
        case seq
        case memberId = "member_id"
        case paused
        case positionMs = "position_ms"
        case rate, at
        case mediaKey = "media_key"
        case waiting
    }
}

struct PartyMember: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var avatarUrl: String?
    var avatarColor: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case avatarColor = "avatar_color"
    }
}

enum PartyMemberStatus: String, Codable, Equatable, Sendable {
    case browsing, loading, buffering, ready, behind
}

/// What a member is doing right now, carried over the realtime channel's presence rather than
/// the database — it changes several times a minute and is worthless once stale.
struct PartyPresence: Codable, Equatable, Sendable {
    var memberId: String
    var status: PartyMemberStatus = .browsing
    var mediaKey: String?
    var behindMs: Int64?

    enum CodingKeys: String, CodingKey {
        case memberId = "member_id"
        case status
        case mediaKey = "media_key"
        case behindMs = "behind_ms"
    }
}

// MARK: - What the backend answers

struct PartyInfo: Codable, Equatable, Sendable {
    var id: String
    var code: String
    var hostMemberId: String?
    var hostOnly: Bool = false
    var media: PartyMedia
    var playback: PartyPlayback?
    var maxMembers: Int = 3

    enum CodingKeys: String, CodingKey {
        case id, code
        case hostMemberId = "host_member_id"
        case hostOnly = "host_only"
        case media, playback
        case maxMembers = "max_members"
    }
}

struct PartySnapshot: Codable, Sendable {
    var party: PartyInfo?
    var members: [PartyMember] = []
    var memberId: String?
    var serverTimeMs: Int64?
    var error: String?
    var ok: Bool?

    enum CodingKeys: String, CodingKey {
        case party, members
        case memberId = "member_id"
        case serverTimeMs = "server_time_ms"
        case error, ok
    }
}

struct PartyPreview: Codable, Sendable {
    var media: PartyMedia?
    var host: PartyMember?
    var members: Int = 0
    var maxMembers: Int = 0
    var error: String?

    enum CodingKeys: String, CodingKey {
        case media, host, members
        case maxMembers = "max_members"
        case error
    }

    var isFull: Bool { maxMembers >= 1 && members >= maxMembers }
}

// MARK: - Failures

enum PartyError: Error, Equatable, Sendable {
    case notFound
    case full
    case removed
    case ended
    case rateLimited
    case signInRequired
    case unavailable
    case network

    /// The backend's own error strings, mapped once. An unrecognised code reads as a network
    /// problem rather than as success, because the alternative is a party that looks joined and
    /// is not.
    static func from(_ code: String?) -> PartyError? {
        switch code {
        case nil: return nil
        case "party_not_found": return .notFound
        case "party_full": return .full
        case "removed", "not_member": return .removed
        case "party_ended": return .ended
        case "rate_limited": return .rateLimited
        case "unavailable": return .unavailable
        default: return .network
        }
    }

    var message: String {
        switch self {
        case .notFound:
            return L10n.text("party.error_not_found", fallback: "No party with that code.")
        case .full:
            return L10n.text("party.error_full", fallback: "That party is full.")
        case .removed:
            return L10n.text("party.error_removed", fallback: "You are no longer in this party.")
        case .ended:
            return L10n.text("party.error_ended", fallback: "The party has ended.")
        case .rateLimited:
            return L10n.text("party.error_rate_limited", fallback: "Too many attempts. Wait a moment.")
        case .signInRequired:
            return L10n.text(
                "party.error_sign_in", fallback: "Sign in to your Nuvio account to watch together."
            )
        case .unavailable:
            return L10n.text(
                "party.error_unavailable", fallback: "Watch parties are unavailable right now."
            )
        case .network:
            return L10n.text("party.error_network", fallback: "Could not reach the party.")
        }
    }
}

// MARK: - What a screen sees

/// A party, as the interface needs it.
struct ActiveParty: Equatable, Sendable {
    var id: String
    var code: String
    var memberId: String
    var hostMemberId: String?
    var members: [PartyMember] = []
    var presence: [String: PartyPresence] = [:]
    var media: PartyMedia
    var maxMembers: Int = 3
    var isConnected = false
    var hostOnly = false
    /// Whether this device — the host — is offering its resolved link to the others.
    ///
    /// Local to the host and deliberately **off by default**: the link is usually a debrid one
    /// tied to their own account, so the party streaming through it is a choice rather than a
    /// consequence. Upstream keeps it the same way, outside the party record entirely.
    var isSharing = false

    var isHost: Bool { memberId == hostMemberId }

    /// Whether this device may drive playback. With *host only* on, everyone else watches.
    var canControl: Bool { !hostOnly || isHost }

    func member(_ id: String?) -> PartyMember? { members.first { $0.id == id } }

    var inviteLink: String { "nuvio://party/\(code)" }
}

/// Something that happened in the party and is worth one line on screen.
enum PartyEvent: Equatable, Sendable {
    case memberJoined(String)
    case memberLeft(String)
    case removed
    case ended
    case mediaChanged(PartyMedia)
    case controlChanged(hostOnly: Bool)
}

enum PartyAction: String, Equatable, Sendable {
    case paused, resumed, seeked, speed
}

/// "Alex paused" — attributed, because an unexplained jump in someone else's hands is the most
/// confusing thing a shared session can do.
struct PartyNotice: Equatable, Sendable {
    var name: String
    var action: PartyAction
    var positionMs: Int64
    var rate: Double
}
