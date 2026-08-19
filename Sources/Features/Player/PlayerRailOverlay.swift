import SwiftUI

/// The bottom-left overlay Android TV uses for the in-playback audio and subtitle choosers.
///
/// It is deliberately not the trailing panel that Sources and Episodes use.  Those are 520 dp
/// side panels on Android as well, but the track choosers are wide, column-based overlays
/// pinned to the bottom-left corner: the right two thirds of the picture stay visible, which is
/// what lets a viewer judge an audio track against what they are hearing while choosing it.
struct PlayerRailOverlay<Content: View>: View {
    let title: String
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            scrim

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
                Text(title)
                    .nuvioText(NuvioTypography.headlineMedium)
                    .foregroundStyle(.white)

                HStack(alignment: .top, spacing: dp(14)) {
                    content()
                }
            }
            .padding(.horizontal, dp(52))
            .padding(.top, dp(36))
            .padding(.bottom, dp(76))
        }
        .ignoresSafeArea()
        .focusSection()
    }

    /// Three stacked washes, in Android's order: a horizontal fade that darkens the column
    /// side, a flat tint, then a vertical fade.  Layering them rather than using one gradient
    /// is what keeps white card text legible over a bright frame without dimming the picture.
    private var scrim: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.black.opacity(0.88), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(Color.black.opacity(0.34))
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.6), location: 0),
                        .init(color: .black.opacity(0.4), location: 0.3),
                        .init(color: .black.opacity(0.2), location: 0.6),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
    }
}

/// One column of an overlay.  The height cap is Android's: a list taller than this runs off the
/// top of a 1080p panel, and the focus engine scrolls it as the viewer moves down.
struct PlayerRailColumn<Content: View>: View {
    @Environment(\.nuvioColors) private var colors

    let width: CGFloat
    var heading: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
            if let heading = heading?.nilIfBlank {
                Text(heading)
                    .nuvioText(NuvioTypography.bodyMedium)
                    .foregroundStyle(.white.opacity(0.92))
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: dp(6)) {
                    content()
                }
                .padding(.vertical, NuvioTheme.spacing.sm)
            }
            .scrollClipDisabled()
            .frame(maxHeight: dp(620))
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Android's track card: transparent until it is the active track, when it fills with the
/// accent; focus is a 4 dp ring and never a scale, because a card that grows under the focus
/// ring pushes the rest of the column around while the viewer is reading it.
struct PlayerRailCard: View {
    @Environment(\.nuvioColors) private var colors
    @FocusState private var focused: Bool

    let title: String
    var subtitle: String? = nil
    var metadata: String? = nil
    var isSelected = false
    var requestsInitialFocus = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: NuvioTheme.spacing.sm) {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                    Text(title)
                        .nuvioText(NuvioTypography.titleMedium)
                        .foregroundStyle(isSelected ? colors.onSecondary : .white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitle = subtitle?.nilIfBlank {
                        Text(subtitle)
                            .nuvioText(NuvioTypography.bodySmall)
                            .foregroundStyle(isSelected ? colors.onSecondary.opacity(0.82) : .white.opacity(0.72))
                            .lineLimit(1)
                    }
                    if let metadata = metadata?.nilIfBlank {
                        Text(metadata)
                            .nuvioText(NuvioTypography.bodySmall)
                            .foregroundStyle(isSelected ? colors.onSecondary.opacity(0.72) : colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: NuvioTheme.sizes.icons.sm, weight: .semibold))
                        .foregroundStyle(colors.onSecondary)
                }
            }
            .padding(.horizontal, NuvioTheme.spacing.md)
            .padding(.vertical, NuvioTheme.spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerRailCardStyle(isSelected: isSelected))
        .focused($focused)
        .onAppear {
            guard requestsInitialFocus else { return }
            Task { @MainActor in focused = true }
        }
    }
}

/// A ± stepper, Android's `StepCard` pair with its label, value and range helper.
struct PlayerRailStepper: View {
    @Environment(\.nuvioColors) private var colors

    let title: String
    let value: String
    let helper: String
    var canDecrease = true
    var canIncrease = true
    var requestsInitialFocus = false
    let onDecrease: () -> Void
    let onIncrease: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
            Text(title)
                .nuvioText(NuvioTypography.bodyMedium)
                .foregroundStyle(.white.opacity(0.92))
            Text(value)
                .nuvioText(NuvioTypography.titleMedium)
                .foregroundStyle(.white)
                .monospacedDigit()
            HStack(spacing: dp(6)) {
                stepButton("minus", enabled: canDecrease, initialFocus: requestsInitialFocus && canDecrease, action: onDecrease)
                stepButton("plus", enabled: canIncrease, initialFocus: requestsInitialFocus && !canDecrease, action: onIncrease)
            }
            Text(helper)
                .nuvioText(NuvioTypography.bodySmall)
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepButton(
        _ systemImage: String,
        enabled: Bool,
        initialFocus: Bool,
        action: @escaping () -> Void
    ) -> some View {
        PlayerRailStepButton(
            systemImage: systemImage,
            enabled: enabled,
            requestsInitialFocus: initialFocus,
            action: action
        )
    }
}

private struct PlayerRailStepButton: View {
    @Environment(\.nuvioColors) private var colors
    @FocusState private var focused: Bool

    let systemImage: String
    let enabled: Bool
    let requestsInitialFocus: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: NuvioTheme.sizes.icons.sm, weight: .semibold))
                .foregroundStyle(enabled ? .white : .white.opacity(0.35))
                .frame(width: dp(72), height: dp(32))
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerRailCardStyle(isSelected: false, restingStroke: enabled ? 0.18 : 0))
        .disabled(!enabled)
        .focused($focused)
        .onAppear {
            guard requestsInitialFocus else { return }
            Task { @MainActor in focused = true }
        }
    }
}

/// Shared chrome for the overlay's cards: accent fill when active, accent ring on focus, no
/// scale — `NuvioRowButtonStyle` lifts and tints instead, which reads wrong over moving video.
private struct PlayerRailCardStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.nuvioColors) private var colors

    let isSelected: Bool
    var restingStroke: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                    .fill(isSelected ? colors.secondary : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                    .strokeBorder(
                        isFocused ? colors.focusRing : .white.opacity(restingStroke),
                        lineWidth: NuvioTheme.spacing.xxs
                    )
            }
            .animation(NuvioMotion.focusTween, value: isFocused)
    }
}
