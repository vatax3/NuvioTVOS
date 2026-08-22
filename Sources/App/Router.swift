import SwiftUI
import Observation

// MARK: - Root destinations (port of the drawer routes in MainActivity)

enum RootTab: String, CaseIterable, Identifiable, Hashable {
    case home, discover, search, library, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L10n.text("navigation.home")
        case .discover: return L10n.text("navigation.discover")
        case .search: return L10n.text("navigation.search")
        case .library: return L10n.text("navigation.library")
        case .settings: return L10n.text("navigation.settings")
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

    /// The ids this video can be asked for, most specific first.
    ///
    /// Catalogs disagree about identity: Cinemeta hands out `tt…`, the TMDB addons hand out
    /// `tmdb:…`. Stream addons almost all declare `idPrefixes: ["tt"]`, so a title opened from a
    /// TMDB catalog would reach none of them. Offering the IMDb form as an alternative is what
    /// makes the same addon set work from either catalog.
    var streamIdCandidates: [String] {
        var candidates = [videoId]
        if let imdbId, !imdbId.isEmpty, !videoId.hasPrefix(imdbId) {
            if let season, let episode {
                candidates.append("\(imdbId):\(season):\(episode)")
            } else {
                candidates.append(imdbId)
            }
        }
        return candidates
    }
}

/// A resolved source handed to the player.
struct PlaybackRequest: Hashable, Identifiable {
    var streamURL: String
    var title: String
    var subtitleLine: String?
    var streamName: String?
    /// `behaviorHints.filename` when the addon supplies it. Debrid links routinely carry no
    /// extension, so this is often the only place the container is visible before playback.
    var filename: String?
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
    /// Originating source request. Retaining it lets the player reopen the source picker,
    /// matching Android TV's in-player Sources side panel without rebuilding title metadata.
    var sourceRequest: StreamRequest? = nil
    /// Source presentation is retained for the in-player Stream info panel, mirroring Android
    /// TV's diagnostic overlay without forcing the viewer back to the stream list.
    var sourceAddonName: String? = nil
    var sourceAddonLogo: String? = nil
    var sourceDescription: String? = nil
    var sourceHints: [String] = []
    /// The stable stream identity is retained independently from its display name.  Several
    /// providers publish identically named releases; matching a current source by label makes
    /// the wrong row look selected and can focus the wrong replacement stream.
    var sourceStableKey: String? = nil
    /// `behaviorHints.bingeGroup`: the addon's own marker for "same release, same encode, next
    /// episode". Carried into playback so auto-advance can pick the matching source next time
    /// instead of starting the choice over.
    var sourceBingeGroup: String? = nil

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
/// Which folder of which collection to open. Identified rather than passed whole so a folder
/// edited while its screen is open reads the current version from the store.
struct CollectionFolderRequest: Hashable, Identifiable {
    var collectionId: String
    var folderId: String

    var id: String { "\(collectionId)#\(folderId)" }
}

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
    case collectionFolder(CollectionFolderRequest)
    case comments(CommentsRequest)
    case qrSignIn
    case addonManager
    case pluginManager
    case collectionManager
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

    /// True while an XCUITest drives the app. Set by the player harness flag, and by an explicit
    /// one for tests that do not use the harness — a fresh test container is indistinguishable
    /// from a first install, so anything gated on "first install" has to know.
    static var isUITesting: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-nuvioPlayerHarness") || arguments.contains("-nuvioUITesting")
        #else
        false
        #endif
    }

    private static func value(for flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
