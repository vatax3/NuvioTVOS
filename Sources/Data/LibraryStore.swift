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

    private let progressFile = JSONFileStore<[String: WatchProgress]>(filename: "watch-progress.json")
    private let libraryFile = JSONFileStore<[SavedLibraryItem]>(filename: "library.json")
    private let previewFile = JSONFileStore<[String: MetaPreview]>(filename: "preview-cache.json")

    init() {
        progress = progressFile.load() ?? [:]
        library = libraryFile.load() ?? []
        previewCache = previewFile.load() ?? [:]
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

    /// Continue Watching rail contents: in-flight items, newest first, finished ones dropped.
    func continueWatching(threshold: Double) -> [ContinueWatchingEntry] {
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
                progress: item, preview: preview, episodeTitle: episodeTitle
            ))
        }
        return entries
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
