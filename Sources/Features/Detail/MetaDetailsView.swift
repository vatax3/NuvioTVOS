import SwiftUI

/// Port of `MetaDetailsScreen`: full-bleed hero with the action row, then the episodes,
/// cast and "More like this" sections.
struct MetaDetailsView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(LibraryStore.self) private var library
    @Environment(CollectionStore.self) private var collections
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    let request: DetailRequest

    @State private var model = MetaDetailsViewModel()
    @State private var logoFailed = false
    @State private var collectionTarget: MetaPreview?

    private func collectionCount(_ meta: Meta) -> Int {
        collections.collections(containing: meta.preview()).count
    }

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
        .sheet(item: $collectionTarget) { preview in
            CollectionPickerView(preview: preview)
        }
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

                // Every card in this rail hands off to the YouTube app, so with the app absent
                // the whole rail is dead weight — and worse, a section the focus engine has to
                // step over. Drop it rather than draw it.
                if TrailerLauncher.isAvailable, !trailerItems(meta).isEmpty {
                    TrailerSection(trailers: trailerItems(meta))
                }

                if !meta.castMembers.isEmpty {
                    CastSection(members: meta.castMembers)
                }

                if !meta.networks.isEmpty {
                    CompanySection(
                        title: "Networks",
                        companies: meta.networks,
                        contentType: meta.apiType,
                        isNetwork: true
                    )
                }

                if !meta.productionCompanies.isEmpty {
                    CompanySection(
                        title: "Studios",
                        companies: meta.productionCompanies,
                        contentType: meta.apiType,
                        isNetwork: false
                    )
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
        if let info = meta.preview().releaseLabel(fullDate: settings.layout.showFullReleaseDate) {
            tokens.append(info)
        }
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

            Button(action: { collectionTarget = meta.preview() }) {
                HStack(spacing: NuvioTheme.spacing.sm) {
                    Image(systemName: collectionCount(meta) > 0 ? "folder.fill" : "folder.badge.plus")
                    Text(collectionCount(meta) > 0 ? "In \(collectionCount(meta)) collection\(collectionCount(meta) == 1 ? "" : "s")" : "Collections")
                }
                .nuvioText(NuvioTextStyles.button)
                .padding(.horizontal, NuvioTheme.spacing.xl)
                .frame(height: NuvioTheme.components.buttonHeight)
            }
            .buttonStyle(NuvioPillButtonStyle(
                emphasis: .secondary,
                selected: collectionCount(meta) > 0
            ))

            if settings.tracking.showMetaComments,
               !settings.tracking.traktClientId.isEmpty,
               let imdbId = meta.imdbId?.nilIfBlank ?? (meta.id.hasPrefix("tt") ? meta.id : nil) {
                Button(action: {
                    router.push(.comments(CommentsRequest(
                        imdbId: imdbId, contentType: meta.apiType, title: meta.name
                    )))
                }) {
                    HStack(spacing: NuvioTheme.spacing.sm) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        Text("Comments")
                    }
                    .nuvioText(NuvioTextStyles.button)
                    .padding(.horizontal, NuvioTheme.spacing.xl)
                    .frame(height: NuvioTheme.components.buttonHeight)
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
            }

            if settings.layout.detailPageTrailerButtonEnabled, let trailer = trailerYouTubeId(meta) {
                Button(action: { TrailerLauncher.open(youTubeId: trailer) }) {
                    HStack(spacing: NuvioTheme.spacing.sm) {
                        Image(systemName: "film")
                        Text("Trailer")
                    }
                    .nuvioText(NuvioTextStyles.button)
                    .padding(.horizontal, NuvioTheme.spacing.xl)
                    .frame(height: NuvioTheme.components.buttonHeight)
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
                .disabled(!TrailerLauncher.isAvailable)
            }
        }
    }

    /// Stremio and TMDB both hand back YouTube ids; either source is fine.
    /// Every trailer the metadata carries, addon entries first so their names and languages
    /// survive, then any bare TMDB id that was not already covered.
    private func trailerItems(_ meta: Meta) -> [TrailerItem] {
        var seen = Set<String>()
        var items: [TrailerItem] = []
        for trailer in meta.trailers {
            guard let id = (trailer.ytId?.nilIfBlank ?? trailer.source?.nilIfBlank),
                  seen.insert(id).inserted else { continue }
            items.append(TrailerItem(youTubeId: id, name: trailer.name?.nilIfBlank, kind: trailer.type?.nilIfBlank, language: trailer.lang?.nilIfBlank))
        }
        for id in meta.trailerYtIds {
            guard let id = id.nilIfBlank, seen.insert(id).inserted else { continue }
            items.append(TrailerItem(youTubeId: id, name: nil, kind: nil, language: nil))
        }
        return items
    }

    private func trailerYouTubeId(_ meta: Meta) -> String? {
        meta.trailerYtIds.first?.nilIfBlank
            ?? meta.trailers.compactMap { $0.ytId?.nilIfBlank ?? $0.source?.nilIfBlank }.first
    }

    private func playLabel(_ meta: Meta) -> String {
        if meta.type == .series {
            if let next = model.nextUpEpisode(
                library: library,
                threshold: settings.watchedThreshold,
                fromFurthest: settings.layout.nextUpFromFurthestEpisode,
                includeUnaired: settings.layout.showUnairedNextUp
            ),
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
            guard let next = model.nextUpEpisode(
                library: library,
                threshold: settings.watchedThreshold,
                fromFurthest: settings.layout.nextUpFromFurthestEpisode,
                includeUnaired: settings.layout.showUnairedNextUp
            )
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
                year: meta.releaseInfo,
                imdbId: meta.imdbId
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
                            blursUnwatched: settings.layout.blurUnwatchedEpisodes,
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
        // Cache the stills so the Continue Watching rail can show the episode the viewer
        // stopped on rather than the series backdrop.
        .onChange(of: model.episodes, initial: true) { _, episodes in
            for episode in episodes {
                library.cacheEpisodeThumbnail(episode.thumbnail, forVideoId: episode.id)
            }
        }
    }
}

