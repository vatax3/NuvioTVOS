import Foundation
import SwiftUI

/// mpv's current subtitle text, for the overlay to draw in place of mpv — upstream's
/// `parseMpvSubtitleText` (1.2.0-beta.1).
///
/// `sub-text/ass` carries the event text with its override blocks: `\i`, `\b` and `\u` become
/// italic, bold and underline runs, `\an7`–`\an9` send an event to the top of the picture, and
/// every other tag is dropped. Line breaks (`\N`, `\n`) and hard spaces (`\h`) are resolved.
struct MpvStyledSubtitleText: Equatable {
    var top: AttributedString
    var bottom: AttributedString

    var isEmpty: Bool { top.characters.isEmpty && bottom.characters.isEmpty }

    static func parse(_ text: String) -> MpvStyledSubtitleText {
        let events = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let top = events.filter(isTopAligned)
        let bottom = events.filter { !isTopAligned($0) }
        return MpvStyledSubtitleText(top: join(top), bottom: join(bottom))
    }

    private static let overrideBlock = /\{[^}]*\}/
    private static let topAlignment = /\\an[789](?!\d)/
    private static let styleTag = /\\([ibu])(\d*)(?![a-z])/

    private static func isTopAligned(_ event: String) -> Bool {
        event.matches(of: overrideBlock).contains { $0.output.contains(topAlignment) }
    }

    private static func join(_ events: [String]) -> AttributedString {
        var result = AttributedString()
        for (index, event) in events.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            result.append(annotated(event))
        }
        return result
    }

    private static func annotated(_ event: String) -> AttributedString {
        var result = AttributedString()
        var italic = false, bold = false, underline = false
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
            result.append(run)
        }

        for block in event.matches(of: overrideBlock) {
            appendPlain(event[cursor..<block.range.lowerBound])
            for tag in block.output.matches(of: styleTag) {
                let enabled = tag.output.2 != "0"
                switch tag.output.1 {
                case "i": italic = enabled
                case "b": bold = enabled
                case "u": underline = enabled
                default: break
                }
            }
            cursor = block.range.upperBound
        }
        appendPlain(event[cursor...])
        return result
    }
}
