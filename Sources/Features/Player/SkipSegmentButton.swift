import SwiftUI

/// The tvOS equivalent of NuvioTV's temporary Skip Intro card. It intentionally stays compact:
/// AVPlayer owns the main transport, while this one extra focus target remains available when the
/// system controls fade away.
struct SkipSegmentButton: View {
    @Environment(\.nuvioColors) private var colors

    let segment: SkipSegment
    let action: () -> Void
    @FocusState private var isFocused: Bool

    private var label: String {
        switch segment.kind {
        case .intro: return "Skip intro"
        case .outro: return "Skip outro"
        case .recap: return "Skip recap"
        case .mixed: return "Skip segment"
        }
    }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "forward.end.fill")
                .nuvioText(NuvioTextStyles.cardTitle)
                .foregroundStyle(isFocused ? colors.onSecondary : Color.white)
                .padding(.horizontal, NuvioTheme.spacing.lg)
                .frame(minHeight: dp(52))
                .background {
                    RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                        .fill(isFocused ? colors.secondary : Color.black.opacity(0.82))
                }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .accessibilityHint("Skips to \(Int(segment.end / 60)) minutes \(Int(segment.end) % 60) seconds")
    }
}
