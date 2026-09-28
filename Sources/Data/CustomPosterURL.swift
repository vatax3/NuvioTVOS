import Foundation
import SwiftUI

/// Where a custom poster pattern is allowed to replace the addon's own artwork.
///
/// Port of `CustomPosterScreen`. Per-screen rather than one switch because the services these
/// patterns point at are rate-limited and charge per key: a viewer may well want rated posters on
/// Home and the addon's own art everywhere else, and every screen that opts in multiplies the
/// requests. An empty stored set means every screen, which is what an upgrade from a version
/// without the setting has to mean — the alternative silently turns a configured pattern off.
enum CustomPosterScreen: String, CaseIterable, Sendable {
    case home
    case continueWatching = "continue_watching"
    case collections
    case library
    case search
    case details

    var displayName: String {
        switch self {
        case .home: return L10n.text("settings.poster.screen_home", fallback: "Home rows")
        case .continueWatching:
            return L10n.text("settings.poster.screen_continue", fallback: "Continue Watching")
        case .collections: return L10n.text("settings.poster.screen_collections", fallback: "Collections")
        case .library: return L10n.text("settings.poster.screen_library", fallback: "Library")
        case .search: return L10n.text("settings.poster.screen_search", fallback: "Search")
        case .details: return L10n.text("settings.poster.screen_details", fallback: "Detail screen")
        }
    }

    static func from(keys: [String]) -> Set<CustomPosterScreen> {
        guard !keys.isEmpty else { return Set(allCases) }
        return Set(keys.compactMap(CustomPosterScreen.init(rawValue:)))
    }
}

/// Builds a poster URL for a title from a pattern the viewer wrote.
///
/// Port of `CustomPosterUrlResolver`. The feature is artwork from a rating-overlay service —
/// RatingPosterDB and its relatives — in place of the addon's poster, and the whole of it is
/// substituting ids into a URL. What makes it more than `String.replacing` is that **a pattern
/// that cannot be satisfied must produce nothing rather than a broken URL**: a title with no TMDB
/// id must fall back to the addon's own poster, not request `…/movie-.jpg` and draw a placeholder.
/// That is what the required/optional distinction below is for, and it is the only reason this is
/// a type and not two lines at the call site.
///
/// Three placeholder forms, in the order they are resolved:
///
/// - `{imdb_id|tmdb_id}` — the service declares which namespaces it can answer. The first one
///   this title has wins; none of them and the pattern yields nothing, so no request is made for
///   an id the service could not have used anyway.
/// - `{tmdb_id}` — **required**. Absent, the whole pattern yields nothing.
/// - `{tmdb_id?}` — optional. Absent, it resolves to an empty string.
enum CustomPosterURL {
    /// Every id a title might be addressed by, read off the Stremio id plus whatever the metadata
    /// carried separately.
    struct ContentIds: Equatable, Sendable {
        var id: String
        var imdb: String?
        var tmdb: String?
        var tvdb: String?
        var kitsu: String?
        var anilist: String?
        var mal: String?
        var anidb: String?
    }

    /// Services known to accept more than one namespace on the same route, so a title the pattern
    /// cannot address directly is worth a second attempt under another id.
    ///
    /// The list is upstream's, `btttr.cc` included — it was added to it three days before this was
    /// written. Membership is decided by substring because the pattern is a whole URL and these
    /// services are reached through several hosts each.
    static let multiNamespaceDomains = [
        "ratingposterdb.com", "aioratings.com", "top-posters.com", "btttr.cc"
    ]

    // MARK: Reading a Stremio id

    /// Stremio addresses IMDb bare and everything else behind a namespace prefix, so the id is
    /// also the statement of which database it came from.
    static func ids(metaId: String, imdbId: String? = nil) -> ContentIds {
        var result = ContentIds(id: metaId)
        let namespaces: [(String, WritableKeyPath<ContentIds, String?>)] = [
            ("tmdb", \.tmdb), ("tvdb", \.tvdb), ("kitsu", \.kitsu),
            ("anilist", \.anilist), ("mal", \.mal), ("anidb", \.anidb)
        ]
        if metaId.hasPrefix("tt") {
            result.imdb = metaId
        } else {
            for (prefix, path) in namespaces where metaId.hasPrefix("\(prefix):") {
                result[keyPath: path] = String(metaId.dropFirst(prefix.count + 1)).nilIfBlank
                break
            }
        }
        // An explicit id from the metadata outranks the one parsed out of the key: a title listed
        // under `kitsu:` may still carry its IMDb id, and that is the namespace most of these
        // services answer best.
        if let imdbId = imdbId?.nilIfBlank { result.imdb = imdbId }
        return result
    }

