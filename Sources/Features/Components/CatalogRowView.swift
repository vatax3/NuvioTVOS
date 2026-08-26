import SwiftUI

/// One horizontal rail: header + poster run, matching `CatalogRowSection` / `ModernHomeRows`.
/// `focusSection` keeps vertical D-pad travel landing on the nearest card of the next rail
/// instead of jumping to whatever happens to be geometrically closest.
struct CatalogRowView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.posterMetrics) private var metrics
    @Environment(\.navigationFeel) private var feel

    let title: String
    var subtitle: String?
    let items: [MetaPreview]
    var watchedIds: Set<String> = []
    var isLoading: Bool = false
    var showsSeeAll: Bool = true
    /// Rail-local opt-out; the viewer's Layout preference still gates the behaviour.
    var backdropExpandEnabled: Bool = true
    var onFocusItem: ((MetaPreview) -> Void)?
    var onSelect: (MetaPreview) -> Void
    var onSeeAll: (() -> Void)?
    /// Fired when focus nears the tail so the caller can page in more items.
    var onReachEnd: (() -> Void)?
    /// Lets the owning screen drive focus onto a specific card (used for launch focus).
    var cardFocus: FocusState<String?>.Binding?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.row.titleBottomSpacing) {
            header
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            if items.isEmpty && isLoading {
                loadingRun
            } else {
                run
            }
        }
        .padding(.vertical, NuvioTheme.components.row.verticalPadding)
        .focusSection()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: NuvioTheme.spacing.md) {
            Text(title)
                .nuvioText(NuvioTextStyles.sectionTitle)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var run: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: NuvioTheme.components.row.itemSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.rowKey) { index, item in
                        ContentCard(
                            item: item,
                            isWatched: watchedIds.contains(item.rowKey),
                            allowsBackdropExpand: backdropExpandEnabled,
                            onFocus: { focused in
                                onFocusItem?(focused)
                                bringIntoView(focused.rowKey, using: scroller)
                                if index >= items.count - 4 { onReachEnd?() }
                            },
                            focusBinding: cardFocus,
                            action: { onSelect(item) }
                        )
                        .id(item.rowKey)
                    }

                    if showsSeeAll, let onSeeAll {
                        SeeAllCard(action: onSeeAll)
                    }

                    if isLoading && !items.isEmpty {
                        ShimmerView()
                            .frame(width: metrics.width, height: metrics.height)
                            .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
                    }
                }
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
                // The focused card scales to 1.02 and can expand to a backdrop; the extra
                // vertical room stops either from being clipped by the scroll view.
                .padding(.vertical, NuvioTheme.spacing.sm)
            }
            .scrollClipDisabled()
        }
    }

    /// Anchors the focused card at `NuvioLayout.rowAnchor` instead of leaving it wherever the
    /// focus engine parked it — the Compose rails keep the focused item at a fixed offset.
    private func bringIntoView(_ key: String, using scroller: ScrollViewProxy) {
        let anchor = UnitPoint(x: NuvioTheme.layout.rowAnchor, y: 0.5)
        if let animation = feel.scrollAnimation {
            withAnimation(animation) { scroller.scrollTo(key, anchor: anchor) }
        } else {
            scroller.scrollTo(key, anchor: anchor)
        }
    }

    private var loadingRun: some View {
        HStack(spacing: NuvioTheme.components.row.itemSpacing) {
            ForEach(0..<8, id: \.self) { _ in
                ShimmerView()
                    .frame(width: metrics.width, height: metrics.height)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
            }
        }
        .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
    }
}

/// Trailing affordance that opens the full catalog grid.
struct SeeAllCard: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.posterMetrics) private var metrics
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: NuvioTheme.spacing.sm) {
                Image(systemName: "arrow.right")
                    .font(.system(size: NuvioTheme.sizes.icons.lg))
                Text(L10n.text("row.see_all", fallback: "See all"))
                    .nuvioText(NuvioTextStyles.button)
            }
            .foregroundStyle(colors.textSecondary)
            .frame(width: metrics.width, height: metrics.height)
            .background(colors.backgroundCard)
        }
        .buttonStyle(NuvioCardButtonStyle(cornerRadius: metrics.cornerRadius))
    }
}

/// Continue Watching rail — separate because its cards carry progress and a different shape.
struct ContinueWatchingRow: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    let entries: [ContinueWatchingEntry]
    var style: ContinueWatchingCardStyle = .landscape
    var onFocusItem: ((MetaPreview) -> Void)?
    var onSelect: (ContinueWatchingEntry) -> Void
    var cardFocus: FocusState<String?>.Binding?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.row.titleBottomSpacing) {
            Text(L10n.text("library.continue_watching", fallback: "Continue Watching"))
                .nuvioText(NuvioTextStyles.sectionTitle)
                .foregroundStyle(colors.textPrimary)
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: NuvioTheme.components.row.itemSpacing) {
                    ForEach(entries) { entry in
                        ContinueWatchingCard(
                            entry: entry,
                            style: style,
                            usesEpisodeThumbnail: settings.layout.useEpisodeThumbnailsInContinueWatching,
                            blursNextUp: settings.layout.blurContinueWatchingNextUp,
                            onFocus: onFocusItem,
                            focusBinding: cardFocus,
                            action: { onSelect(entry) }
                        )
                    }
                }
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
                .padding(.vertical, NuvioTheme.spacing.sm)
            }
            .scrollClipDisabled()
        }
        .padding(.vertical, NuvioTheme.components.row.verticalPadding)
        .focusSection()
    }
}

// MARK: - Empty & error states

/// Port of `EmptyScreenState`.
struct EmptyStateView: View {
    @Environment(\.nuvioColors) private var colors
    var systemImage: String = "tray"
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: NuvioTheme.spacing.lg) {
            Image(systemName: systemImage)
                .font(.system(size: NuvioTheme.sizes.icons.xl * 1.6))
                .foregroundStyle(colors.textTertiary)
            Text(title)
                .nuvioText(NuvioTextStyles.headline)
                .foregroundStyle(colors.textPrimary)
            if let message {
                Text(message)
                    .nuvioText(NuvioTextStyles.body)
                    .foregroundStyle(colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: dp(520))
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .nuvioText(NuvioTextStyles.button)
                        .padding(.horizontal, NuvioTheme.spacing.xl)
                        .padding(.vertical, NuvioTheme.spacing.md)
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))
                .padding(.top, NuvioTheme.spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Port of `ErrorState`.
struct ErrorStateView: View {
    @Environment(\.nuvioColors) private var colors
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: NuvioTheme.spacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: NuvioTheme.sizes.icons.xl * 1.4))
                .foregroundStyle(colors.error)
            Text(L10n.text("row.failed", fallback: "Something went wrong"))
                .nuvioText(NuvioTextStyles.headline)
                .foregroundStyle(colors.textPrimary)
            Text(message)
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: dp(560))
            if let retry {
                Button(action: retry) {
                    Text("Retry")
                        .nuvioText(NuvioTextStyles.button)
                        .padding(.horizontal, NuvioTheme.spacing.xl)
                        .padding(.vertical, NuvioTheme.spacing.md)
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Port of `LoadingIndicator`.
struct NuvioLoadingView: View {
    @Environment(\.nuvioColors) private var colors
    var message: String?

    var body: some View {
        VStack(spacing: NuvioTheme.spacing.lg) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(colors.secondary)
                .scaleEffect(1.6)
            if let message {
                Text(message)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
