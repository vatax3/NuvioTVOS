import SwiftUI

/// The live readings, drawn top-left over playback.
///
/// Deliberately not focusable and not a panel: it is read while something else has the remote,
/// exactly like the seek readout. Anything that took focus here would put the overlay between
/// the viewer and the transport.
struct PlaybackStatsOverlay: View {
    @Environment(\.nuvioColors) private var colors

    let readings: [PlaybackStats.Reading]

    private func colour(for severity: PlaybackStats.Severity) -> Color {
        switch severity {
        case .normal: return .white.opacity(0.92)
        case .warning: return colors.warning
        case .limit: return colors.error
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
            ForEach(readings) { reading in
                HStack(spacing: NuvioTheme.spacing.sm) {
                    Text(reading.label)
                        .frame(width: dp(74), alignment: .leading)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(reading.value)
                        .foregroundStyle(colour(for: reading.severity))
                }
                .font(.system(size: dp(20), weight: .medium, design: .monospaced))
            }
        }
        .padding(NuvioTheme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                .fill(.black.opacity(0.55))
        )
        .allowsHitTesting(false)
        .accessibilityIdentifier(PlaybackStatsOverlay.identifier)
    }

    static let identifier = "player.statsOverlay"
}
