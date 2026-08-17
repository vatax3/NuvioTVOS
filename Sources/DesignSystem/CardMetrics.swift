import SwiftUI

// MARK: - Poster metrics
//
// Android exposes poster width/height/radius as user-tunable dp values in Layout settings, so
// the card components cannot read the static tokens. `PosterMetrics` carries the resolved
// values down through the environment; `NuvioComponents.posterCard` stays the default.

struct PosterMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    var showsLabels: Bool
    var preferLandscape: Bool
    var backdropExpandEnabled: Bool
    var backdropExpandDelay: Int
    /// `show_full_release_date`: card metadata shows the full date rather than the bare year.
    var showsFullReleaseDate: Bool = false

    static let `default` = PosterMetrics(
        width: NuvioTheme.components.posterCard.width,
        height: NuvioTheme.components.posterCard.height,
        cornerRadius: NuvioTheme.components.posterCard.cornerRadius,
        showsLabels: true,
        preferLandscape: false,
        backdropExpandEnabled: true,
        backdropExpandDelay: 3
    )

    /// Landscape and square rails scale off the configured poster height so a viewer who
    /// shrinks their posters gets a proportionally shorter rail rather than a mixed one.
    func size(for shape: PosterShape) -> CGSize {
        switch shape {
        case .poster:
            return CGSize(width: width, height: height)
        case .landscape:
            let landscapeHeight = height * (dp(148) / dp(189))
            return CGSize(width: landscapeHeight * NuvioTheme.media.backdropAspectRatio, height: landscapeHeight)
        case .square:
            let side = height * (dp(170) / dp(189))
            return CGSize(width: side, height: side)
        }
    }

    /// The shape a rail item is actually drawn with, after the "landscape posters" override.
    func resolvedShape(for shape: PosterShape) -> PosterShape {
        preferLandscape && shape == .poster ? .landscape : shape
    }

    /// Grid columns that reflow with the poster size, so shrinking posters fits more per row
    /// instead of leaving the right edge empty.
    func gridColumns(
        spacing: CGFloat = NuvioTheme.components.row.itemSpacing,
        horizontalInset: CGFloat = NuvioTheme.components.row.horizontalPadding
    ) -> [GridItem] {
        let itemWidth = size(for: resolvedShape(for: .poster)).width
        let available = NuvioTheme.layout.screenWidth - horizontalInset * 2
        let count = max(2, Int((available + spacing) / (itemWidth + spacing)))
        return Array(repeating: GridItem(.fixed(itemWidth), spacing: spacing), count: count)
    }
}

private struct PosterMetricsKey: EnvironmentKey {
    static let defaultValue = PosterMetrics.default
}

extension EnvironmentValues {
    var posterMetrics: PosterMetrics {
        get { self[PosterMetricsKey.self] }
        set { self[PosterMetricsKey.self] = newValue }
    }
}

// MARK: - Card depth
//
// Port of the `CardDepth*` preferences: cards get an inner edge shading pass plus a diagonal
// sheen so artwork reads as a physical tile rather than a flat crop. Each surface (posters,
// continue watching, episodes, cast, trailers) opts in separately.

struct CardDepthStyle: Equatable {
    var posters: Bool
    var continueWatching: Bool
    var episodes: Bool
    var cast: Bool
    var trailers: Bool
    var edgeStrength: Double
    var edgeCoverage: Double
    var sheenStrength: Double

    static let `default` = CardDepthStyle(
        posters: true, continueWatching: true, episodes: true,
        cast: false, trailers: false,
        edgeStrength: 0.5, edgeCoverage: 0.35, sheenStrength: 0.4
    )

    static let disabled = CardDepthStyle(
        posters: false, continueWatching: false, episodes: false,
        cast: false, trailers: false,
        edgeStrength: 0, edgeCoverage: 0, sheenStrength: 0
    )

    enum Surface { case poster, continueWatching, episode, cast, trailer }

    func isEnabled(_ surface: Surface) -> Bool {
        switch surface {
        case .poster: return posters
        case .continueWatching: return continueWatching
        case .episode: return episodes
        case .cast: return cast
        case .trailer: return trailers
        }
    }
}

