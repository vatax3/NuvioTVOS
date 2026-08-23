import UIKit

/// Trailers in the Stremio protocol are YouTube ids, and tvOS has no in-app way to play one:
/// AVPlayer cannot resolve a YouTube watch page and WKWebView does not exist on the platform.
/// The workable path is a hand-off to the YouTube tvOS app, which is what the button does.
enum TrailerLauncher {
    /// True when the YouTube app is installed and can take the hand-off.
    @MainActor
    static var isAvailable: Bool {
        guard let probe = URL(string: "youtube://") else { return false }
        return UIApplication.shared.canOpenURL(probe)
    }

    /// The bare video id, whatever shape the addon put it in.
    ///
    /// `trailers[].source` is documented as the id alone, and plenty of addons put a watch URL,
    /// a `youtu.be` short link or an embed path there instead. Passing one of those on as if it
    /// were an id builds a nonsense URL, and it is also what the thumbnail path is interpolated
    /// into — so the same malformed value breaks the artwork and the hand-off together.
    nonisolated static func videoId(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Not a URL: the documented case, and the common one.
        guard trimmed.contains("/") || trimmed.contains("?") else { return trimmed }

        guard let components = URLComponents(string: trimmed) else { return nil }
        if let v = components.queryItems?.first(where: { $0.name == "v" })?.value?.nilIfBlank {
            return v
        }
        // youtu.be/<id>, /embed/<id>, /v/<id>, /shorts/<id> — in each the id is the last segment.
        let segments = components.path.split(separator: "/").map(String.init)
        return segments.last?.nilIfBlank
    }

    /// The hand-off URL for a video id.
    ///
    /// `youtube://<id>` opens the app and plays nothing, which is what it had been doing: with
    /// no path, the id lands in the URL's *host* and the app has no watch request to act on, so
    /// it falls through to its own home screen. The app parses a full watch URL under its own
    /// scheme, so the id has to travel as the `v` query item exactly as it would on the web.
    ///
    /// `canOpenURL` cannot tell these apart — it answers for the scheme and never looks at the
    /// rest — so there is no fallback to try afterwards and no failure to detect. The form has
    /// to be right the first time.
    nonisolated static func handoffURL(youTubeId: String) -> URL? {
        guard let id = videoId(from: youTubeId) else { return nil }
        var components = URLComponents()
        components.scheme = "youtube"
        components.host = "www.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: id)]
        return components.url
    }

    @MainActor
    static func open(youTubeId: String) {
        guard let url = handoffURL(youTubeId: youTubeId),
              UIApplication.shared.canOpenURL(url)
        else { return }
        UIApplication.shared.open(url)
    }
}
