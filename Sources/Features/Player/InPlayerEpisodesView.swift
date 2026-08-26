import SwiftUI

/// tvOS equivalent of Android TV's in-player Episodes side panel. Selecting an episode returns
/// to its source list, where the same resolver and filters as a normal play action are used.
struct InPlayerEpisodesView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons

    let request: PlaybackRequest
    let onDismiss: () -> Void
    let onSelect: (StreamRequest) -> Void
    var handlesExit = true

    @State private var meta: Meta?
    @State private var selectedSeason = 1
    @State private var isLoading = true
    @State private var error: String?

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
                            Button(action: { selectedSeason = season }) {
                                Text(L10n.format("player.season_format", fallback: "Season %@", season))
                                    .nuvioText(NuvioTextStyles.metadata)
                                    .foregroundStyle(selectedSeason == season ? colors.textPrimary : colors.textSecondary)
                                    .padding(.horizontal, NuvioTheme.spacing.md)
                                    .padding(.vertical, NuvioTheme.spacing.sm)
                                    .background(selectedSeason == season ? colors.secondary.opacity(0.28) : colors.surfaceVariant.opacity(0.50), in: Capsule())
                            }
                            .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.xl))
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
                InPlayerPanelSection(title: L10n.format("player.season_format", fallback: "Season %@", selectedSeason)) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                        InPlayerPanelRow(
                            title: episodeLabel(episode),
                            subtitle: episode.displayOverview?.nilIfBlank,
                            systemImage: "play.circle",
                            isSelected: episode.id == request.videoId,
                            requestsInitialFocus: episode.id == request.videoId
                                || (!episodes.contains(where: { $0.id == request.videoId }) && index == 0)
                        ) { onSelect(streamRequest(for: episode)) }
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
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
