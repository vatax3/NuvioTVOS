import SwiftUI

// MARK: - Density bridge
//
// Android TV renders a 1920×1080 panel at density 2.0, so the Compose layout space
// is 960×540 dp. tvOS lays out in a 1920×1080 pt space. Every `dp`/`sp` token from
// NuvioTV therefore maps to exactly 2 tvOS points, which is what keeps proportions
// identical between the two apps.
enum NuvioScale {
    static let dp: CGFloat = 2.0
}

@inline(__always) func dp(_ value: CGFloat) -> CGFloat { value * NuvioScale.dp }
@inline(__always) func sp(_ value: CGFloat) -> CGFloat { value * NuvioScale.dp }

// MARK: - Primitives (port of NuvioPrimitives)

enum NuvioPrimitives {
    static let black = Color(hex: 0xFF000000)
    static let white = Color(hex: 0xFFFFFFFF)
    static let neutral950 = Color(hex: 0xFF0D0D0D)
    static let neutral925 = Color(hex: 0xFF111111)
    static let neutral900 = Color(hex: 0xFF1A1A1A)
    static let neutral875 = Color(hex: 0xFF1E1E1E)
    static let neutral850 = Color(hex: 0xFF222222)
    static let neutral825 = Color(hex: 0xFF242424)
    static let neutral800 = Color(hex: 0xFF2D2D2D)
    static let neutral750 = Color(hex: 0xFF333333)
    static let neutral700 = Color(hex: 0xFF4D4D4D)
    static let neutral650 = Color(hex: 0xFF6F6F6F)
    static let neutral600 = Color(hex: 0xFF808080)
    static let neutral500 = Color(hex: 0xFF9E9E9E)
    static let neutral400 = Color(hex: 0xFFB3B3B3)
    static let neutral200 = Color(hex: 0xFFE0E0E0)
    static let neutral100 = Color(hex: 0xFFF5F5F5)
    static let red500 = Color(hex: 0xFFE53935)
    static let red600 = Color(hex: 0xFFC62828)
    static let red300 = Color(hex: 0xFFFF5252)
    static let blue500 = Color(hex: 0xFF1E88E5)
    static let blue700 = Color(hex: 0xFF1565C0)
    static let blue300 = Color(hex: 0xFF42A5F5)
    static let violet500 = Color(hex: 0xFF8E24AA)
    static let violet700 = Color(hex: 0xFF6A1B9A)
    static let violet300 = Color(hex: 0xFFAB47BC)
    static let green500 = Color(hex: 0xFF43A047)
    static let green700 = Color(hex: 0xFF2E7D32)
    static let green300 = Color(hex: 0xFF66BB6A)
    static let amber500 = Color(hex: 0xFFFB8C00)
    static let amber700 = Color(hex: 0xFFEF6C00)
    static let amber300 = Color(hex: 0xFFFFA726)
    static let rose500 = Color(hex: 0xFFD81B60)
    static let rose700 = Color(hex: 0xFFC2185B)
    static let rose300 = Color(hex: 0xFFEC407A)
    static let rating = Color(hex: 0xFFFFD700)
    static let error = Color(hex: 0xFFCF6679)
    static let warning = Color(hex: 0xFFFFB74D)
    static let success = Color(hex: 0xFF4CAF50)
    static let info = Color(hex: 0xFF29B6F6)
    static let torrent = Color(hex: 0xFF7E57C2)
    static let premium = Color(hex: 0xFFFFD54F)
    static let trakt = Color(hex: 0xFFED1C24)
    static let tmdb = Color(hex: 0xFF01B4E4)
    static let imdb = Color(hex: 0xFFF5C518)
    static let mdblist = Color(hex: 0xFF7DD3FC)
}

// MARK: - Spacing (port of NuvioSpacing)

struct NuvioScreenSpacing {
    let horizontal, vertical: CGFloat
    let compactHorizontal, compactVertical: CGFloat
    let overscanHorizontal, overscanVertical: CGFloat
}

