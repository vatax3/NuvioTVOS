import Foundation
import TVServices

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

    /// - Parameter threshold: the watched threshold, so the shelf lists what Continue Watching
    ///   lists. A fixed 0.9 left titles between 90% and the viewer's threshold off the shelf.
    static func publish(progress: [String: WatchProgress], previews: [String: MetaPreview], threshold: Double) {
        save(snapshot(progress: progress, previews: previews, threshold: threshold))
    }

    /// - Parameter threshold: the watched threshold, so the shelf lists what Continue Watching
    ///   lists. A fixed 0.9 left titles between 90% and the viewer's threshold off the shelf.
    static func snapshot(progress: [String: WatchProgress], previews: [String: MetaPreview], threshold: Double) -> Snapshot {
        let ordered = progress.values
            .filter { $0.isInProgress(threshold: threshold) }
            .sorted { $0.updatedAt > $1.updatedAt }

        var seen = Set<String>()
        let entries = ordered.compactMap { progress -> Entry? in
            let previewKey = "\(progress.contentType)|\(progress.contentId)"
            guard !seen.contains(previewKey), let preview = previews[previewKey] else { return nil }
            seen.insert(previewKey)
            return entry(preview: preview, progress: progress)
        }
        return Snapshot(entries: Array(entries.prefix(12)))
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot),
              defaults.data(forKey: defaultsKey) != data
        else { return }
        defaults.set(data, forKey: defaultsKey)
        announceChange()
    }

    /// tvOS reads the extension when it decides to, which can be long after the row changed; the
    /// Android launcher channel had the same gap until upstream refreshed it on each change
    /// (02a9afc85). Debounced, because one finished episode saves several times.
    @MainActor private static var pendingAnnouncement: Task<Void, Never>?

    private static func announceChange() {
        Task { @MainActor in
            pendingAnnouncement?.cancel()
            pendingAnnouncement = Task {
                guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                TVTopShelfContentProvider.topShelfContentDidChange()
            }
        }
    }

    /// Empties the row on the tvOS home screen. This lives in the app-group container rather
    /// than the app's own, so a reset of the latter does not reach it — and what is left behind
    /// is the signed-out account's viewing history, on the television's home screen, visible
    /// without opening Nuvio at all.
    static func clear() {
        defaults.removeObject(forKey: defaultsKey)
        announceChange()
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