private struct CardDepthStyleKey: EnvironmentKey {
    static let defaultValue = CardDepthStyle.default
}

extension EnvironmentValues {
    var cardDepth: CardDepthStyle {
        get { self[CardDepthStyleKey.self] }
        set { self[CardDepthStyleKey.self] = newValue }
    }
}

/// Draws the edge shading and sheen over artwork. Non-interactive, so it never affects focus.
struct CardDepthOverlay: View {
    @Environment(\.cardDepth) private var depth

    let surface: CardDepthStyle.Surface
    var cornerRadius: CGFloat

    var body: some View {
        if depth.isEnabled(surface) {
            ZStack {
                // Both vertical edges darken inward over `edgeCoverage` of the width.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(edgeAlpha), location: 0),
                        .init(color: .clear, location: coverage),
                        .init(color: .clear, location: 1 - coverage),
                        .init(color: .black.opacity(edgeAlpha), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                // Plus a softer pass along the bottom, which is where Compose grounds the tile.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 1 - coverage),
                        .init(color: .black.opacity(edgeAlpha * 0.8), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(sheenAlpha), location: 0),
                        .init(color: .clear, location: 0.45)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
    }

    /// Preferences arrive as 0…1 sliders; these caps keep the extremes from crushing artwork.
    private var edgeAlpha: Double { min(1, max(0, depth.edgeStrength)) * 0.55 }
    private var sheenAlpha: Double { min(1, max(0, depth.sheenStrength)) * 0.22 }
    private var coverage: Double { min(0.49, max(0.01, depth.edgeCoverage)) }
}

extension View {
    /// Applies the depth treatment for one card surface.
    func cardDepth(_ surface: CardDepthStyle.Surface, cornerRadius: CGFloat) -> some View {
        overlay { CardDepthOverlay(surface: surface, cornerRadius: cornerRadius) }
    }
}

// MARK: - Navigation feel
//
// `fast_horizontal_navigation_enabled` and `smooth_bring_into_view_enabled` govern how the
// rails respond to a held D-pad: the fast mode collapses the focus animation so a long press
// travels without lag, and smooth bring-into-view animates the scroll that follows focus.

struct NavigationFeel: Equatable {
    var fastHorizontal: Bool = true
    var smoothBringIntoView: Bool = true

    static let `default` = NavigationFeel()

    /// Focus ring / scale animation. Fast mode cuts it to roughly a frame so held navigation
    /// does not queue up animations behind the viewer.
    var focusAnimation: Animation {
        fastHorizontal
            ? .timingCurve(0.4, 0, 0.2, 1, duration: NuvioMotion.durations.quick / 2)
            : NuvioMotion.focusTween
    }

    /// Animation for the scroll that chases focus; `nil` means jump straight there.
    var scrollAnimation: Animation? {
        smoothBringIntoView ? NuvioMotion.focusTween : nil
    }
}

private struct NavigationFeelKey: EnvironmentKey {
    static let defaultValue = NavigationFeel.default
}

extension EnvironmentValues {
    var navigationFeel: NavigationFeel {
        get { self[NavigationFeelKey.self] }
        set { self[NavigationFeelKey.self] = newValue }
    }
}

// MARK: - Spoiler blur
//
// `blur_continue_watching_next_up` / `blur_unwatched_episodes`: artwork for something the
// viewer has not seen yet is blurred until the card takes focus.

struct SpoilerBlur: ViewModifier {
    let isActive: Bool
    let isRevealed: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: isActive && !isRevealed ? dp(9) : 0, opaque: true)
            .overlay {
                if isActive && !isRevealed {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: NuvioTheme.sizes.icons.md))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .animation(NuvioMotion.mediumTween, value: isRevealed)
    }
}

extension View {
    /// Blurs artwork that would spoil an unwatched episode, clearing while the card is focused.
    func spoilerBlur(active: Bool, revealed: Bool) -> some View {
        modifier(SpoilerBlur(isActive: active, isRevealed: revealed))
    }
}
