import SwiftUI

// MARK: - Theme identity (port of AppTheme / AppFont)

enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case crimson, ocean, violet, emerald, amber, rose, white
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .crimson: return "Crimson"
        case .ocean: return "Ocean"
        case .violet: return "Violet"
        case .emerald: return "Emerald"
        case .amber: return "Amber"
        case .rose: return "Rose"
        case .white: return "White"
        }
    }
}

enum AppFont: String, CaseIterable, Codable, Identifiable {
    case inter, dmSans, openSans
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inter: return "Inter"
        case .dmSans: return "DM Sans"
        case .openSans: return "Open Sans"
        }
    }

    /// PostScript family names of the bundled variable fonts.
    var familyName: String {
        switch self {
        case .inter: return "Inter"
        case .dmSans: return "DM Sans"
        case .openSans: return "Open Sans"
        }
    }
}

// MARK: - Palette (port of ThemeColorPalette / ThemeColors)

struct ThemeColorPalette {
    var secondary: Color
    var secondaryVariant: Color
    var onSecondary: Color = NuvioPrimitives.white
    var onSecondaryVariant: Color = NuvioPrimitives.white
    var focusRing: Color
    var focusBackground: Color
    var background: Color = NuvioPrimitives.neutral950
    var backgroundElevated: Color = NuvioPrimitives.neutral900
    var backgroundCard: Color = NuvioPrimitives.neutral825
    var surface: Color = NuvioPrimitives.neutral875
    var surfaceVariant: Color = NuvioPrimitives.neutral800
    var panel: Color = NuvioPrimitives.neutral900
    var overlay: Color = Color(hex: 0xD9000000)
    var field: Color = NuvioPrimitives.neutral850
    var menu: Color = NuvioPrimitives.neutral875
    var modal: Color = NuvioPrimitives.neutral900
    var playerOverlay: Color = Color(hex: 0xCC000000)
}

enum ThemeColors {
    static let crimson = ThemeColorPalette(
        secondary: NuvioPrimitives.red500,
        secondaryVariant: NuvioPrimitives.red600,
        focusRing: NuvioPrimitives.red300,
        focusBackground: Color(hex: 0xFF3D1A1A),
        backgroundCard: Color(hex: 0xFF241A1A)
    )

    static let ocean = ThemeColorPalette(
        secondary: NuvioPrimitives.blue500,
        secondaryVariant: NuvioPrimitives.blue700,
        focusRing: NuvioPrimitives.blue300,
        focusBackground: Color(hex: 0xFF1A2D3D),
        background: Color(hex: 0xFF0D0D0F),
        backgroundElevated: Color(hex: 0xFF1A1A1E),
        backgroundCard: Color(hex: 0xFF1A1F24)
    )

    static let violet = ThemeColorPalette(
        secondary: NuvioPrimitives.violet500,
        secondaryVariant: NuvioPrimitives.violet700,
        focusRing: NuvioPrimitives.violet300,
        focusBackground: Color(hex: 0xFF2D1A3D),
        background: Color(hex: 0xFF0D0D0F),
        backgroundElevated: Color(hex: 0xFF1A1A1E),
        backgroundCard: Color(hex: 0xFF1F1A24)
    )

    static let emerald = ThemeColorPalette(
        secondary: NuvioPrimitives.green500,
        secondaryVariant: NuvioPrimitives.green700,
        focusRing: NuvioPrimitives.green300,
        focusBackground: Color(hex: 0xFF1A3D1E),
        backgroundCard: Color(hex: 0xFF1A241A)
    )

    static let amber = ThemeColorPalette(
        secondary: NuvioPrimitives.amber500,
        secondaryVariant: NuvioPrimitives.amber700,
        focusRing: NuvioPrimitives.amber300,
        focusBackground: Color(hex: 0xFF3D2D1A),
        background: Color(hex: 0xFF0F0D0D),
        backgroundElevated: Color(hex: 0xFF1E1A1A),
        backgroundCard: Color(hex: 0xFF24201A)
    )

    static let rose = ThemeColorPalette(
        secondary: NuvioPrimitives.rose500,
        secondaryVariant: NuvioPrimitives.rose700,
        focusRing: NuvioPrimitives.rose300,
        focusBackground: Color(hex: 0xFF3D1A2D),
        backgroundCard: Color(hex: 0xFF241A1F)
    )

    static let white = ThemeColorPalette(
        secondary: NuvioPrimitives.neutral100,
        secondaryVariant: NuvioPrimitives.neutral200,
        onSecondary: NuvioPrimitives.neutral925,
        onSecondaryVariant: NuvioPrimitives.neutral925,
        focusRing: NuvioPrimitives.white,
        focusBackground: Color(hex: 0xFF303030),
        backgroundCard: NuvioPrimitives.neutral850
    )

    static func palette(for theme: AppTheme) -> ThemeColorPalette {
        switch theme {
        case .crimson: return crimson
        case .ocean: return ocean
        case .violet: return violet
        case .emerald: return emerald
        case .amber: return amber
        case .rose: return rose
        case .white: return white
        }
    }
}

// MARK: - Color scheme (port of NuvioColorScheme)

struct NuvioColorScheme {
    let background: Color
    let backgroundElevated: Color
    let backgroundCard: Color
    let surface: Color
    let surfaceVariant: Color
    let panel: Color
    let overlay: Color
    let field: Color
    let menu: Color
    let modal: Color
    let playerOverlay: Color
    let divider: Color

    let primary: Color
    let primaryVariant: Color
    let onPrimary: Color
    let secondary: Color
    let secondaryVariant: Color
    let onSecondary: Color
    let onSecondaryVariant: Color

    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textDisabled: Color
    let textInverse: Color

