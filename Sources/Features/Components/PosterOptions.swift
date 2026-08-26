import SwiftUI

/// What a long press on a poster offers.
///
/// Android TV puts library and watched state behind this one gesture, reachable from every rail
/// and every grid. It matters more here than the feature list suggests: without it, a resume
/// point could be created from anywhere and removed from nowhere — `LibraryStore.clearProgress`
/// existed for releases with no caller in the interface at all.
enum PosterOptionsPolicy {
    enum Action: String, Identifiable, Hashable, CaseIterable {
        case addToLibrary
        case removeFromLibrary
        case markWatched
        case markUnwatched
        case removeFromContinueWatching
        case dismissNextUp
        case openDetails

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .addToLibrary: return "plus"
            case .removeFromLibrary: return "checkmark"
            case .markWatched: return "eye.fill"
            case .markUnwatched: return "eye.slash"
            case .removeFromContinueWatching: return "xmark"
            case .dismissNextUp: return "bell.slash"
            case .openDetails: return "info.circle"
            }
        }

        /// Whether choosing it undoes something the viewer built up, which the dialog marks so
        /// the destructive entry is not one indistinguishable row among six.
        var isDestructive: Bool {
            self == .removeFromLibrary || self == .removeFromContinueWatching
                || self == .markUnwatched || self == .dismissNextUp
        }
    }

    struct Context: Equatable {
        var type: ContentType
        var isInLibrary: Bool
        var isWatched: Bool
        /// Whether the title has a resume point — which is what makes it removable.
        var hasProgress: Bool
        /// Whether this card is a *suggestion* rather than something part-watched, which is the
        /// only case where "stop offering this" means anything.
        var isNextUpSuggestion: Bool = false
    }

    /// The rows, in the order they are drawn.
    ///
    /// Watched is offered for films only, and deliberately. Upstream carries two separate paths
    /// — one per film, one that walks a whole series — and marking a series watched here would
    /// have to enumerate every episode to write the same local state the episode list writes
    /// one row at a time. Offering a control that silently does less than it says is worse than
    /// not offering it, so the series case is left to the detail screen until the walk exists.
    static func actions(for context: Context) -> [Action] {
        var actions: [Action] = [context.isInLibrary ? .removeFromLibrary : .addToLibrary]

        if context.type == .movie {
            actions.append(context.isWatched ? .markUnwatched : .markWatched)
        }
        if context.isNextUpSuggestion {
            // Nothing has been watched of it, so there is no resume point to remove — what the
            // viewer wants gone is the suggestion.
            actions.append(.dismissNextUp)
        } else if context.hasProgress {
            actions.append(.removeFromContinueWatching)
        }
        actions.append(.openDetails)
        return actions
    }
}

/// The title a long press was made on. Identifiable so the presentation is driven by the item
/// rather than a boolean plus a separate payload, which would flicker the wrong poster's name
/// during the dismissal animation.
struct PosterOptionsRequest: Identifiable, Hashable {
    var preview: MetaPreview
    /// Set by the Continue Watching rail for a row it projected rather than one the viewer
    /// started. Only those can be dismissed — there is no resume point to remove.
    var isNextUpSuggestion: Bool = false
    var id: String { preview.rowKey }
}

struct PosterOptionsDialog: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router
    /// Its own instance: the service is per-screen state elsewhere too, and the dialog
    /// outlives none of its writes — each one is fired and reported by `lastResult` nowhere.
    @State private var tracking = TrackingWriteService()

    let request: PosterOptionsRequest
    let onDismiss: () -> Void

    @FocusState private var focused: PosterOptionsPolicy.Action?

    private var preview: MetaPreview { request.preview }

    private var context: PosterOptionsPolicy.Context {
        .init(
            type: preview.type,
            isInLibrary: library.isInLibrary(preview),
            isWatched: library.isWatched(videoId: preview.id, threshold: settings.watchedThreshold),
            hasProgress: hasProgress,
            isNextUpSuggestion: request.isNextUpSuggestion
        )
    }

    /// A series is in Continue Watching through whichever episode is in flight, so the removal
    /// has to look at the whole title rather than a single video id.
    private var hasProgress: Bool {
        preview.type == .movie
            ? library.progress(forVideoId: preview.id) != nil
            : library.continueWatching(threshold: settings.watchedThreshold)
                .contains { $0.preview.id == preview.id }
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
                    ForEach(PosterOptionsPolicy.actions(for: context)) { action in
                        row(action)
                    }
                }
            }
            .padding(NuvioTheme.spacing.xl)
            .frame(width: dp(360), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: NuvioTheme.radii.xl, style: .continuous)
                    .fill(colors.backgroundElevated)
            )
        }
        .focusSection()
        .onExitCommand(perform: onDismiss)
        .onAppear { focused = PosterOptionsPolicy.actions(for: context).first }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
            Text(preview.name)
                .nuvioText(NuvioTypography.headlineLarge)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(2)

            if let subtitle = preview.releaseInfo?.nilIfBlank {
                Text(subtitle)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)
            }
        }
    }

    private func row(_ action: PosterOptionsPolicy.Action) -> some View {
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

    private func label(_ action: PosterOptionsPolicy.Action) -> String {
        switch action {
        case .addToLibrary: return L10n.text("poster_options.add_to_library")
        case .removeFromLibrary: return L10n.text("poster_options.remove_from_library")
        case .markWatched: return L10n.text("poster_options.mark_watched")
        case .markUnwatched: return L10n.text("poster_options.mark_unwatched")
        case .removeFromContinueWatching: return L10n.text("poster_options.remove_from_continue_watching")
        case .dismissNextUp: return L10n.text("poster_options.dismiss_next_up")
        case .openDetails: return L10n.text("poster_options.go_to_details")
        }
    }

    private func perform(_ action: PosterOptionsPolicy.Action) {
        switch action {
        case .addToLibrary, .removeFromLibrary:
            library.toggleLibrary(preview)
            let added = library.isInLibrary(preview)
            Task { await tracking.library(preview, added: added, settings: settings) }

        case .markWatched, .markUnwatched:
            let watched = action == .markWatched
            markMovie(watched: watched)

        case .removeFromContinueWatching:
            // By content id rather than video id: for a series the resume point sits on an
            // episode the viewer never named, and removing the row means removing all of them.
            library.clearProgress(contentId: preview.id)

        case .dismissNextUp:
            settings.layout.dismissedNextUpKeys = NextUpDismissal.adding(
                contentId: preview.id, to: settings.layout.dismissedNextUpKeys
            )

        case .openDetails:
            router.openDetail(preview)
        }
        onDismiss()
    }

    private func markMovie(watched: Bool) {
        if watched {
            // A film with no resume point has no measured runtime here, so the local record is
            // written against whatever the addon published — the store only compares a fraction.
            let duration = library.progress(forVideoId: preview.id)?.durationSeconds ?? 1
            library.markWatched(
                contentId: preview.id,
                contentType: preview.rawType,
                videoId: preview.id,
                season: nil,
                episode: nil,
                duration: duration
            )
        } else {
            library.clearProgress(videoId: preview.id)
        }

        guard let imdb = preview.imdbId?.nilIfBlank else { return }
        Task {
            await tracking.watched(
                imdbId: imdb,
                trackingIds: preview.trackingIds,
                title: preview.name,
                year: preview.year,
                type: preview.type,
                season: nil,
                episode: nil,
                removing: !watched,
                settings: settings
            )
        }
    }
}