struct NuvioRailSpacing {
    let horizontalPadding, verticalPadding: CGFloat
    let rowGap, itemGap: CGFloat
    let headerBottom, tailPadding: CGFloat
}

struct NuvioPanelSpacing {
    let outer, inner, gap, compactGap: CGFloat
}

struct NuvioSpacingTokens {
    let none = dp(0)
    let hairline = dp(1)
    let xxs = dp(2)
    let xs = dp(4)
    let sm = dp(8)
    let md = dp(12)
    let lg = dp(16)
    let xl = dp(24)
    let xxl = dp(32)
    let xxxl = dp(48)
    let huge = dp(56)

    let screen = NuvioScreenSpacing(
        horizontal: dp(48), vertical: dp(24),
        compactHorizontal: dp(32), compactVertical: dp(16),
        overscanHorizontal: dp(56), overscanVertical: dp(36)
    )
    let rail = NuvioRailSpacing(
        horizontalPadding: dp(48), verticalPadding: dp(6),
        rowGap: dp(24), itemGap: dp(12),
        headerBottom: dp(14), tailPadding: dp(200)
    )
    let card = NuvioPanelSpacing(outer: dp(12), inner: dp(16), gap: dp(12), compactGap: dp(8))
    let dialog = NuvioPanelSpacing(outer: dp(32), inner: dp(24), gap: dp(16), compactGap: dp(12))
    let sidePanel = NuvioPanelSpacing(outer: dp(36), inner: dp(20), gap: dp(16), compactGap: dp(10))
    let player = NuvioPanelSpacing(outer: dp(52), inner: dp(16), gap: dp(14), compactGap: dp(8))
    let settings = NuvioPanelSpacing(outer: dp(32), inner: dp(20), gap: dp(16), compactGap: dp(12))
}

enum NuvioSpacing {
    static let tokens = NuvioSpacingTokens()
}

// MARK: - Radii & shapes (port of NuvioRadii / NuvioShapes)

struct NuvioRadiusTokens {
    let none = dp(0)
    let xxs = dp(2)
    let xs = dp(4)
    let sm = dp(8)
    let md = dp(12)
    let lg = dp(14)
    let xl = dp(16)
    let xxl = dp(20)
    let panel = dp(28)
    let full = dp(999)
}

enum NuvioRadii {
    static let tokens = NuvioRadiusTokens()
}

struct NuvioShapeTokens {
    let posterCard = NuvioRadii.tokens.md
    let backdropCard = NuvioRadii.tokens.xl
    let collectionCard = NuvioRadii.tokens.xl
    let button = NuvioRadii.tokens.md
    let iconButton = NuvioRadii.tokens.md
    let chip = NuvioRadii.tokens.full
    let badge = NuvioRadii.tokens.xs
    let dialog = NuvioRadii.tokens.xl
    let sidePanel = NuvioRadii.tokens.xxl
    let sidebar = dp(30)
    let navItem = NuvioRadii.tokens.full
    let progress = NuvioRadii.tokens.xxs
    let slider = NuvioRadii.tokens.full
    let field = NuvioRadii.tokens.md
    let menu = NuvioRadii.tokens.lg
}

enum NuvioShapes {
    static let tokens = NuvioShapeTokens()
}

// MARK: - Sizes (port of NuvioSizes)

struct NuvioIconSizes {
    let xs = dp(14), sm = dp(18), md = dp(22), lg = dp(28), xl = dp(36)
}

struct NuvioButtonSizes {
    let compactHeight = dp(40), defaultHeight = dp(52), largeHeight = dp(64), minWidth = dp(96)
}

struct NuvioSidebarSizes {
    let hiddenWidth = dp(0)
    let compactWidth = dp(72)
    let closedWidth = dp(184)
    let expandedWidth = dp(262)
    let expandedItemWidth = dp(148)
    let railItemHeight = dp(52)
    let leadingVisual = dp(34)
}