    /// The namespace the id itself is written in, and the id with the prefix taken off.
    static func rawIdAndNamespace(_ ids: ContentIds) -> (id: String, namespace: String) {
        if ids.id.hasPrefix("tt") { return (ids.id, "imdb") }
        guard let colon = ids.id.firstIndex(of: ":") else { return (ids.id, "unknown") }
        return (String(ids.id[ids.id.index(after: colon)...]), String(ids.id[..<colon]))
    }

    /// `{typed_id}` — the shape RPDB and aioratings want on a single path segment. IMDb ids are
    /// already unambiguous; a bare TMDB number is not, so it carries the type.
    static func typedId(rawId: String, namespace: String, contentType: String) -> String {
        switch namespace {
        case "imdb": return rawId
        case "tmdb", "tvdb": return "\(contentType == "movie" ? "movie" : "series")-\(rawId)"
        default: return rawId
        }
    }

    // MARK: Resolving

    static func resolve(
        pattern: String,
        ids: ContentIds,
        contentType: String,
        shape: PosterShape = .poster
    ) -> String? {
        guard let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        else { return nil }
        if multiNamespaceDomains.contains(where: pattern.contains) {
            return resolveAcrossNamespaces(
                pattern: pattern, ids: ids, contentType: contentType, shape: shape
            )
        }
        return substitute(pattern: pattern, ids: ids, contentType: contentType, shape: shape)
    }

    private static func lookup(
        _ ids: ContentIds, contentType: String, shape: PosterShape
    ) -> [String: String] {
        let (rawId, namespace) = rawIdAndNamespace(ids)
        return [
            "id": ids.id,
            "id_type": namespace,
            "typed_id": typedId(rawId: rawId, namespace: namespace, contentType: contentType),
            "type": contentType,
            "shape": shape.rawValue,
            "imdb_id": ids.imdb ?? "",
            "tmdb_id": ids.tmdb ?? "",
            "tvdb_id": ids.tvdb ?? "",
            "kitsu_id": ids.kitsu ?? "",
            "anilist_id": ids.anilist ?? "",
            "mal_id": ids.mal ?? "",
            "anidb_id": ids.anidb ?? ""
        ]
    }

    private static func substitute(
        pattern: String, ids: ContentIds, contentType: String, shape: PosterShape
    ) -> String? {
        let values = lookup(ids, contentType: contentType, shape: shape)
        guard var url = resolveAlternatives(in: pattern, values: values) else { return nil }

        for (key, value) in values {
            let optional = "{\(key)?}"
            if url.contains(optional) {
                url = url.replacingOccurrences(of: optional, with: value)
                continue
            }
            let required = "{\(key)}"
            if url.contains(required) {
                // The point of the whole type: a required id this title does not have means the
                // addon's own poster, not a request that will 404.
                guard !value.isEmpty else { return nil }
                url = url.replacingOccurrences(of: required, with: value)
            }
        }
        return url
    }

    /// `{imdb_id|kitsu_id|tvdb_id}` — the namespaces the service accepts, most preferred first.
    private static func resolveAlternatives(
        in pattern: String, values: [String: String]
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\{([a-z_]+(?:\\|[a-z_]+)+)\\}")
        else { return pattern }
        var url = pattern
        let matches = regex.matches(
            in: pattern, range: NSRange(pattern.startIndex..., in: pattern)
        )
        for match in matches {
            guard let token = Range(match.range, in: pattern).map({ String(pattern[$0]) }),
                  let group = Range(match.range(at: 1), in: pattern).map({ String(pattern[$0]) })
            else { continue }
            guard let value = group.split(separator: "|")
                .compactMap({ values[String($0)]?.nilIfBlank })
                .first
            else { return nil }
            url = url.replacingOccurrences(of: token, with: value)
        }
        return url
    }

