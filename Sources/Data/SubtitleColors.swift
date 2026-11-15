import Foundation

/// The colour presets the in-player panel and the settings editor offer, and the `#AARRGGBB`
/// arithmetic both need — upstream's `SubtitleColorPresets` (1.2.0-beta.1).
enum SubtitleColors {
    struct Preset: Hashable {
        var title: String
        var rgb: String
    }

    // Computed rather than stored, so a language change is read on the next draw; and spelled
    // out, so the localisation check can see every key.
    static var text: [Preset] {
        [
            .init(title: L10n.text("player.color_white", fallback: "White"), rgb: "FFFFFF"),
            .init(title: L10n.text("player.color_light_grey", fallback: "Light grey"), rgb: "D9D9D9"),
            .init(title: L10n.text("player.color_yellow", fallback: "Yellow"), rgb: "FFD700"),
            .init(title: L10n.text("player.color_cyan", fallback: "Cyan"), rgb: "00E5FF"),
            .init(title: L10n.text("player.color_red", fallback: "Red"), rgb: "FF5C5C"),
            .init(title: L10n.text("player.color_green", fallback: "Green"), rgb: "00FF88")
        ]
    }

    static var outline: [Preset] {
        [
            .init(title: L10n.text("player.color_black", fallback: "Black"), rgb: "000000"),
            .init(title: L10n.text("player.color_white", fallback: "White"), rgb: "FFFFFF"),
            .init(title: L10n.text("player.color_cyan", fallback: "Cyan"), rgb: "00E5FF"),
            .init(title: L10n.text("player.color_red", fallback: "Red"), rgb: "FF5C5C")
        ]
    }

    static var background: [Preset] {
        [
            .init(title: L10n.text("player.color_black", fallback: "Black"), rgb: "000000"),
            .init(title: L10n.text("player.color_dark_grey", fallback: "Dark grey"), rgb: "3A3A3A"),
            .init(title: L10n.text("player.color_white", fallback: "White"), rgb: "FFFFFF"),
            .init(title: L10n.text("player.color_yellow", fallback: "Yellow"), rgb: "FFD700"),
            .init(title: L10n.text("player.color_blue", fallback: "Blue"), rgb: "1E3A8A")
        ]
    }

    /// `SUBTITLE_BACKGROUND_DEFAULT_OPACITY`: what a background gets when it had none.
    static let backgroundDefaultOpacity = 75

    static func rgb(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "#", with: "").uppercased()
        return cleaned.count == 8 ? String(cleaned.suffix(6)) : cleaned
    }

    static func alphaPercent(_ value: String) -> Int {
        let cleaned = value.replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 8, let alpha = Int(cleaned.prefix(2), radix: 16) else { return 100 }
        return Int((Double(alpha) / 255 * 100).rounded())
    }

    static func color(_ rgb: String, preservingAlphaFrom current: String) -> String {
        let cleaned = current.replacingOccurrences(of: "#", with: "")
        let alpha = cleaned.count == 8 ? String(cleaned.prefix(2)) : "FF"
        return "#\(alpha)\(Self.rgb(rgb))"
    }

    static func color(_ current: String, alphaPercent: Int) -> String {
        let clamped = min(100, max(0, alphaPercent))
        let alpha = String(format: "%02X", Int((Double(clamped) / 100 * 255).rounded()))
        return "#\(alpha)\(rgb(current))"
    }

    /// `subtitleBackgroundColorFor`: a preset keeps the current opacity, or takes the default
    /// one when the background was off.
    static func background(_ rgb: String, current: String) -> String {
        let alpha = alphaPercent(current)
        return color(rgb, alphaPercent: alpha > 0 ? alpha : backgroundDefaultOpacity)
    }

    /// `selectedSubtitleBackgroundPreset`: no preset is selected while the background is off.
    static func selectedBackground(_ current: String) -> String? {
        alphaPercent(current) > 0 ? rgb(current) : nil
    }
}