// MARK: - Trailers (port of TrailerSection)

struct TrailerItem: Identifiable, Hashable {
    let youTubeId: String
    let name: String?
    let kind: String?
    let language: String?

    var id: String { youTubeId }

    var title: String { name ?? kind?.capitalized ?? L10n.text("detail.trailer") }

    var subtitle: String? {
        [kind?.capitalized, language?.uppercased()].compactMap { $0 }.joined(separator: " • ").nilIfBlank
    }

    /// YouTube serves a still for any video id at a stable path, so a trailer row needs no
    /// extra metadata request to have artwork.
    var thumbnailURL: String { "https://img.youtube.com/vi/\(youTubeId)/hqdefault.jpg" }
}

/// The landscape trailer rail from the Android detail screen.
///
/// The cards hand off to the YouTube app rather than playing in place: the ids are YouTube
/// watch ids and AVFoundation has no way to turn one into a stream. Android resolves them
/// through its own InnerTube extractor, which is the piece that would have to be ported for
/// playback to happen on this screen.
struct TrailerSection: View {
    @Environment(\.nuvioColors) private var colors
    let trailers: [TrailerItem]

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            Text(L10n.text("detail.trailers"))
                .nuvioText(NuvioTextStyles.sectionTitle)
                .foregroundStyle(colors.textPrimary)
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: NuvioTheme.spacing.lg) {
                    ForEach(trailers) { trailer in
                        TrailerCard(trailer: trailer)
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

private struct TrailerCard: View {
    @Environment(\.nuvioColors) private var colors
    let trailer: TrailerItem

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            Button(action: { TrailerLauncher.open(youTubeId: trailer.youTubeId) }) {
                ZStack {
                    RemoteImage(url: trailer.thumbnailURL, contentMode: .fill) {
                        colors.backgroundCard
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: NuvioTheme.sizes.icons.xl))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.6), radius: dp(4))
                }
                .frame(width: dp(260), height: dp(146))
                .clipped()
            }
            .buttonStyle(NuvioCardButtonStyle(cornerRadius: NuvioTheme.spacing.md))

            Text(trailer.title)
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)
            if let subtitle = trailer.subtitle {
                Text(subtitle)
                    .nuvioText(NuvioTypography.labelSmall)
                    .foregroundStyle(colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: dp(260), alignment: .leading)
    }
}

