import SwiftUI

/// What a long press on an episode card opens.
struct EpisodeOptionsRequest: Identifiable, Hashable {
    var video: Video
    var meta: Meta
    var id: String { video.id }

    static func == (lhs: EpisodeOptionsRequest, rhs: EpisodeOptionsRequest) -> Bool {
        lhs.video.id == rhs.video.id
    }

    func hash(into hasher: inout Hasher) { hasher.combine(video.id) }
}

/// The overlay itself.
///
/// Built on the poster dialog's shape rather than a new one: the two answer the same gesture and
/// a viewer who has learned one should not have to learn the other.
struct EpisodeOptionsDialog: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router
    @Environment(AddonStore.self) private var addons
    @State private var tracking = TrackingWriteService()

    let request: EpisodeOptionsRequest
    let onPlay: (Video) -> Void
    let onDismiss: () -> Void

    @FocusState private var focused: EpisodeOptionsPolicy.Action?

    private var video: Video { request.video }
    private var meta: Meta { request.meta }

    /// The season's episodes, from the cache the detail screen fills on arrival.
    private var episodes: [SeriesEpisodeRef] { library.seriesEpisodes[meta.id] ?? [] }

    private var reference: SeriesEpisodeRef? {
        episodes.first { $0.videoId == video.id }
    }

    private var context: EpisodeOptionsPolicy.Context {
        let watched = { (id: String) in
            library.isWatched(videoId: id, threshold: settings.watchedThreshold)
        }
        return .init(
            isWatched: watched(video.id),
            hasProgress: (library.progress(forVideoId: video.id)?.fraction ?? 0) > 0,
            isSeasonWatched: EpisodeWatchedSpan.isSeasonWatched(
                video.season ?? 0, in: episodes, isWatched: watched
            ),
            hasPreviousEpisodes: reference.map { target in
                episodes.contains { $0.season > 0 && $0.order < target.order }
            } ?? false,
            canOpenComments: canOpenComments
        )
    }

    /// The same two conditions the title's own Comments button checks.
    private var canOpenComments: Bool {
        settings.tracking.showMetaComments
            && !settings.tracking.traktClientId.isEmpty
            && commentsImdbId != nil
    }

    private var commentsImdbId: String? {
        meta.imdbId?.nilIfBlank ?? (meta.id.hasPrefix("tt") ? meta.id : nil)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
                header

                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                    ForEach(EpisodeOptionsPolicy.actions(for: context)) { action in
                        row(action)
                    }
                }
            }
            .padding(NuvioTheme.spacing.xl)
            .frame(width: dp(380), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: NuvioTheme.radii.xl, style: .continuous)
                    .fill(colors.backgroundElevated)
            )
        }
        .focusSection()
        .onExitCommand(perform: onDismiss)
        .onAppear { focused = EpisodeOptionsPolicy.actions(for: context).first }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
            Text(video.name ?? video.title ?? coordinates)
                .nuvioText(NuvioTypography.headlineLarge)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(2)

            Text(coordinates)
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textSecondary)
        }
    }

    private var coordinates: String {
        guard let season = video.season, let episode = video.episode else {
            return meta.name
        }
        return "\(meta.name) · S\(season)E\(episode)"
    }

    private func row(_ action: EpisodeOptionsPolicy.Action) -> some View {
        Button(action: { perform(action) }) {
            HStack(spacing: NuvioTheme.spacing.md) {
                Image(systemName: action.systemImage)
                    .frame(width: dp(22))
                Text(label(action))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .nuvioText(NuvioTextStyles.button)
            .foregroundStyle(action.isDestructive ? colors.error : colors.textPrimary)
            .padding(.horizontal, NuvioTheme.spacing.lg)
            .frame(height: NuvioTheme.components.buttonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.lg))
        .focused($focused, equals: action)
    }

    private func label(_ action: EpisodeOptionsPolicy.Action) -> String {
        switch action {
        case .play: return L10n.text("episode_options.play", fallback: "Play")
        case .startFromBeginning:
            return L10n.text("episode_options.start_over", fallback: "Start from the beginning")
        case .markWatched:
            return L10n.text("episode_options.mark_watched", fallback: "Mark watched")
        case .markUnwatched:
            return L10n.text("episode_options.mark_unwatched", fallback: "Mark unwatched")
        case .markSeasonWatched:
            return L10n.text("episode_options.mark_season_watched", fallback: "Mark season watched")
        case .markSeasonUnwatched:
            return L10n.text("episode_options.mark_season_unwatched", fallback: "Mark season unwatched")
        case .markPreviousWatched:
            return L10n.text("episode_options.mark_previous_watched", fallback: "Mark this and everything before it watched")
        case .openComments:
            return L10n.text("episode_options.comments", fallback: "Comments")
        }
    }

    private func perform(_ action: EpisodeOptionsPolicy.Action) {
        switch action {
        case .play:
            onPlay(video)

        case .startFromBeginning:
            library.clearProgress(videoId: video.id)
            onPlay(video)

        case .markWatched:
            mark([reference].compactMap { $0 }, watched: true)

        case .markUnwatched:
            mark([reference].compactMap { $0 }, watched: false)

        case .markSeasonWatched:
            mark(EpisodeWatchedSpan.season(video.season ?? 0, in: episodes), watched: true)

        case .markSeasonUnwatched:
            // Unwatching takes the whole season as listed, unaired included, so nothing is left
            // marked behind — the same rule `SeriesWatchedWalk` follows for a series.
            mark(episodes.filter { $0.season == video.season }, watched: false)

        case .markPreviousWatched:
            guard let reference else { break }
            mark(EpisodeWatchedSpan.precedingAndIncluding(reference, in: episodes), watched: true)

        case .openComments:
            guard let imdbId = commentsImdbId else { break }
            router.push(.comments(CommentsRequest(
                imdbId: imdbId, contentType: meta.apiType, title: meta.name
            )))
        }
        onDismiss()
    }

    /// Writes the local records, then tells the tracking service once per episode.
    ///
    /// One call per episode rather than one for the span, unlike the series walk: Trakt and Simkl
    /// both take a whole show with no coordinates, but neither takes "these nine episodes" in a
    /// shape we already build. A season is nine or twenty calls, not four hundred.
    private func mark(_ targets: [SeriesEpisodeRef], watched: Bool) {
        guard !targets.isEmpty else { return }

        for target in targets {
            if watched {
                let duration = library.progress(forVideoId: target.videoId)?.durationSeconds ?? 1
                library.markWatched(
                    contentId: meta.id,
                    contentType: meta.apiType,
                    videoId: target.videoId,
                    season: target.season,
                    episode: target.episode,
                    duration: duration
                )
            } else {
                library.clearProgress(videoId: target.videoId)
            }
        }

        guard let imdb = meta.imdbId?.nilIfBlank ?? (meta.id.hasPrefix("tt") ? meta.id : nil) else {
            return
        }
        let sent = targets
        let preview = meta.preview()
        Task {
            for target in sent {
                await tracking.watched(
                    imdbId: imdb,
                    trackingIds: preview.trackingIds,
                    title: meta.name,
                    year: preview.year,
                    type: .series,
                    season: target.season,
                    episode: target.episode,
                    videoId: target.videoId,
                    removing: !watched,
                    settings: settings
                )
            }
        }
    }
}