    let focusRing: Color
    let focusBackground: Color
    let focusContent: Color
    let focusScrim: Color

    let rating: Color
    let error: Color
    let warning: Color
    let success: Color
    let info: Color
    let watched: Color
    let unwatched: Color
    let cached: Color
    let torrent: Color
    let premium: Color

    let border: Color
    let borderFocused: Color
    let borderMuted: Color

    let scrim: Color
    let imageScrim: Color
    let videoControlsScrim: Color
    let posterFallback: Color

    let disabledContainer: Color
    let disabledContent: Color
    let disabledBorder: Color
    let disabledOverlay: Color

    let glassPanelTop: Color
    let glassPanelMiddle: Color
    let glassPanelBottom: Color
    let glow: Color

    let sourceTrakt: Color
    let sourceTmdb: Color
    let sourceImdb: Color
    let sourceMdblist: Color

    init(palette: ThemeColorPalette, amoledMode: Bool = false, amoledSurfaces: Bool = false) {
        let pureBlack = NuvioPrimitives.black
        let pureBlackSurfaces = amoledMode && amoledSurfaces

        background = amoledMode ? pureBlack : palette.background
        backgroundElevated = pureBlackSurfaces ? pureBlack : palette.backgroundElevated
        backgroundCard = pureBlackSurfaces ? pureBlack : palette.backgroundCard
        surface = pureBlackSurfaces ? pureBlack : palette.surface
        surfaceVariant = pureBlackSurfaces ? pureBlack : palette.surfaceVariant
        panel = pureBlackSurfaces ? pureBlack : palette.panel
        overlay = palette.overlay
        field = pureBlackSurfaces ? pureBlack : palette.field
        menu = pureBlackSurfaces ? pureBlack : palette.menu
        modal = pureBlackSurfaces ? pureBlack : palette.modal
        playerOverlay = palette.playerOverlay
        divider = NuvioPrimitives.neutral750

        primary = NuvioPrimitives.neutral500
        primaryVariant = NuvioPrimitives.neutral650
        onPrimary = NuvioPrimitives.white
        secondary = palette.secondary
        secondaryVariant = palette.secondaryVariant
        onSecondary = palette.onSecondary
        onSecondaryVariant = palette.onSecondaryVariant

        textPrimary = NuvioPrimitives.white
        textSecondary = NuvioPrimitives.neutral400
        textTertiary = NuvioPrimitives.neutral600
        textDisabled = NuvioPrimitives.neutral700
        textInverse = NuvioPrimitives.neutral925

        focusRing = palette.focusRing
        focusBackground = palette.focusBackground
        focusContent = NuvioPrimitives.white
        focusScrim = NuvioPrimitives.black.opacity(0.32)

        rating = NuvioPrimitives.rating
        error = NuvioPrimitives.error
        warning = NuvioPrimitives.warning
        success = NuvioPrimitives.success
        info = NuvioPrimitives.info
        watched = NuvioPrimitives.success
        unwatched = NuvioPrimitives.neutral600
        cached = NuvioPrimitives.blue300
        torrent = NuvioPrimitives.torrent
        premium = NuvioPrimitives.premium

        border = NuvioPrimitives.neutral750
        borderFocused = palette.focusRing
        borderMuted = NuvioPrimitives.neutral750.opacity(0.58)

        scrim = NuvioPrimitives.black.opacity(0.62)
        imageScrim = NuvioPrimitives.black.opacity(0.58)
        videoControlsScrim = NuvioPrimitives.black.opacity(0.72)
        posterFallback = pureBlackSurfaces ? pureBlack : palette.backgroundCard

        disabledContainer = (pureBlackSurfaces ? pureBlack : palette.surfaceVariant).opacity(0.42)
        disabledContent = NuvioPrimitives.neutral700
        disabledBorder = NuvioPrimitives.neutral750.opacity(0.48)
        disabledOverlay = NuvioPrimitives.black.opacity(0.42)

        glassPanelTop = Color(hex: 0xD64A4F59)
        glassPanelMiddle = Color(hex: 0xCC3F454F)
        glassPanelBottom = Color(hex: 0xC640474F)
        glow = palette.focusRing.opacity(0.32)

        sourceTrakt = NuvioPrimitives.trakt
        sourceTmdb = NuvioPrimitives.tmdb
        sourceImdb = NuvioPrimitives.imdb
        sourceMdblist = NuvioPrimitives.mdblist
    }
}

// MARK: - Environment plumbing

private struct NuvioColorsKey: EnvironmentKey {
    static let defaultValue = NuvioColorScheme(palette: ThemeColors.crimson)
}

private struct NuvioFontFamilyKey: EnvironmentKey {
    static let defaultValue: AppFont = .inter
}

extension EnvironmentValues {
    var nuvioColors: NuvioColorScheme {
        get { self[NuvioColorsKey.self] }
        set { self[NuvioColorsKey.self] = newValue }
    }

    var nuvioFont: AppFont {
        get { self[NuvioFontFamilyKey.self] }
        set { self[NuvioFontFamilyKey.self] = newValue }
    }
}

/// Convenience accessors mirroring `NuvioTheme.*` in the Compose codebase.
enum NuvioTheme {
    static let spacing = NuvioSpacing.tokens
    static let radii = NuvioRadii.tokens
    static let shapes = NuvioShapes.tokens
    static let sizes = NuvioSizes.tokens
    static let components = NuvioComponents.tokens
    static let layout = NuvioLayout.tokens
    static let media = NuvioMedia.tokens
    static let strokes = NuvioStrokes.tokens
    static let elevations = NuvioElevations.tokens
    static let effects = NuvioEffects.tokens
}
