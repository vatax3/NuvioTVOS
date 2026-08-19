import Foundation

/// App-internal links used by Top Shelf, notifications and external hand-off.
///
/// The parser is intentionally independent from SwiftUI so every entry point performs the same
/// validation and it can be covered by unit tests.  Links never contain a playable URL or an
/// account token; opening one always returns through the normal addon/source resolver.
enum DeepLink: Equatable {
    case tab(RootTab)
    case detail(DetailRequest)
    case streams(StreamRequest)

    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "nuvio" else { return nil }
        let host = url.host?.lowercased()
        let components = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first(where: { $0.name == name })?.value?.nilIfBlank }

        switch host {
        case "home", "discover", "search", "library", "settings":
            return host.flatMap(RootTab.init(rawValue:)).map(DeepLink.tab)

        case "detail":
            guard components.count >= 2 else { return nil }
            let type = ContentType.from(components[0]).apiString(fallback: components[0])
            let id = components[1].nilIfBlank
            guard let id else { return nil }
            return .detail(DetailRequest(
                itemId: id,
                itemType: type,
                addonBaseUrl: value("addon"),
                heroBackdropUrl: value("backdrop")
            ))

        case "streams", "play":
            guard components.count >= 2 else { return nil }
            let type = ContentType.from(components[0]).apiString(fallback: components[0])
            let id = components[1].nilIfBlank
            guard let id else { return nil }
            let season = value("season").flatMap(Int.init)
            let episode = value("episode").flatMap(Int.init)
            let title = value("title") ?? ""
            return .streams(StreamRequest(
                videoId: value("video") ?? id,
                contentType: type,
                title: title,
                contentId: id,
                contentName: title.nilIfBlank,
                poster: value("poster"),
                backdrop: value("backdrop"),
                logo: nil,
                season: season,
                episode: episode,
                episodeName: value("episodeName"),
                year: nil,
                runtime: nil,
                imdbId: value("imdb") ?? (id.hasPrefix("tt") ? id : nil),
                nextUpVideoId: nil
            ))

        default:
            return nil
        }
    }
}

extension Router {
    /// Opens a deeplink as a fresh top-level navigation flow.  Clearing any old path prevents
    /// a Top Shelf selection from being stacked on a detail page that happened to be open when
    /// the app was last suspended.
    func open(_ deepLink: DeepLink) {
        playback = nil
        path.removeAll()
        switch deepLink {
        case .tab(let tab):
            selectedTab = tab
        case .detail(let request):
            selectedTab = .home
            push(.detail(request))
        case .streams(let request):
            selectedTab = .home
            push(.streams(request))
        }
    }
}