struct NuvioCardSizes {
    let posterWidth = dp(126), posterHeight = dp(189)
    let posterCompactWidth = dp(112), posterCompactHeight = dp(168)
    let backdropWidth = dp(320), backdropHeight = dp(180)
    let episodeWidth = dp(320), episodeHeight = dp(207)
}

struct NuvioAvatarSizes {
    let sm = dp(34), md = dp(48), lg = dp(82), xl = dp(112)
    let profile = dp(126), profileCompact = dp(104)
}

struct NuvioPlayerSizes {
    let control = dp(44), compactControl = dp(40)
    let timelineHeight = dp(4), sidePanelWidth = dp(360), railWidth = dp(280)
}

struct NuvioSettingsSizes {
    let railWidth = dp(260), railItemHeight = dp(56)
    let workspaceMinWidth = dp(720), rowMinHeight = dp(64)
}

struct NuvioSizeTokens {
    let icons = NuvioIconSizes()
    let buttons = NuvioButtonSizes()
    let sidebar = NuvioSidebarSizes()
    let cards = NuvioCardSizes()
    let avatars = NuvioAvatarSizes()
    let player = NuvioPlayerSizes()
    let settings = NuvioSettingsSizes()
    let logoWidth = dp(190)
    let logoHeight = dp(44)
    let menuItemHeight = dp(48)
}

enum NuvioSizes {
    static let tokens = NuvioSizeTokens()
}

// MARK: - Component tokens (port of NuvioComponents)

struct NuvioCardComponentTokens {
    let width, height, cornerRadius, contentPadding, focusedBorderWidth: CGFloat
    let focusedScale: CGFloat
}

struct NuvioRowComponentTokens {
    let horizontalPadding = dp(48)
    let verticalPadding = dp(6)
    let itemSpacing = dp(12)
    let titleBottomSpacing = dp(14)
}

struct NuvioSidebarComponentTokens {
    let legacyCollapsedWidth = dp(72)
    let legacyExpandedWidth = dp(196)
    let collapsedWidth = dp(184)
    let expandedWidth = dp(262)
    let itemHeight = dp(52)
    let itemWidth = dp(148)
    let iconSize = dp(22)
    let leadingVisual = dp(34)
    let panelRadius = dp(30)
    let contentGap = dp(14)
}

struct NuvioDialogComponentTokens {
    let maxWidth, contentPadding, cornerRadius, actionSpacing: CGFloat
}

struct NuvioPlayerComponentTokens {
    let overlayHorizontalPadding = dp(52)
    let overlayVerticalPadding = dp(36)
    let controlSize = dp(44)
    let sidePanelWidth = dp(360)
    let railWidth = dp(280)
    let progressHeight = dp(4)
}

struct NuvioSettingsComponentTokens {
    let containerRadius = dp(28)
    let secondaryCardRadius = dp(18)
    let railItemHeight = dp(56)
    let workspacePadding = dp(20)
    let rowGap = dp(16)
}

