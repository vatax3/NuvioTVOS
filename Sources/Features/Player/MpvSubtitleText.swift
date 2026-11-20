import Foundation
import SwiftUI
import UIKit

/// mpv's current subtitle text, for the overlay to draw in place of mpv — upstream's
/// `parseMpvSubtitleText` as of 1.2.0-beta.2 (2c5398e85).
///
/// `sub-text/ass` carries the event text with its override blocks: `\i`, `\b` and `\u` become
/// italic, bold and underline runs, `\c` / `\1c` the file's own colour, `\r` resets them all, and
/// `\an1`–`\an9` place the event in one of nine positions. Every other tag is dropped. Line
/// breaks (`\N`, `\n`) and hard spaces (`\h`) are resolved.
///
/// Until 1.0.68 only `\an7`–`\an9` were read, as "top", and colours were dropped, so a sign in
/// a corner was drawn centred and every line in the viewer's colour.
struct MpvStyledSubtitleText: Equatable {
    enum Vertical: Hashable, CaseIterable { case top, middle, bottom }
    enum Horizontal: Hashable, CaseIterable { case start, center, end }

    struct Block: Equatable {
        var text: AttributedString
        var vertical: Vertical = .bottom
        var horizontal: Horizontal = .center

        var alignment: Alignment {
            switch (vertical, horizontal) {
            case (.top, .start): return .topLeading
            case (.top, .center): return .top
            case (.top, .end): return .topTrailing
            case (.middle, .start): return .leading
            case (.middle, .center): return .center
            case (.middle, .end): return .trailing
            case (.bottom, .start): return .bottomLeading
            case (.bottom, .center): return .bottom
            case (.bottom, .end): return .bottomTrailing
            }
        }
    }

    /// One block per position, events at the same position joined in order — upstream's
    /// `styledSubtitleCues`.
    var blocks: [Block]

    var isEmpty: Bool { blocks.allSatisfy { $0.text.characters.isEmpty } }

    /// The bottom-centre block, which stacks with addon cues above the transport.
    var bottomCenter: AttributedString? {
        blocks.first { $0.vertical == .bottom && $0.horizontal == .center }?.text
    }

    /// Every other block, each drawn at its own position.
    var placed: [Block] {
        blocks.filter { !($0.vertical == .bottom && $0.horizontal == .center) }
    }

    static func parse(_ text: String) -> MpvStyledSubtitleText {
        let events = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var grouped: [(Vertical, Horizontal, [AttributedString])] = []
        for event in events {
            let alignment = event.matches(of: overrideBlock)
                .flatMap { $0.output.matches(of: alignmentTag) }
                .last
                .flatMap { Int($0.output.1) } ?? 2
            let vertical: Vertical = (7...9).contains(alignment) ? .top : (4...6).contains(alignment) ? .middle : .bottom
            let horizontal: Horizontal = alignment % 3 == 1 ? .start : alignment % 3 == 0 ? .end : .center
            let annotated = annotated(event)
            guard !annotated.characters.isEmpty else { continue }
            if let index = grouped.firstIndex(where: { $0.0 == vertical && $0.1 == horizontal }) {
                grouped[index].2.append(annotated)
            } else {
                grouped.append((vertical, horizontal, [annotated]))
            }
        }
        return MpvStyledSubtitleText(blocks: grouped.map { Block(text: join($0.2), vertical: $0.0, horizontal: $0.1) })
    }

    /// The file's colours as drawn: scaled by `brightness` (the HDR style's dimming, upstream's
    /// `fileColorBrightness`) and made as transparent as the viewer's text colour.
    static func applyingFileColors(_ text: AttributedString, brightness: Double, textAlpha: Double) -> AttributedString {
        var result = text
        for run in text.runs {
            guard let color = run.uiKit.foregroundColor else { continue }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            result[run.range].uiKit.foregroundColor = nil
            result[run.range].foregroundColor = Color(
                .sRGB,
                red: red * brightness, green: green * brightness, blue: blue * brightness,
                opacity: alpha * textAlpha
            )
        }
        return result
    }

    private static let overrideBlock = /\{[^}]*\}/
    private static let alignmentTag = /\\an([1-9])(?!\d)/
    private static let styleTag = /\\(?:([ibu])(\d*)(?![a-z])|(1?c)(?:&H([0-9A-Fa-f]{1,8})&?|(?![a-z]))|r(?![a-z]))/

    private static func join(_ events: [AttributedString]) -> AttributedString {
        var result = AttributedString()
        for (index, event) in events.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            result.append(event)
        }
        return result
    }

    private static func annotated(_ event: String) -> AttributedString {
        var result = AttributedString()
        var italic = false, bold = false, underline = false
        var color: UIColor?
        var cursor = event.startIndex

        func appendPlain(_ raw: Substring) {
            let plain = raw.replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: "\u{00A0}")
            guard !plain.isEmpty else { return }
            var run = AttributedString(plain)
            var intent = InlinePresentationIntent()
            if italic { intent.insert(.emphasized) }
            if bold { intent.insert(.stronglyEmphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if underline { run.underlineStyle = .single }
            if let color { run.uiKit.foregroundColor = color }
            result.append(run)
        }

        for block in event.matches(of: overrideBlock) {
            appendPlain(event[cursor..<block.range.lowerBound])
            for tag in block.output.matches(of: styleTag) {
                if let style = tag.output.1 {
                    let enabled = tag.output.2 != "0"
                    switch style {
                    case "i": italic = enabled
                    case "b": bold = enabled
                    case "u": underline = enabled
                    default: break
                    }
                } else if tag.output.3 != nil {
                    color = tag.output.4.flatMap { assColor(String($0)) }
                } else {
                    italic = false; bold = false; underline = false; color = nil
                }
            }
            cursor = block.range.upperBound
        }
        appendPlain(event[cursor...])
        return result
    }

    /// ASS colours are `&HBBGGRR` (an alpha byte may lead); upstream's `assBgrColor`.
    static func assColor(_ hex: String) -> UIColor? {
        let last = String(hex.suffix(6))
        guard let bgr = Int(String(repeating: "0", count: 6 - last.count) + last, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat(bgr & 0xFF) / 255,
            green: CGFloat((bgr >> 8) & 0xFF) / 255,
            blue: CGFloat((bgr >> 16) & 0xFF) / 255,
            alpha: 1
        )
    }
}
