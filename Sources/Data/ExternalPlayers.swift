import Foundation
import UIKit

/// Third-party tvOS players Nuvio can hand a stream to.
///
/// This is the practical answer to AVFoundation's container coverage: Infuse, VLC and the others
/// bring their own demuxers, so an MKV that the system player refuses opens fine in them.
///
/// The trade-off is real and worth knowing: a hand-off carries only a URL. Per-stream request
/// headers cannot travel with it, so a debrid link that needs an `Authorization` or `Referer`
/// header will fail in an external player even though it plays internally. Nuvio says so at the
/// point of choice rather than letting it fail silently.
enum ExternalPlayer: String, CaseIterable, Identifiable, Codable, Sendable {
    case infuse
    case vlc
    case nplayer
    case outplayer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .infuse: return "Infuse"
        case .vlc: return "VLC"
        case .nplayer: return "nPlayer"
        case .outplayer: return "Outplayer"
        }
    }

    var summary: String {
        switch self {
        case .infuse: return "Broad container and codec support, Firecore"
        case .vlc: return "Plays essentially anything, VideoLAN"
        case .nplayer: return "Hardware-accelerated, wide format support"
        case .outplayer: return "Lightweight MKV-capable player"
        }
    }

    /// Scheme probed with `canOpenURL`, and declared in `LSApplicationQueriesSchemes`.
    var probeScheme: String {
        switch self {
        case .infuse: return "infuse"
        case .vlc: return "vlc-x-callback"
        case .nplayer: return "nplayer"
        case .outplayer: return "outplayer"
        }
    }

    /// Whether this player accepts a sidecar subtitle URL on its callback. nPlayer and Outplayer
    /// take a bare stream URL and nothing else, so a track cannot travel with the hand-off.
    var acceptsSubtitleURL: Bool {
        switch self {
        case .infuse, .vlc: return true
        case .nplayer, .outplayer: return false
        }
    }

    /// Builds the hand-off URL. Infuse and VLC take an x-callback-url with the stream as a query
    /// parameter; nPlayer and Outplayer concatenate the stream onto their scheme directly.
    ///
    /// `subtitleURL` is the addon track the viewer had selected, forwarded when
    /// `external_player_forward_subtitles` is on. Without it the hand-off silently drops the
    /// subtitles — the external player only sees the video URL and has no idea a track was chosen.
    func playbackURL(for stream: String, title: String?, subtitleURL: String? = nil) -> URL? {
        guard let encoded = stream.addingPercentEncoding(
            withAllowedCharacters: .externalPlayerArgument
        ) else { return nil }
        let encodedSubtitle = subtitleURL?.nilIfBlank?.addingPercentEncoding(
            withAllowedCharacters: .externalPlayerArgument
        )

        switch self {
        case .infuse:
            var string = "infuse://x-callback-url/play?url=\(encoded)"
            if let title, let encodedTitle = title.addingPercentEncoding(
                withAllowedCharacters: .externalPlayerArgument
            ) {
                string += "&name=\(encodedTitle)"
            }
            if let encodedSubtitle { string += "&sub=\(encodedSubtitle)" }
            return URL(string: string)
        case .vlc:
            var string = "vlc-x-callback://x-callback-url/stream?url=\(encoded)"
            if let encodedSubtitle { string += "&sub=\(encodedSubtitle)" }
            return URL(string: string)
        case .nplayer:
            // nPlayer takes the raw URL appended to its scheme, not percent-encoded.
            return URL(string: "nplayer-\(stream)")
        case .outplayer:
            return URL(string: "outplayer://\(stream)")
        }
    }
}

extension CharacterSet {
    /// Everything that must survive as data inside a query parameter — notably `&`, `?` and `=`,
    /// which appear in debrid and CDN links and would otherwise split the callback URL.
    static let externalPlayerArgument: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

@MainActor
enum ExternalPlayerLauncher {
    /// Players actually installed on this device. An uninstalled player is never offered, so the
    /// list is short and every entry works.
    static var installed: [ExternalPlayer] {
        ExternalPlayer.allCases.filter { isInstalled($0) }
    }

    static func isInstalled(_ player: ExternalPlayer) -> Bool {
        guard let probe = URL(string: "\(player.probeScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(probe)
    }

    @discardableResult
    static func open(
        _ player: ExternalPlayer,
        stream: String,
        title: String?,
        subtitleURL: String? = nil
    ) -> Bool {
        guard let url = player.playbackURL(for: stream, title: title, subtitleURL: subtitleURL),
              UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }
}
