import SwiftUI

/// The tvOS equivalent of NuvioTV's temporary Skip Intro card.
///
/// It is not a `Button`, for the reason recorded on the stream row: tvOS 26 draws its own opaque
/// focus plate over a `Button` even under `.buttonStyle(.plain)`, applied after the view tree and
/// so on top of everything here. Over bare video that plate reads as a large white slab with the
/// label lost inside it, which is what it looked like. A focusable shape with the button trait
/// keeps Select on the Siri Remote while letting the card own every pixel of its focus state —
/// the same secondary fill Android uses.
struct SkipSegmentButton: View {
    @Environment(\.nuvioColors) private var colors

    let segment: SkipSegment
    /// Whether the card should take the remote. False while the transport is up: the viewer is
    /// already steering with it. See `SkipSegmentVisibility.claimsFocus`.
    var claimsFocus: Bool = true
    /// Whether the auto-hide countdown is running. Drawn as the strip along the bottom edge,
    /// as upstream does, so a card about to vanish says so rather than just vanishing.
    var showsCountdown: Bool = true
    let action: () -> Void
    /// Up or Down from the card. Upstream moves focus to the transport row; here the card steps
    /// aside and the player takes the remote back, which is the same outcome with one focus
    /// target instead of two competing for the bottom of the screen.
    let onDismiss: () -> Void
    /// Left and Right. Without these the remote was **dead** for the length of a segment: the
    /// card held focus, a card is not a scrubber, and the player's own seek handler only runs
    /// while nothing is drawn over the picture. An opening is exactly when someone reaches for
    /// the fast-forward.
    let onSeek: (Bool) -> Void

    @FocusState private var isFocused: Bool
    @State private var countdown: CGFloat = 0

    private var label: String {
        switch segment.kind {
        case .intro: return "Skip intro"
        case .outro: return "Skip outro"
        case .recap: return "Skip recap"
        case .mixed: return "Skip segment"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Label(label, systemImage: "forward.end.fill")
                .nuvioText(NuvioTextStyles.cardTitle)
                .foregroundStyle(isFocused ? colors.onSecondary : Color.white)
                .padding(.horizontal, NuvioTheme.spacing.lg)
                .frame(minHeight: dp(52))

            // The remaining time before the card hides itself. Hidden while focused: a card the
            // viewer is pointing at is not idle, and the countdown is not running either.
            Capsule()
                .fill(.white.opacity(showsCountdown && !isFocused ? 0.22 : 0))
                .frame(height: dp(3))
                .scaleEffect(x: 1 - countdown, y: 1, anchor: .leading)
                .padding(.horizontal, NuvioTheme.spacing.sm)
                .padding(.bottom, dp(5))
        }
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                .fill(isFocused ? colors.secondary : Color.black.opacity(0.82))
        }
        .scaleEffect(isFocused ? NuvioMotion.focusScale : 1)
        .animation(NuvioMotion.focusTween, value: isFocused)
        // Upstream's `width(IntrinsicSize.Max)`. Without it the card takes the width its
        // full-screen alignment container offers it and stretches across the picture, which a
        // `Button` used to prevent for free.
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .focusEffectDisabled()
        .focusable(claimsFocus)
        .focused($isFocused)
        .onTapGesture(perform: action)
        .onMoveCommand { direction in
            switch direction {
            case .left: onSeek(false)
            case .right: onSeek(true)
            case .up, .down: onDismiss()
            @unknown default: break
            }
        }
        // Android focuses the card as it appears so a single Select skips, but only when the
        // transport is down — otherwise focus is taken out of a control row somebody is using.
        .onChange(of: claimsFocus, initial: true) { _, claims in
            guard claims else { return }
            Task { @MainActor in isFocused = true }
        }
        .task(id: showsCountdown) {
            guard showsCountdown else {
                countdown = 0
                return
            }
            withAnimation(.linear(duration: SkipSegmentVisibility.autoHideTimeout)) {
                countdown = 1
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityHint("Skips to \(Int(segment.end / 60)) minutes \(Int(segment.end) % 60) seconds")
    }
}
