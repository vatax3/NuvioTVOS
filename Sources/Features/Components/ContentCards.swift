import SwiftUI

// MARK: - Poster card (port of ContentCard.kt)

struct ContentCard: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.posterMetrics) private var metrics

    let item: MetaPreview
    var isWatched: Bool = false
    /// Rails may suppress the expansion locally (the Grid layout does); the viewer's Layout
    /// preference still has the final say.
    var allowsBackdropExpand: Bool = true
    var onFocus: ((MetaPreview) -> Void)?
    /// `.focused()` only has an effect on the focusable view itself, so callers hand the
    /// binding down to the card rather than wrapping it from outside.
    var focusBinding: FocusState<String?>.Binding?
    var action: () -> Void

    @State private var isFocused = false
    @State private var isExpanded = false
    @State private var logoFailed = false
    @State private var expandTask: Task<Void, Never>?

    private var showLabels: Bool { metrics.showsLabels }
    private var backdropExpandEnabled: Bool { allowsBackdropExpand && metrics.backdropExpandEnabled }
    private var cornerRadius: CGFloat { metrics.cornerRadius }
    private var shape: PosterShape { metrics.resolvedShape(for: item.posterShape) }
    private var baseSize: CGSize { metrics.size(for: shape) }
    private var baseHeight: CGFloat { baseSize.height }

    private var expandedWidth: CGFloat { baseHeight * NuvioTheme.media.backdropAspectRatio }
    private var cardWidth: CGFloat { isExpanded ? expandedWidth : baseSize.width }
    /// A landscape rail already shows the backdrop, so it never falls back to the poster.
    private var imageURL: String? {
        if isExpanded || shape == .landscape {
            return item.backdropUrl ?? item.poster
        }
        return item.poster
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                artwork
            }
            .buttonStyle(NuvioCardButtonStyle(cornerRadius: cornerRadius))
            .focusedIfAvailable(focusBinding, equals: item.rowKey)
            .onFocusChange { focused in
                guard focused != isFocused else { return }
                isFocused = focused
                if focused {
                    onFocus?(item)
                    scheduleExpand()
                } else {
                    cancelExpand()
                }
            }

            if showLabels {
                labels
                    .padding(.top, NuvioTheme.spacing.sm)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        .animation(NuvioMotion.mediumTween, value: isExpanded)
        .onDisappear { cancelExpand() }
    }

    // MARK: Artwork

    private var artwork: some View {
        ZStack(alignment: .topTrailing) {
            RemoteImage(url: imageURL, contentMode: .fill) {
                PosterPlaceholder()
            }
            .frame(width: cardWidth, height: baseHeight)
            .clipped()

            if isExpanded {
                expandedOverlay
            }

            if isWatched {
                watchedBadge
            }
        }
        .frame(width: cardWidth, height: baseHeight)
        .background(colors.backgroundCard)
        .cardDepth(.poster, cornerRadius: cornerRadius)
    }

    private var expandedOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.76)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: dp(96))
            .frame(maxHeight: .infinity, alignment: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                if let logo = item.logo?.nilIfBlank, !logoFailed {
                    RemoteImage(url: logo, contentMode: .fit, onFailure: { logoFailed = true }) {
                        Color.clear
                    }
                    .frame(height: NuvioTheme.spacing.xxxl, alignment: .leading)
                } else {
                    FocusMarqueeText(
                        text: item.name,
                        style: NuvioTextStyles.cardTitle,
                        color: .white,
                        isFocused: isFocused
                    )
                }
            }
            .frame(width: cardWidth * 0.75, alignment: .leading)
            .padding(.horizontal, NuvioTheme.spacing.md)
            .padding(.bottom, NuvioTheme.spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    private var watchedBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: dp(13), weight: .bold))
            .foregroundStyle(colors.secondary == ThemeColors.white.secondary ? .black : .white)
            .frame(width: dp(21), height: dp(21))
            .background(colors.secondary, in: Circle())
            .padding(.top, NuvioTheme.spacing.sm)
            .padding(.trailing, NuvioTheme.spacing.sm)
    }

    // MARK: Labels

    @ViewBuilder
    private var labels: some View {
        if isExpanded {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                if !metaTokens.isEmpty {
                    Text(metaTokens.joined(separator: "  •  "))
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(1)
                }
                if let description = item.description?.nilIfBlank {
                    Text(description)
                        .nuvioText(NuvioTypography.bodySmall)
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                FocusMarqueeText(
                    text: item.name,
                    style: NuvioTextStyles.cardTitle,
                    color: colors.textPrimary,
                    isFocused: isFocused
                )
                if let info = item.releaseLabel(fullDate: metrics.showsFullReleaseDate) {
                    FocusMarqueeText(
                        text: info,
                        style: NuvioTextStyles.metadata,
                        color: colors.textSecondary,
                        isFocused: isFocused
                    )
                }
                if backdropExpandEnabled {
                    Spacer().frame(height: dp(15))
                }
            }
        }
    }

    private var metaTokens: [String] {
        var tokens: [String] = []
        if let info = item.releaseLabel(fullDate: metrics.showsFullReleaseDate) { tokens.append(info) }
        if let rating = item.imdbRating { tokens.append(String(format: "★ %.1f", rating)) }
        if let runtime = item.runtime?.nilIfBlank { tokens.append(runtime) }
        if let genre = item.genres.first { tokens.append(genre) }
        return tokens
    }

    // MARK: Expand timing

    private func scheduleExpand() {
        guard backdropExpandEnabled, item.backdropUrl != nil else { return }
        cancelExpand()
        expandTask = Task {
            try? await Task.sleep(for: .seconds(max(0, metrics.backdropExpandDelay)))
            guard !Task.isCancelled, isFocused else { return }
            isExpanded = true
        }
    }

    private func cancelExpand() {
        expandTask?.cancel()
        expandTask = nil
        if isExpanded { isExpanded = false }
    }
}

