import Foundation

/// Repairs subtitle text that was already broken before it reached us.
///
/// Charset detection cannot catch this one, and ours is the reason why. A UTF-8 file that some
/// earlier tool read as Windows-1252 and wrote back out as UTF-8 is *itself valid UTF-8* — so
/// the detector accepts it, correctly, and renders `Itâ€™s` where the author wrote `It's`. mpv's
/// `sub-codepage=auto` has the same blind spot for the same reason: there is nothing wrong with
/// the encoding, only with the text inside it.
///
/// Upstream fixed this in 0.8.8 with a lookup table of the sequences they had seen. A table only
/// covers what somebody reported, so this undoes the transformation instead: re-encode the string
/// to recover the bytes that tool wrote, then read them as UTF-8 again. Every double-encoding is
/// reversed by construction, including the ones nobody has reported — the Cyrillic, Greek and
/// Japanese cases below were never on anybody's list and come out right anyway.
enum SubtitleMojibake {
    /// The characters a UTF-8 lead byte turns into when read as a single-byte codepage.
    ///
    /// Expressed as the byte range rather than a hand-written list, because a list is how the
    /// first version of this missed `ã` — `0xE3`, which leads every Japanese kana — and declined
    /// to repair an entire writing system. UTF-8 lead bytes run `0xC2`–`0xF4`; nothing outside
    /// that range can begin a damaged sequence.
    private static let leadRange: ClosedRange<UInt32> = 0xC2...0xF4

    private static func isLead(_ scalar: Unicode.Scalar) -> Bool {
        leadRange.contains(scalar.value)
    }

    /// Strips the replacement characters a lossy decode left behind and undoes any double
    /// encoding. Ordered: repairing first would only produce more replacement characters.
    static func sanitize(_ text: String) -> String {
        repaired(stripReplacements(text))
    }

    /// U+FFFD is what a decoder writes where it gave up. Nothing downstream can recover the
    /// character, and a lone black diamond on screen is worse than the gap it stands in for.
    static func stripReplacements(_ text: String) -> String {
        guard text.contains("\u{FFFD}") else { return text }
        // The space it leaves would otherwise double up with the one already beside it.
        return text
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// Reverses one round of UTF-8 read as a single-byte codepage, when that is what happened.
    ///
    /// Three guards keep it away from healthy text. The lead scan skips anything with no
    /// mojibake shape at all. The re-encode declines anything the codepage never held —
    /// Cyrillic, Greek, CJK that arrived intact — so correct text cannot round trip. And the
    /// UTF-8 decode is self-validating, which is the guard that does most of the work: real
    /// accented prose such as `château` re-encodes to bytes that are not valid UTF-8, so it
    /// fails there and the original stands.
    static func repaired(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isLead) else { return text }
        guard let bytes = windows1252Bytes(text),
              let decoded = String(data: bytes, encoding: .utf8),
              decoded != text
        else { return text }
        // A last check on the result rather than the input: a repair that did not reduce the
        // mojibake shapes did not repair anything, and should not be trusted to have improved
        // the text it rewrote.
        return score(decoded) < score(text) ? decoded : text
    }

    /// Windows-1252 back to bytes, including the five positions the codepage leaves undefined.
    ///
    /// Foundation's own encoder refuses `0x81`, `0x8D`, `0x8F`, `0x90` and `0x9D`, correctly —
    /// the standard assigns them nothing. But the tools that produce this damage do not refuse
    /// them: they hand back the matching C1 control, the way every browser does, and those five
    /// bytes are common inside multi-byte UTF-8 sequences. Japanese `こ` is `E3 81 93`, so a
    /// strict encoder fails on the second byte of the very first character and the whole track
    /// is declined. Rejecting exactly the text that most needs repairing is not conservative,
    /// it is useless, so the mapping is written out.
    private static func windows1252Bytes(_ text: String) -> Data? {
        var bytes = Data()
        bytes.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            // Latin-1 positions, and the C1 range the lenient variant passes through unchanged.
            if scalar.value <= 0xFF {
                bytes.append(UInt8(scalar.value))
            } else if let byte = highRange[scalar] {
                bytes.append(byte)
            } else {
                // Something the codepage never held — Cyrillic, CJK, anything already correct.
                return nil
            }
        }
        return bytes
    }

    /// The twenty-seven characters Windows-1252 puts in `0x80`–`0x9F`, where Latin-1 has
    /// controls. They are why `’` becomes `â€™` rather than something Latin-1 could explain.
    private static let highRange: [Unicode.Scalar: UInt8] = [
        "\u{20AC}": 0x80, "\u{201A}": 0x82, "\u{0192}": 0x83, "\u{201E}": 0x84,
        "\u{2026}": 0x85, "\u{2020}": 0x86, "\u{2021}": 0x87, "\u{02C6}": 0x88,
        "\u{2030}": 0x89, "\u{0160}": 0x8A, "\u{2039}": 0x8B, "\u{0152}": 0x8C,
        "\u{017D}": 0x8E, "\u{2018}": 0x91, "\u{2019}": 0x92, "\u{201C}": 0x93,
        "\u{201D}": 0x94, "\u{2022}": 0x95, "\u{2013}": 0x96, "\u{2014}": 0x97,
        "\u{02DC}": 0x98, "\u{2122}": 0x99, "\u{0161}": 0x9A, "\u{203A}": 0x9B,
        "\u{0153}": 0x9C, "\u{017E}": 0x9E, "\u{0178}": 0x9F
    ]

    /// How many lead-shaped characters remain. A repair that did not reduce this did not
    /// repair anything.
    private static func score(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { total, scalar in
            if isLead(scalar) { total += 1 }
        }
    }
}
