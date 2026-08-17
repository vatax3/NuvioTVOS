import Foundation
import Observation

// MARK: - Records

/// Playback position for one video (a movie, or one episode of a series).
struct WatchProgress: Codable, Hashable, Identifiable {
    var contentId: String
    var contentType: String
    var videoId: String
    var season: Int?
    var episode: Int?
    var positionSeconds: Double
    var durationSeconds: Double
    var updatedAt: Date

    var id: String { videoId }

    var fraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, positionSeconds / durationSeconds))
    }

    func isFinished(threshold: Double) -> Bool { fraction >= threshold }

    var remainingSeconds: Double { max(0, durationSeconds - positionSeconds) }
}

/// An entry the user explicitly saved to their library.
struct SavedLibraryItem: Codable, Hashable, Identifiable {
    var preview: MetaPreview
    var addedAt: Date
    var id: String { preview.rowKey }
}

/// A resolved Continue Watching row entry — a saved position plus the artwork to draw it.
struct ContinueWatchingEntry: Identifiable, Hashable {
    var progress: WatchProgress
    var preview: MetaPreview
    var episodeTitle: String?
    /// Episode still, when one was cached and the viewer wants thumbnails in the rail.
    var episodeThumbnail: String?
    /// True when the row points at an episode the viewer has not started — the case the
    /// "blur next up" preference is about.
    var isNextUp: Bool = false
    var id: String { progress.videoId }
}

// MARK: - Store

@Observable
@MainActor
final class LibraryStore {
    private(set) var progress: [String: WatchProgress] = [:]
    private(set) var library: [SavedLibraryItem] = []
    /// Artwork cache so Continue Watching can render without refetching every meta.
    private(set) var previewCache: [String: MetaPreview] = [:]
    private(set) var episodeThumbnails: [String: String] = [:]

    private let progressFile = JSONFileStore<[String: WatchProgress]>(filename: "watch-progress.json")
    private let libraryFile = JSONFileStore<[SavedLibraryItem]>(filename: "library.json")
    private let previewFile = JSONFileStore<[String: MetaPreview]>(filename: "preview-cache.json")
    private let thumbnailFile = JSONFileStore<[String: String]>(filename: "episode-thumbnails.json")

    init() {
        progress = progressFile.load() ?? [:]
        library = libraryFile.load() ?? []
        previewCache = previewFile.load() ?? [:]
        episodeThumbnails = thumbnailFile.load() ?? [:]
    }

    // MARK: Progress

    func progress(forVideoId videoId: String) -> WatchProgress? { progress[videoId] }

    func record(
        contentId: String,
        contentType: String,
        videoId: String,
        season: Int?,
        episode: Int?,
        position: Double,
        duration: Double,
        preview: MetaPreview?
    ) {
        guard duration > 0 else { return }
        progress[videoId] = WatchProgress(
            contentId: contentId,
            contentType: contentType,
            videoId: videoId,
            season: season,
            episode: episode,
            positionSeconds: position,
            durationSeconds: duration,
            updatedAt: Date()
        )
        if let preview { previewCache["\(contentType)|\(contentId)"] = preview }
        persistProgress()
    }

    func clearProgress(videoId: String) {
        progress.removeValue(forKey: videoId)
        persistProgress()
    }

    func clearProgress(contentId: String) {
        progress = progress.filter { $0.value.contentId != contentId }
        persistProgress()
    }

    func markWatched(contentId: String, contentType: String, videoId: String, season: Int?, episode: Int?, duration: Double) {
        progress[videoId] = WatchProgress(
            contentId: contentId, contentType: contentType, videoId: videoId,
            season: season, episode: episode,
            positionSeconds: max(duration, 1), durationSeconds: max(duration, 1),
            updatedAt: Date()
        )
        persistProgress()
    }

    func isWatched(videoId: String, threshold: Double) -> Bool {
        progress[videoId]?.isFinished(threshold: threshold) ?? false
    }

