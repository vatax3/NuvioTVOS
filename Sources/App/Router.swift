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

    /// TMDB-sourced rows use a `tmdb:<id>` id; the detail model swaps it for an IMDb id before
    /// asking any addon.
    var tmdbId: Int? {
        guard itemId.hasPrefix("tmdb:") else { return nil }
        return Int(itemId.dropFirst("tmdb:".count))
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
    var imdbId: String?
    /// Video id of the following episode, so the player can chain without re-resolving meta.
    var nextUpVideoId: String?

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
    /// Populated for series so auto-play can chain straight into the next episode.
    var nextUp: StreamRequest?
    /// IMDb id, used for Trakt scrobbling.
    var imdbId: String?
    /// External tracks gathered from every addon advertising `subtitles` for this video.
    var subtitles: [Subtitle] = []

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

/// A TMDB person, opened from the cast rail.
struct CastRequest: Hashable, Identifiable {
    var tmdbId: Int
    var name: String
    var photo: String?
    var id: String { "person-\(tmdbId)" }
}

/// A TMDB network / studio / genre listing.
struct TMDBBrowseRequest: Hashable, Identifiable {
    enum Entity: Hashable {
        case network(Int)
        case company(Int)
        case genre(Int)
    }

    var entity: Entity
    var title: String
    var contentType: String
    var logo: String?

    var id: String { "\(entity)-\(contentType)" }
}

/// Trakt comments for one title.
struct CommentsRequest: Hashable, Identifiable {
    var imdbId: String
    var contentType: String
    var title: String
    var id: String { "comments-\(imdbId)" }
}

enum Route: Hashable {
    case detail(DetailRequest)
    case streams(StreamRequest)
    case catalogSeeAll(CatalogRequest)
    case castMember(CastRequest)
    case tmdbBrowse(TMDBBrowseRequest)
    case comments(CommentsRequest)
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
    var selectedTab: RootTab = LaunchArguments.startTab ?? .home
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


// MARK: - Launch arguments

/// Debug-only entry points so a screenshot pass can land on a given screen without having to
/// drive the focus engine from a script. Stripped from release builds.
enum LaunchArguments {
    static var startTab: RootTab? {
        #if DEBUG
        value(for: "-startTab").flatMap { RootTab(rawValue: $0) }
        #else
        nil
        #endif
    }

    static var settingsSection: String? {
        #if DEBUG
        value(for: "-settingsSection")
        #else
        nil
        #endif
    }

    private static func value(for flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
