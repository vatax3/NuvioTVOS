import SwiftUI

/// tvOS equivalent of Android TV's in-player Episodes side panel. Selecting an episode returns
/// to its source list, where the same resolver and filters as a normal play action are used.
struct InPlayerEpisodesView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings

    let request: PlaybackRequest
    let onDismiss: () -> Void
    let onSelect: (StreamRequest) -> Void
    var handlesExit = true

    @State private var meta: Meta?
    @State private var selectedSeason = 1
    @State private var isLoading = true
    @State private var error: String?
    @State private var options: EpisodeOptionsRequest?
    /// Debounces the season a focused chip asks for, so crossing four chips to reach the fifth
    /// loads one season rather than five. Upstream uses 150ms for the same control.
    @State private var seasonFocusTask: Task<Void, Never>?

    private var seasons: [Int] { meta?.seasons ?? [] }
    private var episodes: [Video] {
        guard let meta else { return [] }
        return meta.watchableEpisodes().filter { $0.season == selectedSeason }
    }

    var body: some View {
        InPlayerPanel(
            title: L10n.text("player.episodes"), subtitle: request.title,
            handlesExit: handlesExit, onDismiss: onDismiss
        ) {
            if !seasons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NuvioTheme.spacing.xs) {
                        ForEach(seasons, id: \.self) { season in
                            seasonChip(season)
                        }
                    }
                    .padding(.horizontal, NuvioTheme.spacing.xs)
                }
            }

            if isLoading {
                ProgressView(L10n.text("player.loading_episodes"))
                    .tint(colors.secondary)
                    .frame(maxWidth: .infinity, minHeight: dp(180))
            } else if let error {
                InPlayerPanelSection(title: L10n.text("player.episodes")) {
                    InPlayerInfoRow(title: L10n.text("common.unavailable"), value: error)
                }
            } else {
                InPlayerPanelSection(title: L10n.format("player.season_format", fallback: "Season %@", String(selectedSeason))) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                        InPlayerPanelRow(
                            title: episodeLabel(episode),
                            subtitle: episode.displayOverview?.nilIfBlank,
                            systemImage: progressIcon(for: episode),
                            isSelected: episode.id == request.videoId,
                            // Only the season the panel opened on claims focus. A chip loading
                            // its season must not pull the remote down into the list — that is
                            // upstream's own bug here, and ours re-runs this the same way.
                            requestsInitialFocus: selectedSeason == (request.season ?? selectedSeason)
                                && (episode.id == request.videoId
                                    || (!episodes.contains(where: { $0.id == request.videoId }) && index == 0)),
                            revealsSubtitle: true,
                            onHold: meta.map { meta in
                                { options = EpisodeOptionsRequest(video: episode, meta: meta) }
                            },
                            identifier: "player.episode.\(episode.id)"
                        ) { onSelect(streamRequest(for: episode)) }
                    }
                }
            }
        }
        .overlay {
            if let options {
                EpisodeOptionsDialog(
                    request: options,
                    onPlay: { episode in
                        self.options = nil
                        onSelect(streamRequest(for: episode))
                    },
                    onDismiss: { self.options = nil }
                )
            }
        }
        .task { await load() }
        .onDisappear { seasonFocusTask?.cancel() }
    }

    /// One season chip. Focusing it selects the season, after a beat.
    ///
    /// Selecting on focus rather than on Select, which is what upstream moved to and is right here
    /// for a reason that is ours: every season's episodes are already in the `Meta` we loaded, so
    /// there is no request behind a move and the list is simply there. Making the viewer press
    /// Select to see it was a keystroke that bought nothing.
    private func seasonChip(_ season: Int) -> some View {
        Button(action: { select(season: season, immediately: true) }) {
            Text(L10n.format("player.season_format", fallback: "Season %@", String(season)))
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(selectedSeason == season ? colors.textPrimary : colors.textSecondary)
                .padding(.horizontal, NuvioTheme.spacing.md)
                .padding(.vertical, NuvioTheme.spacing.sm)
                .background(
                    selectedSeason == season
                        ? colors.secondary.opacity(0.28)
                        : colors.surfaceVariant.opacity(0.50),
                    in: Capsule()
                )
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.xl))
        .onFocusChange { focused in
            guard focused else { return }
            select(season: season, immediately: false)
        }
    }

    /// The debounce. Crossing four chips to reach the fifth should load one season, not five.
    private func select(season: Int, immediately: Bool) {
        seasonFocusTask?.cancel()
        guard !immediately else {
            selectedSeason = season
            return
        }
        seasonFocusTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            selectedSeason = season
        }
    }

    /// Three states in one symbol family, which is what the panel had none of: every episode
    /// drew the same outline whether it had been finished, started or never opened. Upstream
    /// distinguishes finished from started on the still; this row has no still, so the leading
    /// icon carries it.
    private func progressIcon(for episode: Video) -> String {
        if library.isWatched(videoId: episode.id, threshold: settings.watchedThreshold) {
            return "checkmark.circle.fill"
        }
        return library.progress(forVideoId: episode.id) == nil ? "play.circle" : "play.circle.fill"
    }

    private func load() async {
        #if DEBUG
        if let staged = PlayerHarness.episodesMeta() {
            meta = staged
            library.cacheEpisodes(staged.episodeRefs, forContentId: request.contentId)
            selectedSeason = request.season ?? staged.seasons.first ?? 1
            isLoading = false
            return
        }
        #endif
        guard request.contentType == "series" else {
            error = L10n.text("player.episodes_series_only", fallback: "Episode selection is available for series only.")
            isLoading = false
            return
        }
        let candidates = addons.addonsProviding(
            resource: "meta", type: request.contentType, id: request.contentId
        )
        for addon in candidates {
            if let resolved = try? await StremioClient.shared.fetchMeta(
                addon: addon, type: request.contentType, id: request.contentId
            ), resolved.type == .series {
                meta = resolved
                // Free, and it makes the options dialog correct from here: the season-watched and
                // previous-episodes rows read this cache, and until now only the detail screen
                // filled it. Next Up and the watched walk read it too.
                if !resolved.episodeRefs.isEmpty {
                    library.cacheEpisodes(resolved.episodeRefs, forContentId: request.contentId)
                }
                selectedSeason = request.season
                    ?? resolved.seasons.first
                    ?? 1
                isLoading = false
                return
            }
        }
        error = candidates.isEmpty
            ? L10n.text("player.episodes_no_addon", fallback: "No installed addon can provide this episode list.")
            : L10n.text("player.episodes_failed", fallback: "Episodes could not be loaded from the installed addons.")
        isLoading = false
    }

    private func episodeLabel(_ episode: Video) -> String {
        let code = [episode.season, episode.episode]
        if let season = code[0], let number = code[1] {
            return String(format: "S%02dE%02d · %@", season, number, episode.displayTitle)
        }
        return episode.displayTitle
    }

    private func streamRequest(for episode: Video) -> StreamRequest {
        let ordered = meta?.watchableEpisodes().sorted {
            ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
        } ?? []
        let next = ordered.drop { $0.id != episode.id }.dropFirst().first
        return StreamRequest(
            videoId: episode.id,
            contentType: request.contentType,
            title: request.title,
            contentId: request.contentId,
            contentName: request.title,
            poster: request.poster,
            backdrop: request.backdrop,
            logo: request.logo,
            season: episode.season,
            episode: episode.episode,
            episodeName: episode.displayTitle,
            year: nil,
            runtime: nil,
            imdbId: request.imdbId,
            nextUpVideoId: next?.id
        )
    }
}
