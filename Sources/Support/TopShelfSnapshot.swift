import Foundation

/// The small, privacy-safe bridge between the app and the separate Top Shelf extension.
/// Extensions do not share the app's process or its normal container, so only this minimal
/// snapshot is copied into the app-group defaults.  Stream URLs and authentication are never
/// exported; a Top Shelf action comes back through `nuvio://` and resolves normally.
enum TopShelfSnapshotPublisher {
    static let appGroupIdentifier = "group.com.nuvio.tvos"
    static let defaultsKey = "topshelf.snapshot.v1"

    struct Snapshot: Codable, Hashable {
        var entries: [Entry]
    }

    struct Entry: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var subtitle: String?
        var artworkURL: String?
        var detailURL: String
        var playURL: String
    }

    static func publish(progress: [String: WatchProgress], previews: [String: MetaPreview]) {
        let ordered = progress.values
            .filter { $0.fraction > 0.01 && $0.fraction < 0.9 }
            .sorted { $0.updatedAt > $1.updatedAt }

        var seen = Set<String>()
        let entries = ordered.compactMap { progress -> Entry? in
            let previewKey = "\(progress.contentType)|\(progress.contentId)"
            guard !seen.contains(previewKey), let preview = previews[previewKey] else { return nil }
            seen.insert(previewKey)
            return entry(preview: preview, progress: progress)
        }
        save(Snapshot(entries: Array(entries.prefix(12))))
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    private static func entry(preview: MetaPreview, progress: WatchProgress) -> Entry {
        let type = preview.apiType
        let id = preview.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? preview.id
        var detail = URLComponents(string: "nuvio://detail/\(type)/\(id)")!
        var play = URLComponents(string: "nuvio://streams/\(type)/\(id)")!
        let title = progress.season.flatMap { season in
            progress.episode.map { String(format: "S%02dE%02d", season, $0) }
        }
        detail.queryItems = [
            URLQueryItem(name: "addon", value: preview.sourceAddonBaseUrl),
            URLQueryItem(name: "backdrop", value: preview.background)
        ].compactMap { $0.value?.nilIfBlank == nil ? nil : $0 }
        play.queryItems = [
            URLQueryItem(name: "title", value: preview.name),
            URLQueryItem(name: "video", value: progress.videoId),
            URLQueryItem(name: "season", value: progress.season.map(String.init)),
            URLQueryItem(name: "episode", value: progress.episode.map(String.init)),
            URLQueryItem(name: "imdb", value: preview.imdbId)
        ].compactMap { $0.value?.nilIfBlank == nil ? nil : $0 }

        return Entry(
            id: progress.videoId,
            title: preview.name,
            subtitle: title ?? L10n.text("topshelf.continue_watching"),
            artworkURL: progress.season == nil ? preview.landscapePoster ?? preview.background ?? preview.poster : preview.poster,
            detailURL: detail.url!.absoluteString,
            playURL: play.url!.absoluteString
        )
    }
}
