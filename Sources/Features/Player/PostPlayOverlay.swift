import SwiftUI

/// Focusable end-of-episode decision. The Android app exposes this as a rich overlay; on tvOS
/// we keep it intentionally compact so the system transport remains available underneath.
struct PostPlayOverlay: View {
    @Environment(\.nuvioColors) private var colors

    let next: StreamRequest
    let countdown: Int
    let continuePlayback: () -> Void
    let cancel: () -> Void

    @FocusState private var focus: PlayerCardChoice?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            Text(L10n.text("postplay.up_next", fallback: "Up next"))
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.textSecondary)

            Text(next.episodeLabel.map { "\($0) · \(next.episodeName ?? next.title)" } ?? next.title)
                .nuvioText(NuvioTextStyles.sectionTitle)
                .foregroundStyle(colors.textPrimary)
                .lineLimit(2)

            HStack(spacing: NuvioTheme.spacing.md) {
                PlayerCardButton(
                    title: "Play next (\(countdown))",
                    systemImage: "play.fill",
                    emphasis: .primary,
                    focus: $focus,
                    choice: .confirm,
                    action: continuePlayback
                )
                PlayerCardButton(
                    title: L10n.text("postplay.stay", fallback: "Stay here"),
                    emphasis: .secondary,
                    focus: $focus,
                    choice: .decline,
                    action: cancel
                )
            }
        }
        .padding(NuvioTheme.spacing.xl)
        .frame(maxWidth: dp(640), alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous)
                .fill(.black.opacity(0.88))
        }
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("postplay.next_episode", fallback: "Next episode"))
        // The transport is out of the focus graph while a card is up, so the card has to take
        // the remote itself — otherwise focus lands nowhere and the countdown cannot be
        // answered at all.
        .onAppear { Task { @MainActor in focus = .confirm } }
    }
}

struct StillWatchingOverlay: View {
    @Environment(\.nuvioColors) private var colors

    let continuePlayback: () -> Void
    let stopAutoPlay: () -> Void

    @FocusState private var focus: PlayerCardChoice?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            Label(L10n.text("postplay.still_watching", fallback: "Still watching?"), systemImage: "person.fill.questionmark")
                .nuvioText(NuvioTextStyles.sectionTitle)
                .foregroundStyle(colors.textPrimary)
            Text(L10n.text("postplay.still_watching_body", fallback: "Continue to the next episode, or stop auto-play for this session."))
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textSecondary)

            HStack(spacing: NuvioTheme.spacing.md) {
                PlayerCardButton(
                    title: L10n.text("postplay.continue", fallback: "Continue watching"),
                    systemImage: "play.fill",
                    emphasis: .primary,
                    focus: $focus,
                    choice: .confirm,
                    action: continuePlayback
                )
                PlayerCardButton(
                    title: L10n.text("postplay.stop_autoplay", fallback: "Stop auto-play"),
                    emphasis: .secondary,
                    focus: $focus,
                    choice: .decline,
                    action: stopAutoPlay
                )
            }
        }
        .padding(NuvioTheme.spacing.xl)
        .frame(maxWidth: dp(620), alignment: .leading)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: NuvioTheme.radii.lg))
        .focusSection()
        .accessibilityElement(children: .contain)
        // The transport is out of the focus graph while a card is up, so the card has to take
        // the remote itself — otherwise focus lands nowhere and the countdown cannot be
        // answered at all.
        .onAppear { Task { @MainActor in focus = .confirm } }
    }
}

enum PlayerCardChoice: Hashable { case confirm, decline }

/// The two answers a player card can take.
///
/// Not a `Button`, for the reason recorded on `SkipSegmentButton` and the stream row: tvOS 26
/// lays its own opaque focus plate over a `Button` after the view tree has been built, so
/// `.buttonStyle(.plain)` still produced the large white slab these cards were reported for, and
/// `.bordered` produced the system's pill next to it — two focus treatments on one row, neither
/// of them the app's.
private struct PlayerCardButton: View {
    @Environment(\.nuvioColors) private var colors

    enum Emphasis { case primary, secondary }

    let title: String
    var systemImage: String?
    let emphasis: Emphasis
    var focus: FocusState<PlayerCardChoice?>.Binding
    let choice: PlayerCardChoice
    let action: () -> Void

    private var isFocused: Bool { focus.wrappedValue == choice }

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .nuvioText(NuvioTextStyles.cardTitle)
        .foregroundStyle(foreground)
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .frame(minHeight: dp(52))
        .background {
            Capsule(style: .continuous).fill(background)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(isFocused ? colors.focusRing : .clear, lineWidth: NuvioTheme.strokes.focus)
        }
        .scaleEffect(isFocused ? NuvioMotion.focusScale : 1)
        .animation(NuvioMotion.focusTween, value: isFocused)
        .contentShape(Rectangle())
        .focusEffectDisabled()
        .focusable()
        .focused(focus, equals: choice)
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        if isFocused { return colors.onSecondary }
        return emphasis == .primary ? .white : colors.textSecondary
    }

    private var background: Color {
        if isFocused { return colors.secondary }
        return emphasis == .primary ? .white.opacity(0.18) : .white.opacity(0.08)
    }
}