// MARK: - Continue Watching card (port of ContinueWatchingSection)

struct ContinueWatchingCard: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.posterMetrics) private var metrics

    let entry: ContinueWatchingEntry
    var style: ContinueWatchingCardStyle = .landscape
    /// `use_episode_thumbnails_in_cw`: prefer the episode still over the series artwork.
    var usesEpisodeThumbnail: Bool = true
    /// `blur_continue_watching_next_up`: hide the still for an episode not yet started.
    var blursNextUp: Bool = false
    var onFocus: ((MetaPreview) -> Void)?
    var focusBinding: FocusState<String?>.Binding?
    var action: () -> Void

    @State private var isFocused = false

    private var tokens: NuvioCardComponentTokens { NuvioTheme.components.continueWatchingCard }

    private var cardWidth: CGFloat {
        style == .landscape ? tokens.width : metrics.width
    }

    private var cardHeight: CGFloat {
        style == .landscape ? tokens.height : metrics.height
    }

    private var artworkURL: String? {
        if usesEpisodeThumbnail, let thumbnail = entry.episodeThumbnail?.nilIfBlank {
            return thumbnail
        }
        return style == .landscape
            ? (entry.preview.backdropUrl ?? entry.preview.poster)
            : (entry.preview.poster ?? entry.preview.backdropUrl)
    }

    /// Only blur what the viewer has not begun — a resumed episode is not a spoiler.
    private var shouldBlur: Bool { blursNextUp && entry.isNextUp }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: artworkURL, contentMode: .fill) {
                        PosterPlaceholder()
                    }
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
                    .spoilerBlur(active: shouldBlur, revealed: isFocused)

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.85)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                        Spacer()
                        HStack(spacing: NuvioTheme.spacing.sm) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(.white)
                            if let episodeTitle = entry.episodeTitle {
                                Text(episodeTitle)
                                    .nuvioText(NuvioTextStyles.metadata)
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            Spacer()
                            Text(remainingLabel)
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        WatchProgressBar(fraction: entry.progress.fraction)
                    }
                    .padding(tokens.contentPadding)
                }
                .frame(width: cardWidth, height: cardHeight)
                .background(colors.backgroundCard)
                .cardDepth(.continueWatching, cornerRadius: tokens.cornerRadius)
            }
            .buttonStyle(NuvioCardButtonStyle(cornerRadius: tokens.cornerRadius))
            .focusedIfAvailable(focusBinding, equals: entry.preview.rowKey)
            .onFocusChange { focused in
                isFocused = focused
                if focused { onFocus?(entry.preview) }
            }

            VStack(alignment: .leading, spacing: 0) {
                FocusMarqueeText(
                    text: entry.preview.name,
                    style: NuvioTextStyles.cardTitle,
                    color: colors.textPrimary,
                    isFocused: isFocused
                )
            }
            .padding(.top, NuvioTheme.spacing.sm)
            .frame(width: cardWidth, alignment: .leading)
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private var remainingLabel: String {
        let remaining = Int(entry.progress.remainingSeconds / 60)
        return remaining > 0 ? "\(remaining) min left" : "Almost done"
    }
}

