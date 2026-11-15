import SwiftUI

/// Upstream's `SourceStatusFilterChip`: a source filter that says how its source is doing.
///
/// Loading shimmers the name; an error turns the chip red with two gentle shakes, then the
/// model removes it. A chip that is not selectable still takes focus, as upstream's does —
/// pressing it does nothing.
struct SourceStatusChip: View {
    @Environment(\.nuvioColors) private var colors

    let title: String
    let status: SourceChip.Status
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .nuvioText(NuvioTextStyles.metadata)
                .lineLimit(1)
                .padding(.horizontal, NuvioTheme.spacing.md)
                .frame(height: dp(38))
        }
        .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary, selected: isSelected))
        .overlay {
            if status == .error {
                Capsule(style: .continuous)
                    .strokeBorder(colors.error.opacity(0.7), lineWidth: NuvioTheme.strokes.hairline)
            }
        }
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: status) { content, offset in
            content.offset(x: offset)
        } keyframes: { _ in
            KeyframeTrack {
                if status == .error {
                    CubicKeyframe(3, duration: 0.08)
                    CubicKeyframe(-3, duration: 0.11)
                    CubicKeyframe(2, duration: 0.09)
                    CubicKeyframe(-2, duration: 0.09)
                    CubicKeyframe(0, duration: 0.14)
                } else {
                    CubicKeyframe(0, duration: 0.01)
                }
            }
        }
        .accessibilityValue(accessibilityStatus)
    }

    @ViewBuilder
    private var label: some View {
        switch status {
        case .loading:
            Text(title)
                .phaseAnimator([1.0, 0.45]) { text, opacity in
                    text.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: NuvioMotion.durations.shimmer / 2)
                }
        case .success:
            Text(title)
        case .error:
            Text(title)
                .foregroundStyle(colors.error)
        }
    }

    private var accessibilityStatus: String {
        switch status {
        case .loading: return L10n.text("streams.source_loading", fallback: "Loading")
        case .success: return ""
        case .error: return L10n.text("streams.source_failed", fallback: "No sources")
        }
    }
}