// MARK: - Cast (port of CastSection)

struct CastSection: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(Router.self) private var router
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
                        CastMemberCard(member: member) {
                            // Only TMDB-sourced members carry an id, and the detail screen is
                            // entirely TMDB-backed — a plain addon credit has nowhere to go.
                            guard let tmdbId = member.tmdbId else { return }
                            router.push(.castMember(CastRequest(
                                tmdbId: tmdbId, name: member.name, photo: member.photo
                            )))
                        }
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

private struct CastMemberCard: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.cardDepth) private var depth

    let member: MetaCastMember
    let action: () -> Void

    @State private var isFocused = false

    private var isNavigable: Bool { member.tmdbId != nil }

    var body: some View {
        VStack(spacing: NuvioTheme.spacing.sm) {
            Button(action: action) {
                RemoteImage(url: member.photo, contentMode: .fill) {
                    ZStack {
                        colors.backgroundCard
                        Image(systemName: "person.fill")
                            .font(.system(size: NuvioTheme.sizes.icons.xl))
                            .foregroundStyle(colors.textTertiary)
                    }
                }
                .frame(width: NuvioTheme.sizes.avatars.xl, height: NuvioTheme.sizes.avatars.xl)
                .background(colors.backgroundCard)
                .cardDepth(.cast, cornerRadius: NuvioTheme.sizes.avatars.xl / 2)
            }
            .buttonStyle(NuvioCardButtonStyle(cornerRadius: NuvioTheme.sizes.avatars.xl / 2))
            .onFocusChange { isFocused = $0 }
            // Credits keep their focus even with nowhere to go. Disabling them looks harmless
            // one card at a time, but an addon that supplies no TMDB ids — Cinemeta, for one —
            // disables every card in the row at once, and a row with nothing focusable in it is
            // a row the focus engine steps straight over: pressing Down past the episodes
            // landed on More like this and the cast could be seen but never reached. Select on
            // a credit with no id is already a no-op in `action`.

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

// MARK: - Networks & studios

/// Logos from the TMDB enrichment, each opening that entity's catalogue.
struct CompanySection: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(Router.self) private var router

    let title: String
    let companies: [MetaCompany]
    let contentType: String
    /// Networks and production companies are different TMDB `discover` filters.
    let isNetwork: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            Text(title)
                .nuvioText(NuvioTextStyles.sectionTitle)
                .foregroundStyle(colors.textPrimary)
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: NuvioTheme.spacing.lg) {
                    ForEach(companies) { company in
                        CompanyCard(company: company) {
                            guard let tmdbId = company.tmdbId else { return }
                            router.push(.tmdbBrowse(TMDBBrowseRequest(
                                entity: isNetwork ? .network(tmdbId) : .company(tmdbId),
                                title: company.name,
                                contentType: contentType,
                                logo: company.logo
                            )))
                        }
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

private struct CompanyCard: View {
    @Environment(\.nuvioColors) private var colors

    let company: MetaCompany
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: NuvioTheme.spacing.sm) {
                if let logo = company.logo?.nilIfBlank {
                    RemoteImage(url: logo, contentMode: .fit) { Color.clear }
                        .frame(height: dp(44))
                        .padding(.horizontal, NuvioTheme.spacing.md)
                } else {
                    Text(company.name)
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, NuvioTheme.spacing.md)
                }
            }
            .frame(width: dp(180), height: dp(90))
            .background(colors.backgroundCard)
        }
        .buttonStyle(NuvioCardButtonStyle(cornerRadius: NuvioTheme.radii.md))
        .disabled(company.tmdbId == nil)
    }
}