// MARK: - Episode card (port of EpisodesSection cards)

struct EpisodeCard: View {
    @Environment(\.nuvioColors) private var colors

    let video: Video
    var fallbackImage: String?
    var isWatched: Bool = false
    var progress: Double = 0
    /// `blur_unwatched_episodes`: the still stays hidden until the card is focused.
    var blursUnwatched: Bool = false
    var action: () -> Void

    @State private var isFocused = false

    private var tokens: NuvioCardComponentTokens { NuvioTheme.components.episodeCard }

    private var shouldBlur: Bool { blursUnwatched && !isWatched && progress <= 0.01 }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: video.thumbnail ?? fallbackImage, contentMode: .fill) {
                        PosterPlaceholder(systemImage: "tv")
                    }
                    .frame(width: tokens.width, height: tokens.width / NuvioTheme.media.thumbnailAspectRatio)
                    .clipped()
                    .spoilerBlur(active: shouldBlur, revealed: isFocused)

                    if progress > 0.01 {
                        WatchProgressBar(fraction: progress)
                            .padding(.horizontal, NuvioTheme.spacing.sm)
                            .padding(.bottom, NuvioTheme.spacing.sm)
                    }

                    if isWatched {
                        Image(systemName: "checkmark")
                            .font(.system(size: dp(13), weight: .bold))
                            .foregroundStyle(colors.secondary == ThemeColors.white.secondary ? .black : .white)
                            .frame(width: dp(21), height: dp(21))
                            .background(colors.secondary, in: Circle())
                            .padding(NuvioTheme.spacing.sm)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .frame(width: tokens.width, height: tokens.width / NuvioTheme.media.thumbnailAspectRatio)
                .background(colors.backgroundCard)
                .cardDepth(.episode, cornerRadius: tokens.cornerRadius)
            }
            .buttonStyle(NuvioCardButtonStyle(cornerRadius: tokens.cornerRadius))
            .onFocusChange { isFocused = $0 }

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                HStack(spacing: NuvioTheme.spacing.sm) {
                    if let episode = video.episode {
                        Text("\(episode)")
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.secondary)
                    }
                    FocusMarqueeText(
                        text: video.displayTitle,
                        style: NuvioTextStyles.cardTitle,
                        color: colors.textPrimary,
                        isFocused: isFocused
                    )
                }
                if let overview = video.displayOverview?.nilIfBlank {
                    Text(overview)
                        .nuvioText(NuvioTypography.bodySmall)
                        .foregroundStyle(colors.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(width: tokens.width, alignment: .leading)
        }
        .frame(width: tokens.width, alignment: .leading)
    }
}

// MARK: - Skeleton

struct PosterSkeletonRow: View {
    @Environment(\.posterMetrics) private var metrics
    var count: Int = 8
    var showsTitle: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.row.titleBottomSpacing) {
            if showsTitle {
                ShimmerView()
                    .frame(width: dp(180), height: dp(24))
                    .clipShape(RoundedRectangle(cornerRadius: NuvioTheme.components.skeletonCornerRadius))
                    .padding(.leading, NuvioTheme.components.row.horizontalPadding)
            }
            HStack(spacing: NuvioTheme.components.row.itemSpacing) {
                ForEach(0..<count, id: \.self) { _ in
                    ShimmerView()
                        .frame(width: metrics.width, height: metrics.height)
                        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
                }
            }
            .padding(.leading, NuvioTheme.components.row.horizontalPadding)
        }
    }
}
