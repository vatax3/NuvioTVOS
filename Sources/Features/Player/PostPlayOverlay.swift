import SwiftUI

/// Focusable end-of-episode decision. The Android app exposes this as a rich overlay; on tvOS
/// we keep it intentionally compact so the system transport remains available underneath.
struct PostPlayOverlay: View {
    @Environment(\.nuvioColors) private var colors

    let next: StreamRequest
    let countdown: Int
    let continuePlayback: () -> Void
    let cancel: () -> Void

    @FocusState private var continueFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            Text("Up next")
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.textSecondary)

            Text(next.episodeLabel.map { "\($0) · \(next.episodeName ?? next.title)" } ?? next.title)
                .nuvioText(NuvioTextStyles.sectionTitle)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(2)

            HStack(spacing: NuvioTheme.spacing.md) {
                Button(action: continuePlayback) {
                    Label("Play next (\(countdown))", systemImage: "play.fill")
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(continueFocused ? colors.onSecondary : .white)
                        .padding(.horizontal, NuvioTheme.spacing.lg)
                        .frame(minHeight: dp(52))
                        .background {
                            RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                                .fill(continueFocused ? colors.secondary : Color.white.opacity(0.18))
                        }
                }
                .buttonStyle(.plain)
                .focused($continueFocused)

                Button("Stay here", action: cancel)
                    .buttonStyle(.bordered)
            }
        }
        .padding(NuvioTheme.spacing.xl)
        .frame(maxWidth: dp(640), alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous)
                .fill(.black.opacity(0.88))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next episode")
    }
}

struct StillWatchingOverlay: View {
    @Environment(\.nuvioColors) private var colors

    let continuePlayback: () -> Void
    let stopAutoPlay: () -> Void

    @FocusState private var continueFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            Label("Still watching?", systemImage: "person.fill.questionmark")
                .nuvioText(NuvioTextStyles.sectionTitle)
                .foregroundStyle(colors.textPrimary)
            Text("Continue to the next episode, or stop auto-play for this session.")
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textSecondary)

            HStack(spacing: NuvioTheme.spacing.md) {
                Button(action: continuePlayback) {
                    Label("Continue watching", systemImage: "play.fill")
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(continueFocused ? colors.onSecondary : .white)
                        .padding(.horizontal, NuvioTheme.spacing.lg)
                        .frame(minHeight: dp(52))
                        .background {
                            RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                                .fill(continueFocused ? colors.secondary : Color.white.opacity(0.18))
                        }
                }
                .buttonStyle(.plain)
                .focused($continueFocused)

                Button("Stop auto-play", action: stopAutoPlay)
                    .buttonStyle(.bordered)
            }
        }
        .padding(NuvioTheme.spacing.xl)
        .frame(maxWidth: dp(620), alignment: .leading)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: NuvioTheme.radii.lg))
        .accessibilityElement(children: .contain)
    }
}