struct NuvioComponentTokens {
    let posterCard = NuvioCardComponentTokens(
        width: dp(126), height: dp(189), cornerRadius: dp(12),
        contentPadding: dp(8), focusedBorderWidth: dp(2), focusedScale: 1.02
    )
    let backdropCard = NuvioCardComponentTokens(
        width: dp(320), height: dp(180), cornerRadius: dp(16),
        contentPadding: dp(16), focusedBorderWidth: dp(2), focusedScale: 1.02
    )
    let collectionCard = NuvioCardComponentTokens(
        width: dp(320), height: dp(180), cornerRadius: dp(16),
        contentPadding: dp(16), focusedBorderWidth: dp(2), focusedScale: 1.02
    )
    let continueWatchingCard = NuvioCardComponentTokens(
        width: dp(260), height: dp(146), cornerRadius: dp(12),
        contentPadding: dp(12), focusedBorderWidth: dp(2), focusedScale: 1.02
    )
    let episodeCard = NuvioCardComponentTokens(
        width: dp(320), height: dp(207), cornerRadius: dp(16),
        contentPadding: dp(16), focusedBorderWidth: dp(2), focusedScale: 1.02
    )
    let row = NuvioRowComponentTokens()
    let sidebar = NuvioSidebarComponentTokens()
    let dialog = NuvioDialogComponentTokens(
        maxWidth: dp(720), contentPadding: dp(24), cornerRadius: dp(16), actionSpacing: dp(12)
    )
    let sidePanel = NuvioDialogComponentTokens(
        maxWidth: dp(420), contentPadding: dp(20), cornerRadius: dp(20), actionSpacing: dp(12)
    )
    let settings = NuvioSettingsComponentTokens()
    let player = NuvioPlayerComponentTokens()
    let buttonHeight = dp(52)
    let chipHeight = dp(32)
    let badgeHeight = dp(20)
    let skeletonCornerRadius = dp(10)
}

enum NuvioComponents {
    static let tokens = NuvioComponentTokens()
}

// MARK: - Motion & focus (port of NuvioMotion / NuvioFocus)

struct NuvioMotionDurations {
    let instant = 0.0
    let quick = 0.125
    let fast = 0.180
    let medium = 0.350
    let slow = 0.450
    let overlay = 0.400
    let sidebarLabelIn = 0.125
    let sidebarLabelOut = 0.145
    let sidebarPanelIn = 0.345
    let sidebarPanelOut = 0.385
    let sidebarBloomOut = 0.395
    let sidebarEnter = 0.385
    let sidebarExit = 0.145
    let hero = 0.450
    let shimmer = 1.200
}

enum NuvioMotion {
    static let durations = NuvioMotionDurations()

    /// Compose `FastOutSlowInEasing` — cubic-bezier(0.4, 0, 0.2, 1)
    static let standard = UnitCurve.bezier(startControlPoint: .init(x: 0.4, y: 0), endControlPoint: .init(x: 0.2, y: 1))
    /// Compose emphasized — cubic-bezier(0.2, 0, 0, 1)
    static let emphasized = UnitCurve.bezier(startControlPoint: .init(x: 0.2, y: 0), endControlPoint: .init(x: 0, y: 1))
    /// Compose `LinearOutSlowInEasing` — cubic-bezier(0, 0, 0.2, 1)
    static let decelerate = UnitCurve.bezier(startControlPoint: .init(x: 0, y: 0), endControlPoint: .init(x: 0.2, y: 1))
    /// Compose accelerate — cubic-bezier(0.4, 0, 1, 1)
    static let accelerate = UnitCurve.bezier(startControlPoint: .init(x: 0.4, y: 0), endControlPoint: .init(x: 1, y: 1))

    static let focusScale: CGFloat = 1.02
    static let selectedScale: CGFloat = 1.01
    static let pressedScale: CGFloat = 0.98

    static var quickTween: Animation { .timingCurve(0.4, 0, 0.2, 1, duration: durations.quick) }
    static var focusTween: Animation { .timingCurve(0.4, 0, 0.2, 1, duration: durations.fast) }
    static var mediumTween: Animation { .timingCurve(0.4, 0, 0.2, 1, duration: durations.medium) }
    static var slowTween: Animation { .timingCurve(0, 0, 0.2, 1, duration: durations.slow) }
    static var sidebarPanelIn: Animation { .timingCurve(0.4, 0, 0.2, 1, duration: durations.sidebarPanelIn) }
    static var sidebarPanelOut: Animation { .timingCurve(0, 0, 0.2, 1, duration: durations.sidebarPanelOut) }
}

struct NuvioFocusTokens {
    let scale: CGFloat = 1.02
    let subtleScale: CGFloat = 1.01
    let pressedScale: CGFloat = 0.98
    let disabledScale: CGFloat = 1.0
    let scrollViewportTarget: CGFloat = 0.42
}