    /// A second attempt under another namespace, for the services that accept several.
    ///
    /// The pattern names a route as well as a placeholder — `…/imdb/{imdb_id}.jpg` — so swapping
    /// the id means swapping the segment with it, and a TMDB or TVDB id has to arrive in
    /// `{typed_id}` form because that is what these services expect on the path.
    private static func resolveAcrossNamespaces(
        pattern: String, ids: ContentIds, contentType: String, shape: PosterShape
    ) -> String? {
        if let direct = substitute(
            pattern: pattern, ids: ids, contentType: contentType, shape: shape
        ) { return direct }

        let typePrefix = contentType == "movie" ? "movie" : "series"
        /// Ordered by how many of these services answer the namespace at all.
        let order: [(placeholder: String, segment: String, value: String?, typed: Bool)] = [
            ("{imdb_id}", "imdb", ids.imdb, false),
            ("{tmdb_id}", "tmdb", ids.tmdb, true),
            ("{tvdb_id}", "tvdb", ids.tvdb, true)
        ]
        guard let source = order.first(where: { pattern.contains($0.placeholder) }) else {
            return nil
        }

        for candidate in order where candidate.placeholder != source.placeholder {
            guard let value = candidate.value?.nilIfBlank else { continue }
            let replacement = candidate.typed ? "\(typePrefix)-\(value)" : value
            let swapped = pattern
                .replacingOccurrences(of: "/\(source.segment)/", with: "/\(candidate.segment)/")
                // `movie-{tmdb_id}` written out longhand is the same request as `{typed_id}`;
                // replacing the longer form first stops a stray `movie-` being left behind.
                .replacingOccurrences(of: "\(typePrefix)-\(source.placeholder)", with: replacement)
                .replacingOccurrences(of: source.placeholder, with: replacement)
            if let resolved = substitute(
                pattern: swapped, ids: ids, contentType: contentType, shape: shape
            ) { return resolved }
        }
        return nil
    }
}

// MARK: - Applying it

extension MetaPreview {
    /// Swaps in the custom poster, keeping the addon's own in `rawPosterUrl` so a failed load can
    /// fall back to it. Unchanged when the pattern is empty or this title cannot satisfy it.
    ///
    /// Port of `withCustomPosterUrl`. A pattern with no `{shape}` describes portrait art only, so
    /// it leaves landscape and square cards alone rather than stretching a portrait into them.
    func withCustomPoster(pattern: String) -> MetaPreview {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        let supportsShape = pattern.contains("{shape}")
        guard supportsShape || posterShape == .poster else { return self }

        let ids = CustomPosterURL.ids(metaId: id, imdbId: imdbId)
        let resolved = CustomPosterURL.resolve(
            pattern: pattern,
            ids: ids,
            contentType: apiType,
            shape: supportsShape ? posterShape : .poster
        )
        let resolvedLandscape = supportsShape
            ? CustomPosterURL.resolve(
                pattern: pattern, ids: ids, contentType: apiType, shape: .landscape
            )
            : nil
        guard resolved != nil || resolvedLandscape != nil else { return self }

        var copy = self
        copy.rawPosterUrl = rawPosterUrl ?? poster
        if let resolved { copy.poster = resolved }
        if let resolvedLandscape { copy.landscapePoster = resolvedLandscape }
        return copy
    }
}

extension Array where Element == MetaPreview {
    func withCustomPosters(pattern: String) -> [MetaPreview] {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        return map { $0.withCustomPoster(pattern: pattern) }
    }
}

// MARK: - Carrying it to the cards

private struct CustomPosterPatternKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// The pattern the cards on this screen should apply, already gated by
    /// `LayoutSettingsStore.customPosterPattern(for:)`.
    ///
    /// An environment value rather than a parameter on every card because the gate is per
    /// *screen* and the cards are shared: a rail does not know whether it is on Home or in the
    /// library, and it should not have to. The default is empty, so a screen nobody wired keeps
    /// the addon's own artwork — the safe direction for an omission.
    ///
    /// Applied in the card rather than where the list is produced so a change takes effect at
    /// once. That costs nothing in the common case: `withCustomPoster` returns on an empty
    /// pattern before it looks at anything, and that is what every viewer who has not configured
    /// one has. Whoever has configured one is already paying a network fetch per poster.
    var customPosterPattern: String {
        get { self[CustomPosterPatternKey.self] }
        set { self[CustomPosterPatternKey.self] = newValue }
    }
}

extension View {
    /// Gates the custom poster pattern to one screen's cards.
    func customPosterScreen(_ screen: CustomPosterScreen, settings: AppSettings) -> some View {
        environment(\.customPosterPattern, settings.layout.customPosterPattern(for: screen))
    }
}
