import SwiftUI

/// A palette built from one colour the viewer chose.
///
/// Port of `custom_theme_colors`, which upstream drives with a three-colour hex dialog and an
/// on-screen colour picker. **The picker is the bulk of that work and it is the part worth not
/// copying**: choosing a hue with a D-pad is slow, imprecise and the reason most people never
/// touch such a control. The hex goes to the phone instead, through the same `LocalConfigServer`
/// that already serves the debrid formatter, the badge rules, the plugin repositories and the
/// poster URL.
///
/// One colour rather than three, and that is a reading of the seven presets rather than a
/// shortcut: every one of them is an accent plus the same background tinted towards it. The
/// derivation below reproduces that relationship, so a custom theme sits beside the presets
/// instead of looking like a different app.
enum CustomThemePalette {
    /// What a viewer gets before they have chosen anything — Nuvio's own accent, so the theme is
    /// never a black screen with invisible focus.
    static let defaultHex = "E5484D"

    /// Parses `#RRGGBB`, `RRGGBB` or `#AARRGGBB`. Returns `nil` for anything else, so a half-typed
    /// value leaves the previous theme standing rather than resolving to black.
    static func color(fromHex raw: String) -> Color? {
        guard let value = components(fromHex: raw) else { return nil }
        return Color(
            .sRGB,
            red: Double(value.red) / 255,
            green: Double(value.green) / 255,
            blue: Double(value.blue) / 255,
            opacity: 1
        )
    }

    static func components(fromHex raw: String) -> (red: Int, green: Int, blue: Int)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        // An eight-digit value is `AARRGGBB`, which is how Android writes these. The alpha is
        // dropped rather than honoured: a translucent accent would make focus unreadable.
        if text.count == 8 { text = String(text.dropFirst(2)) }
        guard text.count == 6, text.allSatisfy(\.isHexDigit),
              let value = Int(text, radix: 16)
        else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    static func hex(_ components: (red: Int, green: Int, blue: Int)) -> String {
        String(format: "%02X%02X%02X", components.red, components.green, components.blue)
    }

    /// Mixes towards black or white by `amount`, which is how the presets relate their accent to
    /// its variant and its focus ring.
    static func shifted(
        _ components: (red: Int, green: Int, blue: Int), towards target: Int, amount: Double
    ) -> (red: Int, green: Int, blue: Int) {
        func mix(_ channel: Int) -> Int {
            Int((Double(channel) + (Double(target) - Double(channel)) * amount).rounded())
        }
        return (mix(components.red), mix(components.green), mix(components.blue))
    }

    /// The accent's hue laid over a near-black ground at the weight the presets use.
    ///
    /// Not a mix towards the accent at full strength: `focusBackground` and `backgroundCard` are
    /// surfaces a viewer reads text on, and the presets keep them within a few points of neutral.
    static func tintedSurface(
        _ components: (red: Int, green: Int, blue: Int), base: Int, weight: Double
    ) -> (red: Int, green: Int, blue: Int) {
        func mix(_ channel: Int) -> Int {
            min(255, max(0, Int((Double(base) + Double(channel) * weight).rounded())))
        }
        return (mix(components.red), mix(components.green), mix(components.blue))
    }

    /// Whether text on this accent should be black rather than white.
    ///
    /// Relative luminance, the same rule WCAG uses. A pale accent — the reason the `white` preset
    /// overrides `onSecondary` by hand — would otherwise put white text on near-white buttons.
    static func prefersDarkForeground(
        _ components: (red: Int, green: Int, blue: Int)
    ) -> Bool {
        func channel(_ value: Int) -> Double {
            let normalised = Double(value) / 255
            return normalised <= 0.03928
                ? normalised / 12.92
                : pow((normalised + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(components.red)
            + 0.7152 * channel(components.green)
            + 0.0722 * channel(components.blue)
        return luminance > 0.5
    }

    static func palette(accentHex: String) -> ThemeColorPalette {
        let accent = components(fromHex: accentHex)
            ?? components(fromHex: defaultHex)!
        let dark = prefersDarkForeground(accent)

        func color(_ value: (red: Int, green: Int, blue: Int)) -> Color {
            Color(
                .sRGB,
                red: Double(value.red) / 255,
                green: Double(value.green) / 255,
                blue: Double(value.blue) / 255,
                opacity: 1
            )
        }

        return ThemeColorPalette(
            secondary: color(accent),
            secondaryVariant: color(shifted(accent, towards: 0, amount: 0.22)),
            onSecondary: dark ? NuvioPrimitives.neutral925 : NuvioPrimitives.white,
            onSecondaryVariant: dark ? NuvioPrimitives.neutral925 : NuvioPrimitives.white,
            focusRing: color(shifted(accent, towards: 255, amount: 0.35)),
            focusBackground: color(tintedSurface(accent, base: 12, weight: 0.18)),
            backgroundCard: color(tintedSurface(accent, base: 20, weight: 0.05))
        )
    }
}
