import SwiftUI
import UIKit
import CoreText

// MARK: - Variable-font resolution
//
// The three bundled families are variable fonts exposing a `wght` axis, exactly as on
// Android where `Font(R.font.inter_variable, FontWeight.X)` picks the axis instance.
// We build UIFonts with the axis pinned so weights match the Android app precisely
// instead of relying on synthetic bolding.

enum NuvioFontProvider {
    private static let weightAxis: Int = 0x77676874 // 'wght'
    private static var cache: [String: UIFont] = [:]
    private static let lock = NSLock()

    /// Compose FontWeight numeric values.
    enum Weight: Int {
        case normal = 400
        case medium = 500
        case semiBold = 600
        case bold = 700

        var uiWeight: UIFont.Weight {
            switch self {
            case .normal: return .regular
            case .medium: return .medium
            case .semiBold: return .semibold
            case .bold: return .bold
            }
        }
    }

    static func font(_ family: AppFont, weight: Weight, size: CGFloat) -> Font {
        Font(uiFont(family, weight: weight, size: size))
    }

    static func uiFont(_ family: AppFont, weight: Weight, size: CGFloat) -> UIFont {
        let key = "\(family.rawValue)-\(weight.rawValue)-\(size)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }

        let resolved: UIFont
        if let base = UIFont(name: family.familyName, size: size) {
            let descriptor = base.fontDescriptor.addingAttributes([
                kCTFontVariationAttribute as UIFontDescriptor.AttributeName: [weightAxis: weight.rawValue]
            ])
            resolved = UIFont(descriptor: descriptor, size: size)
        } else {
            // The family failed to register — fall back to the system face at the same weight
            // so layout metrics stay stable rather than silently collapsing to regular.
            resolved = UIFont.systemFont(ofSize: size, weight: weight.uiWeight)
        }
        cache[key] = resolved
        return resolved
    }
}

// MARK: - Text style (port of Compose TextStyle)

struct NuvioTextStyle {
    let weight: NuvioFontProvider.Weight
    /// Font size in Android `sp`; converted to tvOS points on use.
    let size: CGFloat
    /// Line box height in Android `sp`.
    let lineHeight: CGFloat
    /// Letter spacing in Android `sp`.
    let letterSpacing: CGFloat

    func font(_ family: AppFont) -> Font {
        NuvioFontProvider.font(family, weight: weight, size: sp(size))
    }

    var tracking: CGFloat { sp(letterSpacing) }

    /// SwiftUI adds `lineSpacing` on top of the natural line height, while Compose sets the
    /// whole line box. The delta against the font's own line height reproduces the same rhythm.
    func lineSpacing(_ family: AppFont) -> CGFloat {
        let ui = NuvioFontProvider.uiFont(family, weight: weight, size: sp(size))
        return max(0, sp(lineHeight) - ui.lineHeight)
    }

    func with(weight: NuvioFontProvider.Weight? = nil, letterSpacing: CGFloat? = nil) -> NuvioTextStyle {
        NuvioTextStyle(
            weight: weight ?? self.weight,
            size: size,
            lineHeight: lineHeight,
            letterSpacing: letterSpacing ?? self.letterSpacing
        )
    }
}

// MARK: - Scale (port of buildNuvioTypography)

enum NuvioTypography {
    static let displayLarge = NuvioTextStyle(weight: .bold, size: 48, lineHeight: 56, letterSpacing: -0.5)
    static let displayMedium = NuvioTextStyle(weight: .bold, size: 36, lineHeight: 44, letterSpacing: 0)
    static let headlineLarge = NuvioTextStyle(weight: .semiBold, size: 28, lineHeight: 36, letterSpacing: 0)
    static let headlineMedium = NuvioTextStyle(weight: .semiBold, size: 24, lineHeight: 32, letterSpacing: 0)
    static let titleLarge = NuvioTextStyle(weight: .medium, size: 20, lineHeight: 28, letterSpacing: 0)
    static let titleMedium = NuvioTextStyle(weight: .medium, size: 16, lineHeight: 24, letterSpacing: 0.15)
    static let titleSmall = NuvioTextStyle(weight: .medium, size: 14, lineHeight: 20, letterSpacing: 0.1)
    static let bodyLarge = NuvioTextStyle(weight: .normal, size: 16, lineHeight: 24, letterSpacing: 0.5)
    static let bodyMedium = NuvioTextStyle(weight: .normal, size: 14, lineHeight: 20, letterSpacing: 0.25)
    static let bodySmall = NuvioTextStyle(weight: .normal, size: 12, lineHeight: 16, letterSpacing: 0.4)
    static let labelLarge = NuvioTextStyle(weight: .medium, size: 14, lineHeight: 20, letterSpacing: 0.1)
    static let labelMedium = NuvioTextStyle(weight: .medium, size: 12, lineHeight: 16, letterSpacing: 0.5)
    static let labelSmall = NuvioTextStyle(weight: .medium, size: 10, lineHeight: 14, letterSpacing: 0.5)
}

// MARK: - Semantic styles (port of NuvioTextStyles)

enum NuvioTextStyles {
    static let display = NuvioTypography.displayLarge
    static let displayCompact = NuvioTypography.displayMedium
    static let headline = NuvioTypography.headlineLarge
    static let sectionTitle = NuvioTypography.headlineMedium
    static let cardTitle = NuvioTypography.titleMedium
    static let body = NuvioTypography.bodyLarge
    static let bodyCompact = NuvioTypography.bodyMedium
    static let metadata = NuvioTypography.labelMedium
    static let badge = NuvioTypography.labelSmall.with(weight: .semiBold, letterSpacing: 0.8)
    static let button = NuvioTypography.labelLarge.with(weight: .semiBold)
    static let tab = NuvioTypography.titleSmall.with(weight: .semiBold)
    static let nav = NuvioTypography.titleMedium
    static let playerControl = NuvioTypography.titleLarge.with(weight: .semiBold)
}

// MARK: - Application

private struct NuvioTextStyleModifier: ViewModifier {
    @Environment(\.nuvioFont) private var family
    let style: NuvioTextStyle

    func body(content: Content) -> some View {
        content
            .font(style.font(family))
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing(family))
    }
}

extension View {
    func nuvioText(_ style: NuvioTextStyle) -> some View {
        modifier(NuvioTextStyleModifier(style: style))
    }
}

// MARK: - Font registration

enum NuvioFontRegistrar {
    private static var didRegister = false

    /// Registers the bundled variable fonts. `UIAppFonts` covers the normal case; this is the
    /// belt-and-braces path for when the resources land in a subdirectory of the bundle.
    static func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true

        let names = ["inter_variable", "dm_sans_variable", "opensans_variable"]
        for name in names {
            guard UIFont.familyNames.isEmpty || !isRegistered(name) else { continue }
            let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func isRegistered(_ resourceName: String) -> Bool {
        let expected: String
        switch resourceName {
        case "inter_variable": expected = "Inter"
        case "dm_sans_variable": expected = "DM Sans"
        default: expected = "Open Sans"
        }
        return UIFont.familyNames.contains(expected)
    }
}
