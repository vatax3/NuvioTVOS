import SwiftUI

/// Port of `MetaDetailsScreen`: full-bleed hero with the action row, then the episodes,
/// cast and "More like this" sections.
struct MetaDetailsView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let request: DetailRequest

    @State private var model = MetaDetailsViewModel()
    @State private var logoFailed = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                backdrop(size: proxy.size)

                if model.isLoading && model.meta == nil {
                    NuvioLoadingView(message: "Loading details…")
                } else if let meta = model.meta {
                    content(meta: meta, size: proxy.size)
                } else {
                    ErrorStateView(message: model.error ?? "Unknown error") {
                        Task { await model.load(request: request, addonStore: addons, settings: settings) }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .background(colors.background)
        .task { await model.load(request: request, addonStore: addons, settings: settings) }
    }

    // MARK: Backdrop

    private func backdrop(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            RemoteImage(url: model.meta?.backdropUrl ?? request.heroBackdropUrl, contentMode: .fill) {
                colors.background
            }
            .frame(width: size.width, height: size.height)
            .clipped()

            ModernHeroGradient(background: colors.background, fullScreen: true)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Content

    private func content(meta: Meta, size: CGSize) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxl) {
                hero(meta: meta)
                    .frame(
                        width: size.width * NuvioTheme.layout.detailsHeroWidthFraction,
                        alignment: .bottomLeading
                    )
                    .frame(
                        height: size.height * NuvioTheme.layout.detailsHeroHeightFraction,
                        alignment: .bottomLeading
                    )
                    .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)

                if meta.type == .series, !model.seasons.isEmpty {
                    EpisodesSection(model: model, meta: meta, onPlay: playEpisode)
                }

                if !meta.castMembers.isEmpty {
                    CastSection(members: meta.castMembers)
                }

                if !model.moreLikeThis.isEmpty {
                    CatalogRowView(
                        title: "More like this",
                        items: model.moreLikeThis,
                        showsSeeAll: false,
                        backdropExpandEnabled: false,
                        onSelect: { router.openDetail($0) }
                    )
                }
            }
            .padding(.bottom, NuvioTheme.spacing.rail.tailPadding)
        }
        .scrollClipDisabled()
    }

    // MARK: Hero

    private func hero(meta: Meta) -> some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            Spacer(minLength: 0)

            if let logo = meta.logo?.nilIfBlank, !logoFailed {
                RemoteImage(url: logo, contentMode: .fit, onFailure: { logoFailed = true }) {
                    Color.clear
                }
                .frame(height: dp(110), alignment: .leading)
                .frame(minWidth: dp(120), maxWidth: dp(320), alignment: .leading)
            } else {
                Text(meta.name)
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(2)
            }

            metaRow(meta)

            if let ratings = model.ratings, !ratings.isEmpty {
                RatingsStrip(ratings: ratings)
            }

            if let description = meta.description?.nilIfBlank {
                Text(description)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }

            if !meta.genres.isEmpty {
                Text(meta.genres.prefix(4).joined(separator: " · "))
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
            }

            actionRow(meta)
                .padding(.top, NuvioTheme.spacing.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metaRow(_ meta: Meta) -> some View {
        HStack(spacing: NuvioTheme.spacing.md) {
            if let rating = meta.imdbRating {
                RatingLabel(rating: rating)
            }
            ForEach(metaTokens(meta), id: \.self) { token in
                Text(token)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
            }
            if let age = meta.ageRating?.nilIfBlank {
                NuvioBadge(text: age)
            }
        }
    }

    private func metaTokens(_ meta: Meta) -> [String] {
        var tokens: [String] = []
        if let info = meta.releaseInfo?.nilIfBlank { tokens.append(info) }
        if let runtime = meta.runtime?.nilIfBlank { tokens.append(runtime) }
        if let status = meta.status?.nilIfBlank, meta.type == .series { tokens.append(status) }
        if meta.type == .series, !meta.seasons.isEmpty {
            tokens.append("\(meta.seasons.count) season\(meta.seasons.count == 1 ? "" : "s")")
        }
        return tokens
    }

    private func actionRow(_ meta: Meta) -> some View {
        HStack(spacing: NuvioTheme.spacing.md) {
            Button(action: { play(meta: meta) }) {
                HStack(spacing: NuvioTheme.spacing.sm) {
                    Image(systemName: "play.fill")
                    Text(playLabel(meta))
                }
                .nuvioText(NuvioTextStyles.button)
                .padding(.horizontal, NuvioTheme.spacing.xl)
                .frame(height: NuvioTheme.components.buttonHeight)
            }
            .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))

            Button(action: { library.toggleLibrary(meta.preview()) }) {
                HStack(spacing: NuvioTheme.spacing.sm) {
                    Image(systemName: library.isInLibrary(meta.preview()) ? "checkmark" : "plus")
                    Text(library.isInLibrary(meta.preview()) ? "In Library" : "Add to Library")
                }
                .nuvioText(NuvioTextStyles.button)
                .padding(.horizontal, NuvioTheme.spacing.xl)
                .frame(height: NuvioTheme.components.buttonHeight)
            }
            .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary, selected: library.isInLibrary(meta.preview())))
        }
    }

    private func playLabel(_ meta: Meta) -> String {
        if meta.type == .series {
            if let next = model.nextUpEpisode(library: library, threshold: settings.watchedThreshold),
               let season = next.season, let episode = next.episode {
                return String(format: "Play S%02dE%02d", season, episode)
            }
            return "Play"
        }
        if let progress = library.progress(forVideoId: meta.id), progress.fraction > 0.01 {
            return "Resume"
        }
        return "Play"
    }

    // MARK: Actions

    private func play(meta: Meta) {
        library.cache(meta.preview())
        if meta.type == .series {
            guard let next = model.nextUpEpisode(library: library, threshold: settings.watchedThreshold)
            else { return }
            playEpisode(next)
        } else {
            router.openStreams(StreamRequest(
                videoId: meta.id,
                contentType: meta.apiType,
                title: meta.name,
                contentId: meta.id,
                contentName: meta.name,
                poster: meta.poster,
                backdrop: meta.backdropUrl,
                logo: meta.logo,
                year: meta.releaseInfo
            ))
        }
    }

    private func playEpisode(_ video: Video) {
        guard let meta = model.meta else { return }
        library.cache(meta.preview())
        router.openStreams(streamRequest(for: video, meta: meta))
    }

    private func streamRequest(for video: Video, meta: Meta) -> StreamRequest {
        StreamRequest(
            videoId: video.id,
            contentType: meta.apiType,
            title: meta.name,
            contentId: meta.id,
            contentName: meta.name,
            poster: meta.poster,
            backdrop: video.thumbnail ?? meta.backdropUrl,
            logo: meta.logo,
            season: video.season,
            episode: video.episode,
            episodeName: video.displayTitle,
            year: meta.releaseInfo,
            imdbId: meta.imdbId,
            nextUpVideoId: model.episodeAfter(video)?.id
        )
    }
}