    /// Continue Watching rail contents: in-flight items, finished ones dropped, ordered by the
    /// viewer's `continue_watching_sort_mode`.
    func continueWatching(
        threshold: Double,
        sort: ContinueWatchingSortMode = .recentlyWatched
    ) -> [ContinueWatchingEntry] {
        let unfinished = progress.values
            .filter { $0.fraction > 0.01 && !$0.isFinished(threshold: threshold) }
            .sorted { $0.updatedAt > $1.updatedAt }

        // One row per title — the most recent episode represents the whole series.
        var seenContent = Set<String>()
        var entries: [ContinueWatchingEntry] = []
        for item in unfinished {
            let contentKey = "\(item.contentType)|\(item.contentId)"
            guard !seenContent.contains(contentKey) else { continue }
            seenContent.insert(contentKey)
            guard let preview = previewCache[contentKey] else { continue }
            let episodeTitle: String? = {
                guard let season = item.season, let episode = item.episode else { return nil }
                return String(format: "S%02dE%02d", season, episode)
            }()
            entries.append(ContinueWatchingEntry(
                progress: item,
                preview: preview,
                episodeTitle: episodeTitle,
                episodeThumbnail: episodeThumbnails[item.videoId],
                // Below 2% the viewer effectively never saw the episode, so the still is a
                // spoiler for what the blur preference calls "next up".
                isNextUp: item.fraction < 0.02
            ))
        }
        return sorted(entries, by: sort)
    }

    private func sorted(
        _ entries: [ContinueWatchingEntry],
        by mode: ContinueWatchingSortMode
    ) -> [ContinueWatchingEntry] {
        switch mode {
        case .recentlyWatched:
            return entries  // already newest-first
        case .recentlyAdded:
            let addedAt = Dictionary(
                library.map { ($0.id, $0.addedAt) },
                uniquingKeysWith: { first, _ in first }
            )
            return entries.sorted {
                (addedAt[$0.preview.rowKey] ?? .distantPast)
                    > (addedAt[$1.preview.rowKey] ?? .distantPast)
            }
        case .alphabetical:
            return entries.sorted {
                $0.preview.name.localizedCaseInsensitiveCompare($1.preview.name) == .orderedAscending
            }
        }
    }

    /// Episode stills keyed by video id, so the rail can show the actual episode rather than
    /// the series backdrop when `use_episode_thumbnails_in_cw` is on.
    func cacheEpisodeThumbnail(_ url: String?, forVideoId videoId: String) {
        guard let url = url?.nilIfBlank, episodeThumbnails[videoId] != url else { return }
        episodeThumbnails[videoId] = url
        persistThumbnails()
    }

    // MARK: Library

    func isInLibrary(_ preview: MetaPreview) -> Bool {
        library.contains { $0.id == preview.rowKey }
    }

    func toggleLibrary(_ preview: MetaPreview) {
        if let index = library.firstIndex(where: { $0.id == preview.rowKey }) {
            library.remove(at: index)
        } else {
            library.insert(SavedLibraryItem(preview: preview, addedAt: Date()), at: 0)
            cache(preview)
        }
        persistLibrary()
    }

    func removeFromLibrary(_ preview: MetaPreview) {
        library.removeAll { $0.id == preview.rowKey }
        persistLibrary()
    }

    func cache(_ preview: MetaPreview) {
        previewCache["\(preview.apiType)|\(preview.id)"] = preview
        persistPreviews()
    }

    func cachedPreview(contentType: String, contentId: String) -> MetaPreview? {
        previewCache["\(contentType)|\(contentId)"]
    }

    // MARK: Persistence

    private func persistProgress() { progressFile.save(progress) }
    private func persistLibrary() { libraryFile.save(library) }

    private func persistThumbnails() {
        if episodeThumbnails.count > 600 {
            let keep = Set(progress.keys)
            episodeThumbnails = episodeThumbnails.filter { keep.contains($0.key) }
        }
        thumbnailFile.save(episodeThumbnails)
    }

    private func persistPreviews() {
        // Bound the cache so it cannot grow without limit across long-running installs.
        if previewCache.count > 400 {
            let keep = Set(library.map { "\($0.preview.apiType)|\($0.preview.id)" })
                .union(progress.values.map { "\($0.contentType)|\($0.contentId)" })
            previewCache = previewCache.filter { keep.contains($0.key) }
        }
        previewFile.save(previewCache)
    }
}
