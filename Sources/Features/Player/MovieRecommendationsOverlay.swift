import SwiftUI

/// What a film offers when it reaches its end.
///
/// Upstream draws these behind an autoplaying trailer; ours does not, because tvOS has no
/// supported YouTube playback path — the recommendations are the feature, the trailer was
/// decoration the platform refuses. See `PostPlayRecommendation`.
///
/// It takes the remote outright rather than sitting beside the transport: it appears at the end
/// of a film, when the transport has nothing left to do, and a row of posters competing with a
/// scrubber for Left and Right is unusable.
struct MovieRecommendationsOverlay: View {
    @Environment(\.nuvioColors) private var colors

    let title: String
    let cards: [MetaPreview]
    let onPlay: (MetaPreview) -> Void
    let onDismiss: () -> Void

    @FocusState private var focused: String?

    static let identifier = "player.movieRecommendations"

    var body: some View {
        ZStack {
            // Opaque enough to read against, short of hiding the credits entirely.
            Color.black.opacity(0.82).ignoresSafeArea()

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xl) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                    Text(L10n.format(
                        "postplay.because_you_watched",
                        fallback: "Because you watched %@",
                        title
                    ))
                    .nuvioText(NuvioTypography.headlineLarge)
                    .foregroundStyle(.white)
                    Text(L10n.text("postplay.recommended", fallback: "Recommended for you"))
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(.white.opacity(0.7))
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: NuvioTheme.spacing.lg) {
                        ForEach(cards, id: \.rowKey) { card in
                            Button { onPlay(card) } label: {
                                VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                                    RemoteImage(url: card.poster, contentMode: .fill) {
                                        PosterPlaceholder(systemImage: "film")
                                    }
                                    .frame(width: dp(150), height: dp(225))
                                    .clipShape(RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous))

                                    Text(card.name)
                                        .nuvioText(NuvioTextStyles.cardTitle)
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .frame(width: dp(150), alignment: .leading)
                                }
                            }
                            .buttonStyle(NuvioCardButtonStyle(cornerRadius: NuvioTheme.radii.md))
                            .focused($focused, equals: card.rowKey)
                        }
                    }
                    .padding(.vertical, NuvioTheme.spacing.md)
                }

                Button(action: onDismiss) {
                    Text(L10n.text("postplay.return_to_player", fallback: "Return to player"))
                        .nuvioText(NuvioTextStyles.button)
                        .padding(.horizontal, NuvioTheme.spacing.xl)
                        .frame(height: NuvioTheme.components.buttonHeight)
                }
                .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.lg))
                .focused($focused, equals: Self.returnKey)
            }
            .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .focusSection()
        // Menu returns to the film rather than ending it: the viewer asked to see the credits.
        .onExitCommand(perform: onDismiss)
        .onAppear { focused = cards.first?.rowKey ?? Self.returnKey }
        .accessibilityIdentifier(Self.identifier)
    }

    private static let returnKey = "postplay.return"
}
