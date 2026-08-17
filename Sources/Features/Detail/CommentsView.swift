import SwiftUI
import Observation

/// Trakt comments and reviews for one title. Spoiler-marked comments stay hidden until the
/// viewer chooses to reveal them, which is the whole point of the flag.
struct CommentsView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    let imdbId: String
    let contentType: String
    let title: String

    @State private var model = CommentsViewModel()

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
                    Text("Comments")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    Text(title)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)

                    sortChips

                    if model.isLoading && model.comments.isEmpty {
                        NuvioLoadingView()
                            .frame(height: dp(240))
                    } else if model.comments.isEmpty {
                        EmptyStateView(
                            systemImage: "bubble.left.and.bubble.right",
                            title: "No comments",
                            message: model.error ?? "Nobody has posted about this on Trakt yet."
                        )
                        .frame(height: dp(280))
                    } else {
                        ForEach(model.comments) { comment in
                            CommentCard(comment: comment)
                        }

                        if model.canLoadMore {
                            Button(action: {
                                Task {
                                    await model.loadMore(
                                        imdbId: imdbId, contentType: contentType, settings: settings
                                    )
                                }
                            }) {
                                Text(model.isLoading ? "Loading…" : "Load more")
                                    .nuvioText(NuvioTextStyles.button)
                                    .padding(.horizontal, NuvioTheme.spacing.xl)
                                    .frame(height: NuvioTheme.components.buttonHeight)
                            }
                            .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
                        }
                    }
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
        .task {
            await model.load(imdbId: imdbId, contentType: contentType, settings: settings)
        }
    }

    private var sortChips: some View {
        ChipRow(title: "Sort") {
            ForEach(CommentsViewModel.Sort.allCases) { option in
                NuvioChip(
                    label: option.title,
                    isSelected: model.sort == option,
                    action: {
                        Task {
                            await model.setSort(
                                option, imdbId: imdbId, contentType: contentType, settings: settings
                            )
                        }
                    }
                )
            }
        }
    }
}

private struct CommentCard: View {
    @Environment(\.nuvioColors) private var colors

    let comment: TraktClient.Comment

    @State private var isRevealed = false

    private var isHidden: Bool { comment.isSpoiler && !isRevealed }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
            HStack(spacing: NuvioTheme.spacing.md) {
                RemoteImage(url: comment.avatar, contentMode: .fill) {
                    ZStack {
                        colors.surfaceVariant
                        Image(systemName: "person.fill")
                            .font(.system(size: NuvioTheme.sizes.icons.sm))
                            .foregroundStyle(colors.textTertiary)
                    }
                }
                .frame(width: dp(48), height: dp(48))
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                    Text(comment.author)
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                    if !metaTokens.isEmpty {
                        Text(metaTokens.joined(separator: "  •  "))
                            .nuvioText(NuvioTypography.labelSmall)
                            .foregroundStyle(colors.textTertiary)
                    }
                }

                Spacer(minLength: NuvioTheme.spacing.lg)

                if let rating = comment.userRating {
                    HStack(spacing: NuvioTheme.spacing.xxs) {
                        Image(systemName: "star.fill")
                            .font(.system(size: NuvioTheme.sizes.icons.xs))
                            .foregroundStyle(colors.rating)
                        Text("\(rating)")
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textPrimary)
                    }
                }
            }

            if isHidden {
                Button(action: { isRevealed = true }) {
                    HStack(spacing: NuvioTheme.spacing.sm) {
                        Image(systemName: "eye.slash.fill")
                        Text("Spoiler — show anyway")
                    }
                    .nuvioText(NuvioTextStyles.button)
                    .padding(.horizontal, NuvioTheme.spacing.xl)
                    .frame(height: NuvioTheme.components.buttonHeight)
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .ghost))
            } else {
                Text(comment.body)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)
                    .frame(maxWidth: dp(1000), alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(NuvioTheme.spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.components.settings.secondaryCardRadius, style: .continuous)
                .fill(colors.surface.opacity(0.6))
        }
    }

    private var metaTokens: [String] {
        var tokens: [String] = []
        if comment.isReview { tokens.append("Review") }
        if let date = comment.createdAt {
            tokens.append(DateFormatter.nuvioMediumDate.string(from: date))
        }
        if comment.likes > 0 { tokens.append("\(comment.likes) like\(comment.likes == 1 ? "" : "s")") }
        if comment.replies > 0 { tokens.append("\(comment.replies) repl\(comment.replies == 1 ? "y" : "ies")") }
        return tokens
    }
}

@Observable
@MainActor
final class CommentsViewModel {
    enum Sort: String, CaseIterable, Identifiable {
        case likes, newest, replies, highest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .likes: return "Most liked"
            case .newest: return "Newest"
            case .replies: return "Most replies"
            case .highest: return "Highest rated"
            }
        }
    }

    private(set) var comments: [TraktClient.Comment] = []
    private(set) var isLoading = true
    private(set) var error: String?
    private(set) var sort: Sort = .likes
    private(set) var canLoadMore = false

    private var page = 0

    func load(imdbId: String, contentType: String, settings: AppSettings) async {
        guard comments.isEmpty else { return }
        guard !settings.tracking.traktClientId.isEmpty else {
            isLoading = false
            error = "Comments come from Trakt — add a Trakt client ID in Tracking settings."
            return
        }
        await loadMore(imdbId: imdbId, contentType: contentType, settings: settings)
    }

    func setSort(_ newSort: Sort, imdbId: String, contentType: String, settings: AppSettings) async {
        guard newSort != sort else { return }
        sort = newSort
        comments = []
        page = 0
        canLoadMore = false
        await loadMore(imdbId: imdbId, contentType: contentType, settings: settings)
    }

    func loadMore(imdbId: String, contentType: String, settings: AppSettings) async {
        guard !settings.tracking.traktClientId.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        page += 1
        let batch = await TraktClient.shared.comments(
            imdbId: imdbId,
            type: ContentType.from(contentType),
            clientId: settings.tracking.traktClientId,
            page: page,
            sort: sort.rawValue
        )
        let existing = Set(comments.map(\.id))
        comments.append(contentsOf: batch.filter { !existing.contains($0.id) })
        // Trakt pages at 25; a short page means the end.
        canLoadMore = batch.count >= 25
    }
}
