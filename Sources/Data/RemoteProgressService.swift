import Foundation
import Observation

/// Fills Continue Watching from a tracking account rather than from this device.
///
/// `watch_progress_source` had been stored, synced and shown in Settings since the port began,
/// and read by nothing: choosing Trakt changed no pixel. This is the reader.
///
/// Two things make it more than a fetch. Trakt reports progress as a **percentage**, with no
/// duration, so the entries it produces carry a synthetic 100-second duration — `fraction` is
/// what every caller actually reads, and it comes out right. And Trakt knows only IMDb ids, so a
/// title watched on the phone and never on this Apple TV has no artwork here; the missing
/// previews are resolved through the installed metadata addons before the rail is built,
/// otherwise those rows would be silently dropped for want of a poster.
@Observable
@MainActor
final class RemoteProgressService {
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Rows adopted from the account on the last pass, so a source change can retract them.
    private(set) var adoptedVideoIds: Set<String> = []
    /// Rows already looked up on TMDB, successfully or not. A title with genuinely no still on
    /// TMDB must not be retried on every appearance of Home.
    private var enrichedVideoIds: Set<String> = []

    private let client: StremioClient

    init(client: StremioClient = .shared) {
        self.client = client
    }

    /// Trakt's own resume points expire on their side; refreshing more often than this mostly
    /// spends the account's rate limit.
    private static let minimumInterval: TimeInterval = 120

