import Foundation

/// Removes what an SDH track adds for viewers who cannot hear: bracketed sound effects,
/// upper-case parenthesised actions, and speaker labels.
///
/// This runs on whatever track the viewer picked rather than trying to find a non-SDH twin of
/// it — addons frequently publish only the SDH variant of a language, so "pick the other one"
/// is not an option that exists. MPV filters its own embedded tracks natively; this covers the
/// sidecar SRT and VTT files Nuvio draws itself, which is every addon subtitle.
enum SubtitleSDHFilter {
    static func strip(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.compactMap { cue in
            guard let text = strip(cue.text) else { return nil }
            return SubtitleCue(start: cue.start, end: cue.end, text: text)
        }
    }

    /// `nil` when nothing readable survives — the cue was a sound effect and nothing else, and
    /// leaving an empty box on screen is worse than leaving no box.
    static func strip(_ text: String) -> String? {
        let kept = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(strip(line:))
            .filter { !$0.isEmpty }
        let joined = kept.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func strip(line: Substring) -> String {
        var text = removeAnnotations(in: String(line))
        text = removeSpeakerLabel(from: text)
        text = text.trimmingCharacters(in: .whitespaces)
        // A line that was "- [DOOR CREAKS]" is now "-". Punctuation on its own is not dialogue.
        return text.contains(where: { $0.isLetter || $0.isNumber }) ? text : ""
    }

    /// Square brackets always mark an annotation. Parentheses do not — dialogue uses them — so
    /// those are only dropped when their contents are shouted, which is the SDH convention:
    /// `(SIGHS)` goes, `(the one from before)` stays.
    private static func removeAnnotations(in text: String) -> String {
        var result = ""
        var buffer = ""
        var depth = 0
        var opener: Character?

        for character in text {
            if character == "[" || character == "(" {
                if depth == 0 { opener = character; buffer = "" }
                depth += 1
                continue
            }
            if depth > 0, character == "]" || character == ")" {
                depth -= 1
                guard depth == 0 else { continue }
                // Parenthesised dialogue is put back, brackets and shouted asides are not.
                if opener == "(", !isShouted(buffer) { result += "(\(buffer))" }
                buffer = ""
                continue
            }
            if depth > 0 { buffer.append(character) } else { result.append(character) }
        }
        // An annotation that is never closed runs to the end of the line; dropping the rest is
        // the better guess, since an unterminated bracket is an authoring slip, not dialogue.
        return result.replacingOccurrences(of: "  ", with: " ")
    }

    /// Letters present, and none of them lower case.
    private static func isShouted(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        return !letters.isEmpty && !letters.contains(where: \.isLowercase)
    }

    /// `MAN:`, `NARRATOR:`, `WOMAN #2:` — an upper-case name at the head of a line. The
    /// upper-case test is what keeps it off ordinary dialogue: "But then: nothing" survives,
    /// and so does a timestamp, because neither is shouted.
    private static func removeSpeakerLabel(from text: String) -> String {
        let leading = text.prefix(while: { $0 != ":" })
        guard leading.count < text.count, leading.count <= 24 else { return text }

        let candidate = String(leading.drop(while: { $0 == "-" || $0 == " " }))
        guard isShouted(candidate),
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || " .'#-_".contains($0) })
        else { return text }

        let remainder = text.dropFirst(leading.count + 1).trimmingCharacters(in: .whitespaces)
        // The dialogue dash belongs to the line, not to the label that has just been removed.
        return leading.hasPrefix("-") ? "- \(remainder)" : remainder
    }
}