enum NuvioFocus {
    static let tokens = NuvioFocusTokens()
}

// MARK: - Layout & media (port of NuvioLayout / NuvioMedia)

struct NuvioLayoutTokens {
    /// Android composes Home in a 960dp-wide space; through the density bridge that is the
    /// 1920pt tvOS canvas. Grids size their column count against it.
    let screenWidth = dp(960)
    let tvSafeHorizontal = dp(48)
    let tvSafeVertical = dp(24)
    let compactSafeHorizontal = dp(32)
    let compactSafeVertical = dp(16)
    let sidebarContentOffset = dp(54)
    let rowAnchor: CGFloat = 0.42
    let detailsHeroWidthFraction: CGFloat = 0.62
    let detailsHeroHeightFraction: CGFloat = 0.72
}

enum NuvioLayout {
    static let tokens = NuvioLayoutTokens()
}

struct NuvioMediaTokens {
    let posterAspectRatio: CGFloat = 2.0 / 3.0
    let backdropAspectRatio: CGFloat = 16.0 / 9.0
    let heroAspectRatio: CGFloat = 16.0 / 9.0
    let logoAspectRatio: CGFloat = 190.0 / 44.0
    let thumbnailAspectRatio: CGFloat = 16.0 / 9.0
    let posterFallbackIconFraction: CGFloat = 0.28
    let backdropGradientStops: [CGFloat] = [0, 0.55, 1]
    let playerOverlayGradientStops: [CGFloat] = [0, 0.65, 1]
}

enum NuvioMedia {
    static let tokens = NuvioMediaTokens()
}

// MARK: - Strokes, elevations, effects

struct NuvioStrokeTokens {
    let none = dp(0)
    let hairline = dp(1)
    let thin = dp(1.5)
    let medium = dp(2)
    let focus = dp(2)
    let heavy = dp(3)
    let progress = dp(4)
    let divider = dp(1)
}

enum NuvioStrokes {
    static let tokens = NuvioStrokeTokens()
}

struct NuvioElevationTokens {
    let none = dp(0)
    let card = dp(2)
    let focused = dp(8)
    let menu = dp(8)
    let dialog = dp(12)
    let overlay = dp(16)
}

enum NuvioElevations {
    static let tokens = NuvioElevationTokens()
}

struct NuvioEffectTokens {
    let blurSoft = dp(12)
    let blurPanel = dp(26)
    let blurStrong = dp(40)
    let scrimLightAlpha: CGFloat = 0.28
    let scrimMediumAlpha: CGFloat = 0.52
    let scrimStrongAlpha: CGFloat = 0.78
    let glowSoftAlpha: CGFloat = 0.18
    let glowStrongAlpha: CGFloat = 0.38
    let imageOverlayAlpha: CGFloat = 0.62
    let disabledAlpha: CGFloat = 0.42
    let shimmerLowAlpha: CGFloat = 0.08
    let shimmerHighAlpha: CGFloat = 0.18
}

enum NuvioEffects {
    static let tokens = NuvioEffectTokens()
}

// MARK: - Color helper

extension Color {
    /// Builds a color from a Compose-style 0xAARRGGBB literal.
    init(hex: UInt32) {
        let a = Double((hex >> 24) & 0xFF) / 255.0
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Parses `#RGB`, `#RRGGBB` and `#AARRGGBB` strings coming from addon manifests.
    init?(cssHex: String) {
        var s = cssHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt32(s, radix: 16) else { return nil }
        switch s.count {
        case 3:
            let r = (value >> 8) & 0xF, g = (value >> 4) & 0xF, b = value & 0xF
            self.init(hex: 0xFF000000 | (r * 17) << 16 | (g * 17) << 8 | (b * 17))
        case 6:
            self.init(hex: 0xFF000000 | value)
        case 8:
            self.init(hex: value)
        default:
            return nil
        }
    }
}