// MARK: - Episodes (port of EpisodesSection)

struct EpisodesSection: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings

    let model: MetaDetailsViewModel
    let meta: Meta
    let onPlay: (Video) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            Text("Episodes")
                .nuvioText(NuvioTextStyles.sectionTitle)
                .foregroundStyle(colors.textPrimary)
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            if model.seasons.count > 1 {
                ChipRow(title: "Season") {
                    ForEach(model.seasons, id: \.self) { season in
                        NuvioChip(
                            label: "Season \(season)",
                            isSelected: model.selectedSeason == season,
                            action: { model.selectedSeason = season }
                        )
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: NuvioTheme.components.row.itemSpacing) {
                    ForEach(model.episodes) { episode in
                        EpisodeCard(
                            video: episode,
                            fallbackImage: meta.backdropUrl,
                            isWatched: library.isWatched(
                                videoId: episode.id,
                                threshold: settings.watchedThreshold
                            ),
                            progress: library.progress(forVideoId: episode.id)?.fraction ?? 0,
                            action: { onPlay(episode) }
                        )
                    }
                }
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
                .padding(.vertical, NuvioTheme.spacing.sm)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

// MARK: - Cast (port of CastSection)

struct CastSection: View {
    @Environment(\.nuvioColors) private var colors
    let members: [MetaCastMember]

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            Text("Cast")
                .nuvioText(NuvioTextStyles.sectionTitle)
                .foregroundStyle(colors.textPrimary)
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: NuvioTheme.spacing.lg) {
                    ForEach(members.prefix(24)) { member in
                        VStack(spacing: NuvioTheme.spacing.sm) {
                            RemoteImage(url: member.photo, contentMode: .fill) {
                                ZStack {
                                    colors.backgroundCard
                                    Image(systemName: "person.fill")
                                        .font(.system(size: NuvioTheme.sizes.icons.xl))
                                        .foregroundStyle(colors.textTertiary)
                                }
                            }
                            .frame(width: NuvioTheme.sizes.avatars.xl, height: NuvioTheme.sizes.avatars.xl)
                            .clipShape(Circle())

                            Text(member.name)
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(colors.textPrimary)
                                .lineLimit(1)

                            if let character = member.character?.nilIfBlank {
                                Text(character)
                                    .nuvioText(NuvioTypography.labelSmall)
                                    .foregroundStyle(colors.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: dp(140))
                    }
                }
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}
