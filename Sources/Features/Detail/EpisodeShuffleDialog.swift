import SwiftUI

/// Turning shuffle on for one series, and asking for a different episode.
///
/// Port of upstream's `EpisodeShuffleDialog`, on the same chrome as the episode options so a
/// viewer who has learned one dialog has learned this one. Three rows, because there are exactly
/// three decisions: shuffle or not, whether episodes already watched may come up, and "not that
/// one".
struct EpisodeShuffleDialog: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(EpisodeShuffleStore.self) private var shuffle

    let contentId: String
    /// What *Play* is currently offering, so the dialog can name it. Shuffle with nothing to
    /// offer has to say so rather than showing an empty row.
    let offering: String?
    let onDismiss: () -> Void

    private enum Row: Hashable { case enabled, includeWatched, reroll }

    @FocusState private var focused: Row?

    private var settings: EpisodeShuffleSettings { shuffle.settings(forContentId: contentId) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                    Text(L10n.text("detail.shuffle", fallback: "Shuffle"))
                        .nuvioText(NuvioTypography.headlineLarge)
                        .foregroundStyle(colors.textPrimary)
                    Text(subtitle)
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                    row(
                        .enabled,
                        title: L10n.text("detail.shuffle_enabled", fallback: "Shuffle episodes"),
                        systemImage: "shuffle",
                        isOn: settings.isEnabled
                    ) {
                        var next = settings
                        next.isEnabled.toggle()
                        shuffle.update(next, forContentId: contentId)
                    }

                    row(
                        .includeWatched,
                        title: L10n.text(
                            "detail.shuffle_include_watched", fallback: "Include watched episodes"
                        ),
                        systemImage: "eye",
                        isOn: settings.includesWatched
                    ) {
                        var next = settings
                        next.includesWatched.toggle()
                        shuffle.update(next, forContentId: contentId)
                    }

                    if settings.isEnabled {
                        row(
                            .reroll,
                            title: L10n.text("detail.shuffle_another", fallback: "Another episode"),
                            systemImage: "arrow.triangle.2.circlepath",
                            isOn: false
                        ) {
                            shuffle.reroll(surface: .detail, contentId: contentId)
                            onDismiss()
                        }
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
        .onAppear { focused = .enabled }
    }

    private var subtitle: String {
        guard settings.isEnabled else {
            return L10n.text(
                "detail.shuffle_off_hint", fallback: "Play follows the next unwatched episode"
            )
        }
        guard let offering else {
            return L10n.text(
                "detail.shuffle_exhausted_hint",
                fallback: "Nothing left to offer — include watched episodes to keep going"
            )
        }
        return L10n.format("detail.shuffle_offering", fallback: "Next up: %@", offering)
    }

    private func row(
        _ id: Row,
        title: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: NuvioTheme.spacing.md) {
                Image(systemName: systemImage)
                    .frame(width: dp(22))
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark")
                        .foregroundStyle(colors.secondary)
                }
            }
            .nuvioText(NuvioTextStyles.button)
            .foregroundStyle(colors.textPrimary)
            .padding(.horizontal, NuvioTheme.spacing.lg)
            .frame(height: NuvioTheme.components.buttonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.lg))
        .focused($focused, equals: id)
    }
}
