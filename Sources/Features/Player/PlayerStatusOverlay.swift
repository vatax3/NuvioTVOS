import SwiftUI

/// Nuvio-branded status layers above the system transport. They deliberately do not replace
/// `AVPlayerViewController`: Siri Remote scrubbing and the native track menus stay intact.
struct PlayerLoadingOverlay: View {
    @Environment(\.nuvioColors) private var colors

    let request: PlaybackRequest
    let showsDetail: Bool

    var body: some View {
        ZStack {
            Color.black
            if let backdrop = request.backdrop ?? request.poster, let url = URL(string: backdrop) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.black
                }
                .opacity(0.42)
                .blur(radius: dp(5))
            }
            LinearGradient(
                colors: [.black.opacity(0.35), .black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: NuvioTheme.spacing.lg) {
                ProgressView()
                    .controlSize(.large)
                    .tint(colors.secondary)
                Text(request.title)
                    .nuvioText(NuvioTextStyles.sectionTitle)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if showsDetail {
                    Text("Preparing stream…")
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(NuvioTheme.spacing.xl)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading \(request.title)")
    }
}

struct PlayerPauseOverlay: View {
    @Environment(\.nuvioColors) private var colors

    let request: PlaybackRequest
    let showsClock: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("You are watching")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                if showsClock {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(Date(), style: .time)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }

            Text(request.title)
                .nuvioText(NuvioTextStyles.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
            if let subtitle = request.subtitleLine?.nilIfBlank {
                Text(subtitle)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)
        .padding(.bottom, dp(118))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom
            )
            .frame(height: dp(440))
            .ignoresSafeArea()
        }
        .accessibilityElement(children: .combine)
    }
}

struct ParentalGuideOverlay: View {
    @Environment(\.nuvioColors) private var colors

    let warnings: [ParentalWarning]

    var body: some View {
        if !warnings.isEmpty {
            // Match the Android/iOS guide: it is a brief, quiet annotation over playback, not
            // a dialog.  The old rounded card expanded visually into a large opaque black block
            // on tvOS and obscured the opening image.
            HStack(alignment: .top, spacing: NuvioTheme.spacing.sm) {
                Capsule()
                    .fill(colors.secondary)
                    .frame(width: dp(2), height: guideHeight)
                VStack(alignment: .leading, spacing: dp(2)) {
                    ForEach(Array(warnings.prefix(5)), id: \.self) { warning in
                        HStack(spacing: dp(4)) {
                            Text(warning.label)
                                .font(.system(size: sp(11), weight: .semibold))
                                .foregroundStyle(.white.opacity(0.88))
                            Text("·")
                                .font(.system(size: sp(11)))
                                .foregroundStyle(.white.opacity(0.40))
                            Text(warning.severity)
                                .font(.system(size: sp(11)))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        .frame(height: dp(18), alignment: .leading)
                    }
                }
            }
            .padding(.leading, NuvioTheme.layout.tvSafeHorizontal)
            .padding(.top, NuvioTheme.layout.tvSafeVertical)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .shadow(color: .black.opacity(0.80), radius: dp(5), y: dp(2))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Content guide")
        }
    }

    private var guideHeight: CGFloat {
        let visibleCount = min(warnings.count, 5)
        return CGFloat(visibleCount) * dp(18) + CGFloat(max(0, visibleCount - 1)) * dp(2)
    }
}
