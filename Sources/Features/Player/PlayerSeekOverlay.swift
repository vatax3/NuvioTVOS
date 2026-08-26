import SwiftUI

/// Where a scrub shows the position it is aiming at, and for how long.
///
/// Android TV splits the remote while the controls are down: vertical brings the transport
/// back, horizontal seeks in place behind a compact readout. This player used to do both at
/// once — every horizontal press revealed the whole transport, which then covered the bottom of
/// the picture the viewer was scrubbing through to find their place.
///
/// The split has to be made carefully, because "any direction brings the controls back" was
/// once a bug report: with the transport down, presses landed on faded buttons that still held
/// focus and nothing happened at all. What that report actually asked for is that **a press
/// always produces a visible response**, and the split keeps that true — vertical answers with
/// the transport, horizontal answers with this readout. Losing sight of the difference is how a
/// fix becomes a regression, so it is written down here rather than left to the diff.
enum PlayerSeekOverlayPolicy {
    /// How long the readout stays up after the last press.
    ///
    /// It has to outlast `scrub`'s 300 ms commit delay plus the ~700 ms mpv takes to settle on
    /// the new position. Fading before then would leave the viewer watching an unexplained jump
    /// with nothing on screen to account for it.
    static let linger: TimeInterval = 1.5

    /// Whether a scrub should bring the transport up instead of drawing the readout.
    ///
    /// True only when the transport is already interactable — the bar is showing the position
    /// anyway, and the press should also restart its auto-hide timer so it does not vanish
    /// mid-scrub.
    static func revealsTransport(controlsInteractable: Bool) -> Bool { controlsInteractable }

    /// `1:23:45`, or `4:07` under an hour.
    ///
    /// Shared with the transport's own readout so the two can never disagree about the same
    /// second — they are on screen together whenever a scrub reveals the bar.
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// The signed distance the pending seek covers, or `nil` before it covers any.
    ///
    /// Measured against where playback actually is, not against the previous press, so a held
    /// direction reads as one jump that keeps growing rather than a stream of identical steps.
    /// The minus is U+2212, which lines up with the digits; the ASCII hyphen does not.
    static func offsetLabel(from origin: Double, to target: Double) -> String? {
        guard origin.isFinite, target.isFinite else { return nil }
        let delta = (target - origin).rounded()
        guard abs(delta) >= 1 else { return nil }
        return (delta > 0 ? "+" : "\u{2212}") + timecode(abs(delta))
    }

    /// Where the pending position sits in the film, for the readout's own progress track.
    static func fraction(target: Double, duration: Double) -> Double {
        guard duration > 0, target.isFinite else { return 0 }
        return min(1, max(0, target / duration))
    }
}

/// The compact readout drawn while a scrub runs with the transport down.
///
/// Deliberately not a small transport: no buttons, nothing focusable, nothing that competes for
/// the remote. It is a label that says where the seek is going, and a track that says where
/// that is in the film — which is the whole of what the transport was being revealed for.
struct PlayerSeekReadout: View {
    /// What a running scrub needs to draw itself.
    ///
    /// The target is carried here rather than read from the pending-seek state, because that
    /// state clears the moment mpv lands and the readout outlives it by design.
    struct Model: Equatable {
        /// Where playback was when this burst of scrubbing began, for the signed offset.
        var origin: Double
        var target: Double
        var forward: Bool
    }

    let model: Model
    let duration: Double

    private var target: Double { model.target }
    private var origin: Double { model.origin }
    private var forward: Bool { model.forward }

    var body: some View {
        VStack(spacing: NuvioTheme.spacing.sm) {
            HStack(spacing: NuvioTheme.spacing.sm) {
                Image(systemName: forward ? "forward.fill" : "backward.fill")
                    .font(.system(size: sp(13), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("\(PlayerSeekOverlayPolicy.timecode(target)) / \(PlayerSeekOverlayPolicy.timecode(duration))")
                    .nuvioText(NuvioTypography.bodyMedium)
                    .foregroundStyle(.white)
                    .monospacedDigit()

                if let offset = PlayerSeekOverlayPolicy.offsetLabel(from: origin, to: target) {
                    Text(offset)
                        .nuvioText(NuvioTypography.bodyMedium)
                        .foregroundStyle(.white.opacity(0.62))
                        .monospacedDigit()
                }
            }

            track
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .background(RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous).fill(.black.opacity(0.72)))
        .overlay(
            RoundedRectangle(cornerRadius: NuvioTheme.radii.lg, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: NuvioTheme.strokes.hairline)
        )
        .padding(.bottom, NuvioTheme.layout.tvSafeVertical + dp(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .transition(.opacity)
        // It draws over the picture and takes nothing from the remote. It is not `.focusable`,
        // so it never enters the focus graph — but it stays in the accessibility tree, both
        // because a viewer scrubbing by ear needs the position read out and because it is the
        // only witness a UI test has that a horizontal press answered.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(PlayerSeekReadout.identifier)
        .accessibilityLabel(
            "\(PlayerSeekOverlayPolicy.timecode(target)) of \(PlayerSeekOverlayPolicy.timecode(duration))"
        )
    }

    /// The handle the UI test watches for; see `PlayerRemoteUITests`.
    static let identifier = "player.seekReadout"

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule()
                    .fill(.white)
                    .frame(width: width * PlayerSeekOverlayPolicy.fraction(target: target, duration: duration))
            }
        }
        .frame(width: dp(280), height: dp(4))
    }
}
