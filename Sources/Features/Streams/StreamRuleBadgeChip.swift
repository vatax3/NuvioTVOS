import SwiftUI

/// One badge earned from an imported rule.
///
/// The pack supplies its own colours, so this chip is the one place in the source list that does
/// not take them from the theme — the point of importing a pack is that its badges look like
/// themselves.
struct StreamRuleBadgeChip: View {
    @Environment(\.nuvioColors) private var colors
    let badge: StreamBadge

    @State private var imageFailed = false

    private var background: Color? {
        // `filled` is upstream's opt-in: a tag colour with no style is a colour the pack author
        // wanted on the *border*, and filling with it would drown the row in blocks.
        guard badge.tagStyle.lowercased() == "filled" else { return nil }
        return Color(cssHex: badge.tagColor)
    }

    private var border: Color? { Color(cssHex: badge.borderColor) }

    var body: some View {
        Group {
            if let url = badge.imageURL.nilIfBlank, !imageFailed {
                RemoteImage(url: url, contentMode: .fit, onFailure: { imageFailed = true }) {
                    // Nothing while it loads. A placeholder box that then becomes a logo of a
                    // different width makes the whole row of chips jump.
                    Color.clear
                }
                .frame(height: dp(22))
                .frame(minWidth: dp(34), maxWidth: dp(92))
                .padding(.horizontal, dp(3))
                .padding(.vertical, NuvioTheme.spacing.xxs)
                .background {
                    RoundedRectangle(cornerRadius: NuvioTheme.shapes.badge, style: .continuous)
                        .fill(background ?? .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: NuvioTheme.shapes.badge, style: .continuous)
                        .strokeBorder(border ?? .clear, lineWidth: NuvioTheme.strokes.hairline)
                }
            } else {
                // Upstream draws only the badges that carry a logo, and silently drops the rest.
                // A pack written without images would then match everything and show nothing, so
                // here the name is the fallback — it is already the thing the rule is called.
                Text(badge.name.uppercased())
                    .nuvioText(NuvioTextStyles.badge)
                    .foregroundStyle(Color(cssHex: badge.textColor) ?? colors.textSecondary)
                    .padding(.horizontal, NuvioTheme.spacing.sm)
                    .padding(.vertical, NuvioTheme.spacing.xxs)
                    .background {
                        RoundedRectangle(cornerRadius: NuvioTheme.shapes.badge, style: .continuous)
                            .fill(background ?? colors.surfaceVariant.opacity(0.7))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: NuvioTheme.shapes.badge, style: .continuous)
                            .strokeBorder(
                                border ?? (Color(cssHex: badge.tagColor) ?? colors.border).opacity(0.5),
                                lineWidth: NuvioTheme.strokes.hairline
                            )
                    }
            }
        }
    }
}
