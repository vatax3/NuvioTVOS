import SwiftUI
import Observation

// MARK: - Root destinations (port of the drawer routes in MainActivity)

enum RootTab: String, CaseIterable, Identifiable, Hashable {
    case home, discover, search, library, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .discover: return "Discover"
        case .search: return "Search"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .discover: return "square.grid.2x2.fill"
        case .search: return "magnifyingglass"
        case .library: return "bookmark.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Payloads

struct DetailRequest: Hashable, Identifiable {
    var itemId: String
    var itemType: String
    var addonBaseUrl: String?
    var heroBackdropUrl: String?
    var id: String { "\(itemType)|\(itemId)" }

    init(preview: MetaPreview) {
        itemId = preview.id
        itemType = preview.apiType
        addonBaseUrl = preview.sourceAddonBaseUrl
        heroBackdropUrl = preview.backdropUrl
    }

    init(itemId: String, itemType: String, addonBaseUrl: String? = nil, heroBackdropUrl: String? = nil) {
        self.itemId = itemId
        self.itemType = itemType
        self.addonBaseUrl = addonBaseUrl
        self.heroBackdropUrl = heroBackdropUrl
    }
}

/// Everything the stream picker needs to resolve sources for one playable video.
struct StreamRequest: Hashable, Identifiable {
    var videoId: String
    var contentType: String
    var title: String
    var contentId: String
    var contentName: String?
    var poster: String?
    var backdrop: String?
    var logo: String?
    var season: Int?
    var episode: Int?
    var episodeName: String?
    var year: String?
    var runtime: Int?

    var id: String { videoId }

    var episodeLabel: String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }
}

/// A resolved source handed to the player.
struct PlaybackRequest: Hashable, Identifiable {
    var streamURL: String
    var title: String
    var subtitleLine: String?
    var streamName: String?
    var headers: [String: String]
    var contentId: String
    var contentType: String
    var videoId: String
    var season: Int?
    var episode: Int?
    var poster: String?
    var backdrop: String?
    var logo: String?
    var startFromBeginning: Bool
    var preview: MetaPreview?

    var id: String { "\(videoId)|\(streamURL)" }
}

struct CatalogRequest: Hashable, Identifiable {
    var addonBaseUrl: String
    var catalogId: String
    var type: String
    var title: String
    var genre: String?
    var id: String { "\(addonBaseUrl)|\(type)|\(catalogId)|\(genre ?? "")" }
}

// MARK: - Pushed routes

enum Route: Hashable {
    case detail(DetailRequest)
    case streams(StreamRequest)
    case catalogSeeAll(CatalogRequest)
    case addonManager
    case catalogOrder
    case themeSettings
    case layoutSettings
    case playbackSettings
    case about
}

// MARK: - Router

@Observable
@MainActor
final class Router {
    var selectedTab: RootTab = .home
    var path: [Route] = []
    /// False while the content region has no focusable view of its own (Home's initial
    /// spinner). The sidebar opts out of focus during that window, otherwise it is the only
    /// focus candidate on screen and the panel blooms open on launch — Android starts with
    /// the pill collapsed and the first poster focused.
    var contentHasFocusableViews = true
    /// Presented as a full-screen cover so playback owns the whole display, the way the
    /// Android player activity does.
    var playback: PlaybackRequest?

    func push(_ route: Route) { path.append(route) }

    func openDetail(_ preview: MetaPreview) {
        push(.detail(DetailRequest(preview: preview)))
    }

    func openStreams(_ request: StreamRequest) {
        push(.streams(request))
    }

    func play(_ request: PlaybackRequest) {
        playback = request
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToRoot() { path.removeAll() }

    func select(_ tab: RootTab) {
        if selectedTab == tab {
            popToRoot()
        } else {
            selectedTab = tab
            path.removeAll()
        }
    }
}
