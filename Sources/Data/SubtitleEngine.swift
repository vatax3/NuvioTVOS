import Foundation
import AVFoundation
import SwiftUI

// MARK: - Cues

/// One timed subtitle line, after parsing.
struct SubtitleCue: Hashable, Identifiable, Sendable {
    let start: Double
    let end: Double
    let text: String
    var id: String { "\(start)-\(end)-\(text.hashValue)" }

    func contains(_ time: Double) -> Bool { time >= start && time < end }
}

/// Parses the two formats addons actually serve: SubRip and WebVTT. Both are cue lists with a
/// `HH:MM:SS,mmm --> HH:MM:SS,mmm` timing line, so one scanner handles them.
enum SubtitleParser {
    static func parse(_ raw: String) -> [SubtitleCue] {
        // Strip a BOM and normalise line endings before splitting.
        let normalized = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            // WebVTT header and NOTE/STYLE/REGION blocks carry no cue.
            let first = lines[0].uppercased()
            if first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE")
                || first.hasPrefix("STYLE") || first.hasPrefix("REGION") { continue }

            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = timings(in: lines[timingIndex])
            else { continue }

            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            let text = stripMarkup(body)
            guard !text.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func timings(in line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        // A WebVTT timing line can carry cue settings after the end stamp ("align:start").
        let endToken = parts[1].trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        guard let start = seconds(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = seconds(endToken) else { return nil }
        return (start, end)
    }

    /// `HH:MM:SS,mmm`, `HH:MM:SS.mmm` or `MM:SS.mmm`.
    private static func seconds(_ stamp: String) -> Double? {
        let cleaned = stamp.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Cue payloads carry HTML-ish tags and, for SSA-converted files, `{\an8}` overrides.
    private static func stripMarkup(_ text: String) -> String {
        var result = text
        for pattern in [#"<[^>]+>"#, #"\{[^}]*\}"#] {
            result = result.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression
            )
        }
        return result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Styling

/// The subtitle appearance settings, resolved into drawable values.
///
/// Two consumers: the custom overlay that renders addon-supplied SRT/VTT, and
/// `AVPlayerItem.textStyleRules`, which is the only lever AVKit gives for tracks embedded in
/// the stream itself.
struct SubtitleStyle: Equatable {
    var sizeScale: Double = 1.0
    var bold: Bool = false
    var textColor: Color = .white
    var backgroundColor: Color = .clear
    var outlineEnabled: Bool = true
    var outlineColor: Color = .black
    var outlineWidth: Double = 2
    var verticalOffset: Double = 0

    static let `default` = SubtitleStyle()

    /// Base size before the viewer's scale. Matches the Compose default of 20sp.
    var fontSize: CGFloat { sp(20) * sizeScale }

    /// AVKit's own rules for legible tracks the container ships with. Only a few attributes
    /// are honoured, so this is deliberately a subset of what the overlay draws.
    var textStyleRules: [AVTextStyleRule] {
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: 100 * sizeScale,
            kCMTextMarkupAttribute_BoldStyle as String: bold
        ]
        if let components = textColor.rgbComponents {
            attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] =
                [1, components.red, components.green, components.blue]
        }
        if let components = backgroundColor.rgbComponents, backgroundColor.alphaComponent > 0.01 {
            attributes[kCMTextMarkupAttribute_BackgroundColorARGB as String] =
                [backgroundColor.alphaComponent, components.red, components.green, components.blue]
        }
        if outlineEnabled {
            // AVKit exposes edge style but not edge colour or width, so the overlay is the
            // only place those two settings can be honoured exactly.
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] =
                kCMTextMarkupCharacterEdgeStyle_Uniform as String
        }
        guard let rule = AVTextStyleRule(textMarkupAttributes: attributes) else { return [] }
        return [rule]
    }
}

extension Color {
    /// Parses the `#AARRGGBB` / `#RRGGBB` strings the preference store holds.
    init(argbHex: String) {
        let cleaned = argbHex.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
        guard let value = UInt64(cleaned, radix: 16) else {
            self = .white
            return
        }
        let hasAlpha = cleaned.count == 8
        let alpha = hasAlpha ? Double((value >> 24) & 0xFF) / 255 : 1
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var rgbComponents: (red: Double, green: Double, blue: Double)? {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else {
            return nil
        }
        return (Double(components[0]), Double(components[1]), Double(components[2]))
    }

    var alphaComponent: Double {
        Double(UIColor(self).cgColor.alpha)
    }
}

// MARK: - Track loading

/// Fetches and parses one external subtitle track.
actor SubtitleLoader {
    static let shared = SubtitleLoader()

    private var cache: [String: [SubtitleCue]] = [:]

    func cues(for subtitle: Subtitle) async throws -> [SubtitleCue] {
        if let cached = cache[subtitle.url] { return cached }
        guard let url = URL(string: subtitle.url) else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let text = decodeSubtitleText(data)
        let cues = SubtitleParser.parse(text)
        cache[subtitle.url] = cues
        return cues
    }

    /// Community SRTs frequently omit their charset. UTF-16 and Windows-1252 need dedicated
    /// handling; treating their bytes as Latin-1 is what produces boxes/mojibake on screen.
    private func decodeSubtitleText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian) ?? ""
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian) ?? ""
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}

// MARK: - Selection

enum SubtitleSelector {
    /// Applies the viewer's language preferences: preferred first, then secondary, then the
    /// rest — unless they asked to see only their languages.
    static func order(
        _ subtitles: [Subtitle],
        preferred: String,
        secondary: String,
        onlyPreferred: Bool
    ) -> [Subtitle] {
        let preferredCode = preferred.trimmingCharacters(in: .whitespaces).lowercased()
        let secondaryCode = secondary.trimmingCharacters(in: .whitespaces).lowercased()

        func rank(_ subtitle: Subtitle) -> Int {
            let lang = subtitle.lang.lowercased()
            if !preferredCode.isEmpty, lang.hasPrefix(preferredCode) { return 0 }
            if !secondaryCode.isEmpty, lang.hasPrefix(secondaryCode) { return 1 }
            return 2
        }

        let filtered = onlyPreferred && !(preferredCode.isEmpty && secondaryCode.isEmpty)
            ? subtitles.filter { rank($0) < 2 }
            : subtitles
        // Enumerate so the sort stays stable: equal-rank tracks keep the addon's own order.
        return filtered.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// The track to enable without asking, or nil to start with subtitles off.
    static func autoSelection(
        _ ordered: [Subtitle],
        preferred: String
    ) -> Subtitle? {
        let code = preferred.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty else { return nil }
        return ordered.first { $0.lang.lowercased().hasPrefix(code) }
    }

    /// Groups tracks for the picker, per `subtitle_organization_mode`.
    static func group(
        _ subtitles: [Subtitle],
        mode: SubtitleOrganizationMode
    ) -> [(title: String, items: [Subtitle])] {
        switch mode {
        case .byLanguage:
            let grouped = Dictionary(grouping: subtitles) { $0.displayLanguage }
            return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
        case .byAddon:
            let grouped = Dictionary(grouping: subtitles) { $0.addonName ?? "Unknown addon" }
            return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
        case .flat:
            return [("All subtitles", subtitles)]
        }
    }
}
