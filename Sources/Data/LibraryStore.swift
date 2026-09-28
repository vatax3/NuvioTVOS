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
    /// Library rows removed on this device but not yet deleted on the account. Without these a
    /// removal would simply be re-adopted from the remote snapshot on the next sync.
    private(set) var pendingLibraryDeletions: [String] = []
    /// The same, for watch progress, keyed by video id — which is what the account's delete RPC
    /// takes. Progress rows are removed by two viewer actions, not one: taking a title out of
    /// Continue Watching, and marking something unwatched. Both wrote only locally, so the next
    /// sync pulled the row back and silently undid them.
    private(set) var pendingProgressDeletions: [String] = []

    private let progressFile = JSONFileStore<[String: WatchProgress]>(filename: "watch-progress.json")
    private let libraryFile = JSONFileStore<[SavedLibraryItem]>(filename: "library.json")
    private let previewFile = JSONFileStore<[String: MetaPreview]>(filename: "preview-cache.json")
    private let thumbnailFile = JSONFileStore<[String: String]>(filename: "episode-thumbnails.json")
    /// Both deletion queues are durable: a purged queue silently resurrects exactly the rows it
    /// was holding, which is the bug they exist to prevent.
    ///
    /// The library one was left purgeable in 1.0.36 because flipping it would have stranded any
    /// queue already written to Caches — `JSONFileStore`'s own migration only reads the
    /// pre-split Application Support path. `migrateDeletionQueue()` is that missing read, so the
    /// note deferring this is now paid off rather than repeated.
    private let deletionFile = JSONFileStore<[String]>(
        filename: "library-deletions.json", durability: .critical
    )
    /// Where the library queue used to live, read once so a pending removal survives the upgrade.
    private let legacyDeletionFile = JSONFileStore<[String]>(filename: "library-deletions.json")
    private let progressDeletionFile = JSONFileStore<[String]>(
        filename: "progress-deletions.json", durability: .critical
    )

    // MARK: Surviving a storage reclaim

    /// The viewer's saved titles, reduced to what cannot be fetched again.
    ///
    /// `library.json` above lives in Caches and holds whole previews. That is the right place for
    /// artwork and the wrong one for the fact that a title was saved at all: tvOS may reclaim it,
    /// and a viewer with no Nuvio account has nothing to rebuild it from. See `LibraryEntryRef`.
    private let libraryIdentityFile = JSONFileStore<[LibraryEntryRef]>(
        filename: "library-identity.json", durability: .critical
    )
    /// Resume points, which are what a viewer notices vanishing. **Unfinished rows only** — the
    /// watched marks are the bulk of this store and would not fit the durable budget, and losing
    /// one costs a tick on an episode rather than a place in a film.
    private let resumeIdentityFile = JSONFileStore<[WatchProgress]>(
        filename: "resume-points.json", durability: .critical
    )
    private let episodeFile = JSONFileStore<[String: [SeriesEpisodeRef]]>(filename: "series-episodes.json")

    /// Episode lists per series, so Next Up can name the episode that follows one just
    /// finished without an addon round trip on the first frame of Home.
    private(set) var seriesEpisodes: [String: [SeriesEpisodeRef]] = [:]

    init() {
        progress = progressFile.load() ?? [:]
        library = libraryFile.load() ?? []
        previewCache = previewFile.load() ?? [:]
        episodeThumbnails = thumbnailFile.load() ?? [:]
        seriesEpisodes = episodeFile.load() ?? [:]
        pendingLibraryDeletions = deletionFile.load() ?? []
        pendingProgressDeletions = progressDeletionFile.load() ?? []
        migrateDeletionQueue()
        restoreFromDurableCopies()
        refreshTopShelf()
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
        cancelProgressDeletion(videoId)
        persistProgress()
    }

    func clearProgress(videoId: String) {
        guard progress.removeValue(forKey: videoId) != nil else { return }
        recordProgressDeletion([videoId])
        persistProgress()
    }

    func clearProgress(contentId: String) {
        let removed = progress.values.filter { $0.contentId == contentId }.map(\.videoId)
        guard !removed.isEmpty else { return }
        progress = progress.filter { $0.value.contentId != contentId }
        recordProgressDeletion(removed)
        persistProgress()
    }

    func markWatched(contentId: String, contentType: String, videoId: String, season: Int?, episode: Int?, duration: Double) {
        progress[videoId] = WatchProgress(
            contentId: contentId, contentType: contentType, videoId: videoId,
            season: season, episode: episode,
            positionSeconds: max(duration, 1), durationSeconds: max(duration, 1),
            updatedAt: Date()
        )
        cancelProgressDeletion(videoId)
        persistProgress()
    }

    func isWatched(videoId: String, threshold: Double) -> Bool {
        progress[videoId]?.isFinished(threshold: threshold) ?? false
    }

    /// Continue Watching rail contents: in-flight items, finished ones dropped, ordered by the
    /// viewer's `continue_watching_sort_mode`.
    ///
    /// `withinDays` is the viewer's cap from Tracking settings. A row you abandoned eight months
    /// ago is not something you are in the middle of, and leaving it there pushes what you *are*
    /// watching off the end of the rail. Zero or less means no cap.
    func continueWatching(
        threshold: Double,
        sort: ContinueWatchingSortMode = .recentlyWatched,
        withinDays: Int = 0,
        nextUp: NextUpOptions = NextUpOptions()
    ) -> [ContinueWatchingEntry] {
        let cutoff = Self.cutoffDate(withinDays: withinDays)
        let unfinished = progress.values
            .filter { $0.fraction > 0.01 && !$0.isFinished(threshold: threshold) }
            .filter { item in cutoff.map { item.updatedAt >= $0 } ?? true }
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
        entries += projectedNextUp(
            threshold: threshold, cutoff: cutoff, excluding: seenContent, options: nextUp
        )
        // `seenContent` only dedupes ids that are literally equal. Two addons keying the same
        // show differently get past it, and the rail shows one series twice, each row offering a
        // different next episode. See `SeriesIdentity`.
        entries = SeriesIdentity.deduplicated(
            entries,
            contentId: { $0.progress.contentId },
            imdbId: { $0.preview.imdbId },
            activity: { $0.progress.updatedAt }
        )
        return sorted(entries, by: sort)
    }

    /// Series whose latest episode is finished, offered their next one.
    ///
    /// Without this the rail only ever holds half-watched episodes, so finishing one removes
    /// the series from Home entirely and the viewer has to go and find the next episode
    /// themselves. See `NextUpProjection`.
    private func projectedNextUp(
        threshold: Double,
        cutoff: Date?,
        excluding represented: Set<String>,
        options: NextUpOptions
    ) -> [ContinueWatchingEntry] {
        guard options.isEnabled else { return [] }

        // Every finished episode, by series, newest activity first.
        var watchedBySeries: [String: [(progress: WatchProgress, episode: SeriesEpisodeRef)]] = [:]
        for item in progress.values where item.isFinished(threshold: threshold) {
            guard item.season != nil, item.episode != nil else { continue }
            guard let episodes = seriesEpisodes[item.contentId] else { continue }
            guard let episode = episodes.first(where: { $0.videoId == item.videoId }) else { continue }
            watchedBySeries[item.contentId, default: []].append((item, episode))
        }

        var entries: [ContinueWatchingEntry] = []
        for (contentId, watched) in watchedBySeries {
            let key = "series|\(contentId)"
            guard !represented.contains(key), let preview = previewCache[key] else { continue }
            guard !NextUpDismissal.isDismissed(contentId: contentId, keys: options.dismissedKeys)
            else { continue }

            // The rail's own cap applies to the activity that seeded the row, not to the
            // episode being offered — which has no timestamp of its own.
            let lastWatched = watched.map(\.progress.updatedAt).max() ?? .distantPast
            if let cutoff, lastWatched < cutoff { continue }

            let anchor = NextUpProjection.anchor(
                watched: watched.map { ($0.episode, $0.progress.updatedAt) },
                fromFurthest: options.fromFurthestEpisode
            )
            guard let next = NextUpProjection.next(
                in: seriesEpisodes[contentId] ?? [],
                isWatched: { [weak self] videoId in
                    self?.progress[videoId]?.isFinished(threshold: threshold) ?? false
                },
                after: anchor,
                allowsUnaired: options.allowsUnaired
            ) else { continue }

            let seed = watched.first?.progress
            entries.append(ContinueWatchingEntry(
                progress: WatchProgress(
                    contentId: contentId,
                    contentType: seed?.contentType ?? "series",
                    videoId: next.videoId,
                    season: next.season,
                    episode: next.episode,
                    // Nothing watched of it yet, which is exactly what the card should draw.
                    positionSeconds: 0,
                    durationSeconds: 0,
                    // The series sorts by when it was last watched, not by an episode that has
                    // never been opened.
                    updatedAt: lastWatched
                ),
                preview: preview,
                episodeTitle: String(format: "S%02dE%02d", next.season, next.episode),
                episodeThumbnail: next.thumbnail ?? episodeThumbnails[next.videoId],
                isNextUp: true
            ))
        }
        return entries
    }

    /// Split out so the cap can be tested without building a store, and so "no cap" has exactly
    /// one definition rather than one per caller.
    nonisolated static func cutoffDate(withinDays days: Int, now: Date = Date()) -> Date? {
        guard days > 0 else { return nil }
        return now.addingTimeInterval(-Double(days) * 86_400)
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

    /// Remembers a series' episode list, written whenever a detail screen resolves one.
    ///
    /// Only for series already in progress or in the library: caching every series a viewer
    /// merely looked at would grow without bound, and none of those can seed a Next Up row.
    func cacheEpisodes(_ episodes: [SeriesEpisodeRef], forContentId contentId: String) {
        guard !episodes.isEmpty else { return }
        let key = "series|\(contentId)"
        guard previewCache[key] != nil || progress.values.contains(where: { $0.contentId == contentId })
        else { return }
        guard seriesEpisodes[contentId] != episodes else { return }
        seriesEpisodes[contentId] = episodes
        episodeFile.save(seriesEpisodes)
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
            recordDeletion(preview.rowKey)
        } else {
            library.insert(SavedLibraryItem(preview: preview, addedAt: Date()), at: 0)
            cancelDeletion(preview.rowKey)
            cache(preview)
        }
        persistLibrary()
    }

    func removeFromLibrary(_ preview: MetaPreview) {
        library.removeAll { $0.id == preview.rowKey }
        recordDeletion(preview.rowKey)
        persistLibrary()
    }

    func cache(_ preview: MetaPreview) {
        previewCache["\(preview.apiType)|\(preview.id)"] = preview
        persistPreviews()
    }

    func cachedPreview(contentType: String, contentId: String) -> MetaPreview? {
        previewCache["\(contentType)|\(contentId)"]
    }

    // MARK: Sync adoption

    /// Applies a row that arrived from the account. Distinct from `record`/`toggleLibrary` so a
    /// pulled row cannot be mistaken for a local action and pushed straight back.
    func adoptProgress(_ incoming: WatchProgress) {
        // A row this device removed must not come back before the deletion has been pushed —
        // the same rule the saved library already follows below, and for the same reason.
        guard !pendingProgressDeletions.contains(incoming.videoId) else { return }
        progress[incoming.videoId] = incoming
        persistProgress()
    }

    func adoptSavedItem(_ item: SavedLibraryItem) {
        // A row this device deleted must not come back before the deletion has been pushed.
        guard !pendingLibraryDeletions.contains(item.id) else { return }
        if let index = library.firstIndex(where: { $0.id == item.id }) {
            library[index] = item
        } else {
            library.append(item)
        }
        library.sort { $0.addedAt > $1.addedAt }
        previewCache[item.preview.rowKey] = item.preview
        persistLibrary()
        persistPreviews()
    }

    /// `advanced_clear_cw_cache`: drops cached artwork and episode stills. Watch progress and
    /// the saved library are left alone — this clears derived data, not the viewer's history.
    func clearContinueWatchingCache() {
        let keep = Set(library.map(\.preview.rowKey))
        previewCache = previewCache.filter { keep.contains($0.key) }
        episodeThumbnails.removeAll()
        persistPreviews()
        persistThumbnails()
    }

    private func recordDeletion(_ rowKey: String) {
        guard !pendingLibraryDeletions.contains(rowKey) else { return }
        pendingLibraryDeletions.append(rowKey)
        deletionFile.save(pendingLibraryDeletions)
    }

    /// Called once the account has accepted the deletes.
    func clearPendingLibraryDeletions(_ keys: [String]) {
        pendingLibraryDeletions.removeAll { keys.contains($0) }
        deletionFile.save(pendingLibraryDeletions)
    }

    /// A row re-added locally is no longer a pending deletion.
    private func cancelDeletion(_ rowKey: String) {
        guard pendingLibraryDeletions.contains(rowKey) else { return }
        pendingLibraryDeletions.removeAll { $0 == rowKey }
        deletionFile.save(pendingLibraryDeletions)
    }

    private func recordProgressDeletion(_ videoIds: [String]) {
        let fresh = videoIds.filter { !pendingProgressDeletions.contains($0) }
        guard !fresh.isEmpty else { return }
        pendingProgressDeletions.append(contentsOf: fresh)
        progressDeletionFile.save(pendingProgressDeletions)
    }

    /// Called once the account has accepted the deletes.
    func clearPendingProgressDeletions(_ keys: [String]) {
        pendingProgressDeletions.removeAll { keys.contains($0) }
        progressDeletionFile.save(pendingProgressDeletions)
    }

    /// Watching something again — or marking it watched — outranks a removal that has not been
    /// pushed yet. Without this the row would be written locally and then deleted on the account.
    private func cancelProgressDeletion(_ videoId: String) {
        guard pendingProgressDeletions.contains(videoId) else { return }
        pendingProgressDeletions.removeAll { $0 == videoId }
        progressDeletionFile.save(pendingProgressDeletions)
    }

    // MARK: Persistence

    private func persistProgress() {
        progressFile.save(progress)
        // Only what a viewer would notice losing. `fraction > 0.01` is the same floor the
        // Continue Watching rail applies, so this is exactly the rail plus nothing.
        resumeIdentityFile.save(
            DurableLibraryBudget.fitting(progress.values.filter { $0.fraction > 0.01 && $0.fraction < 1 })
        )
        refreshTopShelf()
    }

    private func persistLibrary() {
        libraryFile.save(library)
        libraryIdentityFile.save(DurableLibraryBudget.fitting(library.map(LibraryEntryRef.init)))
        refreshTopShelf()
    }

    // MARK: Reclaim recovery

    /// Puts back anything the durable copies still know about after Caches was emptied.
    ///
    /// Additive on purpose. The purgeable file is the fuller record while it survives — it has the
    /// artwork — so it wins wherever both have a row, and the durable copy only supplies what is
    /// missing. That also makes this a no-op on every launch where nothing was reclaimed, which is
    /// almost all of them.
    ///
    /// A removal cannot be undone by this: the durable copy is rewritten on the same write that
    /// performs the removal, so a title taken out of the library is gone from both.
    private func restoreFromDurableCopies() {
        let refs = libraryIdentityFile.load() ?? []
        if !refs.isEmpty {
            let present = Set(library.map(\.preview.rowKey))
            let restored = refs
                .filter { !present.contains($0.rowKey) }
                .map { $0.restored(preview: previewCache[$0.rowKey]) }
            if !restored.isEmpty {
                library.append(contentsOf: restored)
                library.sort { $0.addedAt > $1.addedAt }
                libraryFile.save(library)
            }
        }

        let resumePoints = resumeIdentityFile.load() ?? []
        var recovered = false
        for row in resumePoints where progress[row.videoId] == nil {
            // Never over a queued deletion: the queue is the record of an intent the account has
            // not been told about yet, and restoring past it is the resurrection bug inverted.
            guard !pendingProgressDeletions.contains(row.videoId) else { continue }
            progress[row.videoId] = row
            recovered = true
        }
        if recovered { progressFile.save(progress) }
    }

    /// Reads the library deletion queue out of its old purgeable home, once.
    ///
    /// Merged rather than replaced, and the old file is left where it is: this build may not be
    /// the one the viewer keeps, and a downgrade that found the queue gone would re-adopt every
    /// row it was holding.
    private func migrateDeletionQueue() {
        guard let stranded = legacyDeletionFile.load(), !stranded.isEmpty else { return }
        let fresh = stranded.filter { !pendingLibraryDeletions.contains($0) }
        guard !fresh.isEmpty else { return }
        pendingLibraryDeletions.append(contentsOf: fresh)
        deletionFile.save(pendingLibraryDeletions)
    }

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
        refreshTopShelf()
    }

    private func refreshTopShelf() {
        TopShelfSnapshotPublisher.publish(progress: progress, previews: previewCache)
    }
}