    func refreshIfNeeded(
        settings: AppSettings,
        library: LibraryStore,
        addons: AddonStore,
        force: Bool = false
    ) async {
        let source = settings.effectiveWatchProgressSource
        guard source == .trakt || source == .simkl else { return }
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < Self.minimumInterval {
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var adopted: Set<String> = []
        if source == .trakt {
            let clientId = settings.tracking.traktClientId
            let token = settings.tracking.traktAccessToken
            guard !clientId.isEmpty, !token.isEmpty else { return }
            let items = await TraktClient.shared.playbackProgress(clientId: clientId, token: token)
            for item in items {
                guard let entry = Self.progress(from: item) else { continue }
                if adopt(entry, into: library) { adopted.insert(entry.videoId) }
                if library.cachedPreview(contentType: entry.contentType, contentId: entry.contentId) == nil,
                   let preview = await preview(for: item, addons: addons) {
                    library.cache(preview)
                }
            }
        } else {
            let clientId = settings.tracking.simklClientId
            let token = settings.tracking.simklAccessToken
            guard !clientId.isEmpty, !token.isEmpty else { return }
            let items = (try? await SimklClient.shared.playbackProgress(
                clientId: clientId, token: token
            )) ?? []
            for item in items {
                guard let entry = Self.progress(from: item) else { continue }
                if adopt(entry, into: library) { adopted.insert(entry.videoId) }
                if library.cachedPreview(contentType: entry.contentType, contentId: entry.contentId) == nil {
                    library.cache(MetaPreview(
                        id: item.contentId,
                        type: item.type,
                        rawType: item.type.apiString(),
                        name: item.title,
                        poster: item.poster,
                        imdbId: Self.imdbId(fromContentId: item.contentId)
                    ))
                }
            }
        }
        lastRefresh = Date()
        adoptedVideoIds = adopted
    }

    private func adopt(_ entry: WatchProgress, into library: LibraryStore) -> Bool {
        // A position recorded on this device is the better one: it has a real duration and is
        // the exact point the engine can seek to. Remote percentages only fill gaps/newer rows.
        if let local = library.progress(forVideoId: entry.videoId), local.updatedAt >= entry.updatedAt {
            return false
        }
        library.adoptProgress(entry)
        return true
    }

    /// Maps one Trakt resume point onto our record.
    ///
    /// Split out and `nonisolated` so the percentage arithmetic and the episode id format can be
    /// tested without a network or a store.
    nonisolated static func progress(from item: TraktClient.PlaybackItem) -> WatchProgress? {
        guard item.progress > 0 else { return nil }
        let videoId: String
        if item.type == .series, let season = item.season, let episode = item.episode {
            videoId = "\(item.imdbId):\(season):\(episode)"
        } else {
            videoId = item.imdbId
        }
        return WatchProgress(
            contentId: item.imdbId,
            contentType: item.type.rawValue,
            videoId: videoId,
            season: item.season,
            episode: item.episode,
            // Trakt gives a percentage and no duration. A nominal 100-second duration makes
            // `fraction` exact, which is the only thing the rail reads; the player still resumes
            // from whatever this device recorded, never from here.
            positionSeconds: min(100, max(0, item.progress)),
            durationSeconds: 100,
            updatedAt: item.pausedAt ?? Date()
        )
    }

    nonisolated static func progress(from item: SimklClient.PlaybackItem) -> WatchProgress? {
        guard item.progress > 0 else { return nil }
        let videoId: String
        if item.type == .series, let episode = item.episode {
            videoId = "\(item.contentId):\(item.season ?? 0):\(episode)"
        } else {
            videoId = item.contentId
        }
        let duration = item.durationSeconds > 0 ? item.durationSeconds : 100
        return WatchProgress(
            contentId: item.contentId,
            contentType: item.type.rawValue,
            videoId: videoId,
            season: item.season,
            episode: item.episode,
            positionSeconds: duration * item.progress / 100,
            durationSeconds: duration,
            updatedAt: item.pausedAt ?? Date()
        )
    }

    // MARK: TMDB enrichment

    /// Episode stills for Continue Watching rows that have none — the reader for
    /// `tmdb_enrich_continue_watching`.
    ///
    /// The rail falls back to the series backdrop when an episode has no still, so every row of a
    /// show looks identical and you cannot tell at a glance which episode you stopped on. That is
    /// what this fixes, and it is why it only ever fills blanks.
    func enrichContinueWatching(
        _ entries: [ContinueWatchingEntry],
        settings: AppSettings,
        library: LibraryStore
    ) async {
        guard settings.tmdb.enrichContinueWatching, settings.tmdb.isUsable else { return }
        let missing = entries.filter {
            $0.episodeThumbnail?.nilIfBlank == nil && $0.progress.season != nil && $0.progress.episode != nil
        }
        guard !missing.isEmpty else { return }

        for entry in missing.prefix(Self.enrichmentBudget) {
            let key = entry.progress.videoId
            guard !enrichedVideoIds.contains(key) else { continue }
            enrichedVideoIds.insert(key)

            guard let imdbId = entry.preview.imdbId ?? Self.imdbId(fromContentId: entry.progress.contentId),
                  let season = entry.progress.season,
                  let episode = entry.progress.episode
            else { continue }

            let tmdbId = await TMDBClient.shared.tmdbId(
                imdbId: imdbId, type: .series, apiKey: settings.tmdb.apiKey
            )
            guard let tmdbId else { continue }
            let details = await TMDBClient.shared.seasonEpisodes(
                tmdbId: tmdbId,
                season: season,
                apiKey: settings.tmdb.apiKey,
                language: settings.tmdb.language
            )
            guard let still = details.first(where: { $0.episode == episode })?.still else { continue }
            library.cacheEpisodeThumbnail(still, forVideoId: key)
        }
    }

    /// A rail is a handful of rows; without a cap a viewer with a long history would fire off one
    /// TMDB round trip per row on every appearance of Home.
    private static let enrichmentBudget = 12

    nonisolated static func imdbId(fromContentId contentId: String) -> String? {
        contentId.hasPrefix("tt") ? String(contentId.split(separator: ":")[0]) : nil
    }

    private func preview(for item: TraktClient.PlaybackItem, addons: AddonStore) async -> MetaPreview? {
        let candidates = addons.addonsProviding(
            resource: "meta", type: item.type.rawValue, id: item.imdbId
        )
        for addon in candidates {
            if let meta = try? await client.fetchMeta(
                addon: addon, type: item.type.rawValue, id: item.imdbId
            ) {
                return meta.preview()
            }
        }
        return nil
    }
}
