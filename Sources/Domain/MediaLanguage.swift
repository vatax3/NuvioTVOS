import Foundation

/// The language catalogue the Android app offers, verbatim — `AVAILABLE_SUBTITLE_LANGUAGES`.
///
/// It exists as a list rather than a free-text field for a plain reason: a two-letter code is
/// something a viewer has to know, and getting it wrong fails silently, leaving them to wonder
/// why their subtitles never come up. It is also the same list on both platforms, which matters
/// because these preferences sync between them.
struct MediaLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String

    var id: String { code }

    /// The name in the viewer's own language when the system knows it, falling back to the
    /// English name Android ships.
    var displayName: String {
        Locale.current.localizedString(forIdentifier: code)?.capitalized
            ?? Locale.current.localizedString(forLanguageCode: code)?.capitalized
            ?? name
    }

    static let all: [MediaLanguage] = [
        MediaLanguage(code: "af", name: "Afrikaans"),
        MediaLanguage(code: "sq", name: "Albanian"),
        MediaLanguage(code: "am", name: "Amharic"),
        MediaLanguage(code: "ar", name: "Arabic"),
        MediaLanguage(code: "hy", name: "Armenian"),
        MediaLanguage(code: "az", name: "Azerbaijani"),
        MediaLanguage(code: "eu", name: "Basque"),
        MediaLanguage(code: "be", name: "Belarusian"),
        MediaLanguage(code: "bn", name: "Bengali"),
        MediaLanguage(code: "bs", name: "Bosnian"),
        MediaLanguage(code: "bg", name: "Bulgarian"),
        MediaLanguage(code: "my", name: "Burmese"),
        MediaLanguage(code: "ca", name: "Catalan"),
        MediaLanguage(code: "zh", name: "Chinese"),
        MediaLanguage(code: "zh-CN", name: "Chinese (Simplified)"),
        MediaLanguage(code: "zh-TW", name: "Chinese (Traditional)"),
        MediaLanguage(code: "hr", name: "Croatian"),
        MediaLanguage(code: "cs", name: "Czech"),
        MediaLanguage(code: "da", name: "Danish"),
        MediaLanguage(code: "nl", name: "Dutch"),
        MediaLanguage(code: "en", name: "English"),
        MediaLanguage(code: "et", name: "Estonian"),
        MediaLanguage(code: "tl", name: "Filipino"),
        MediaLanguage(code: "fi", name: "Finnish"),
        MediaLanguage(code: "fr", name: "French"),
        MediaLanguage(code: "gl", name: "Galician"),
        MediaLanguage(code: "ka", name: "Georgian"),
        MediaLanguage(code: "de", name: "German"),
        MediaLanguage(code: "el", name: "Greek"),
        MediaLanguage(code: "gu", name: "Gujarati"),
        MediaLanguage(code: "he", name: "Hebrew"),
        MediaLanguage(code: "hi", name: "Hindi"),
        MediaLanguage(code: "hu", name: "Hungarian"),
        MediaLanguage(code: "is", name: "Icelandic"),
        MediaLanguage(code: "id", name: "Indonesian"),
        MediaLanguage(code: "ga", name: "Irish"),
        MediaLanguage(code: "it", name: "Italian"),
        MediaLanguage(code: "ja", name: "Japanese"),
        MediaLanguage(code: "kn", name: "Kannada"),
        MediaLanguage(code: "kk", name: "Kazakh"),
        MediaLanguage(code: "km", name: "Khmer"),
        MediaLanguage(code: "ko", name: "Korean"),
        MediaLanguage(code: "lo", name: "Lao"),
        MediaLanguage(code: "lv", name: "Latvian"),
        MediaLanguage(code: "lt", name: "Lithuanian"),
        MediaLanguage(code: "mk", name: "Macedonian"),
        MediaLanguage(code: "ms", name: "Malay"),
        MediaLanguage(code: "ml", name: "Malayalam"),
        MediaLanguage(code: "mt", name: "Maltese"),
        MediaLanguage(code: "mr", name: "Marathi"),
        MediaLanguage(code: "mn", name: "Mongolian"),
        MediaLanguage(code: "ne", name: "Nepali"),
        MediaLanguage(code: "no", name: "Norwegian"),
        MediaLanguage(code: "pa", name: "Punjabi"),
        MediaLanguage(code: "fa", name: "Persian"),
        MediaLanguage(code: "pl", name: "Polish"),
        MediaLanguage(code: "pt", name: "Portuguese (Portugal)"),
        MediaLanguage(code: "pt-br", name: "Portuguese (Brazil)"),
        MediaLanguage(code: "ro", name: "Romanian"),
        MediaLanguage(code: "ru", name: "Russian"),
        MediaLanguage(code: "sr", name: "Serbian"),
        MediaLanguage(code: "si", name: "Sinhala"),
        MediaLanguage(code: "sk", name: "Slovak"),
        MediaLanguage(code: "sl", name: "Slovenian"),
        MediaLanguage(code: "es", name: "Spanish"),
        MediaLanguage(code: "es-419", name: "Spanish (Latin America)"),
        MediaLanguage(code: "sw", name: "Swahili"),
        MediaLanguage(code: "sv", name: "Swedish"),
        MediaLanguage(code: "ta", name: "Tamil"),
        MediaLanguage(code: "te", name: "Telugu"),
        MediaLanguage(code: "th", name: "Thai"),
        MediaLanguage(code: "tr", name: "Turkish"),
        MediaLanguage(code: "uk", name: "Ukrainian"),
        MediaLanguage(code: "ur", name: "Urdu"),
        MediaLanguage(code: "uz", name: "Uzbek"),
        MediaLanguage(code: "vi", name: "Vietnamese"),
        MediaLanguage(code: "cy", name: "Welsh"),
        MediaLanguage(code: "zu", name: "Zulu")
    ]

    /// Resolves a stored code to a catalogue entry, tolerating the three-letter forms addons
    /// and media files use (`fre`, `ger`, `dut`) and region suffixes we do not list.
    static func named(_ code: String?) -> String? {
        guard let raw = code?.trimmingCharacters(in: .whitespaces).nilIfBlank else { return nil }
        let normalised = normalise(raw)
        if let match = all.first(where: { $0.code.lowercased() == normalised }) {
            return match.displayName
        }
        return Locale.current.localizedString(forLanguageCode: normalised)?.capitalized
            ?? Locale.current.localizedString(forIdentifier: raw)?.capitalized
            ?? raw.uppercased()
    }

    /// Maps a code onto the catalogue's own spelling so comparisons work across the ISO-639-1
    /// and 639-2 forms that turn up in track metadata.
    static func normalise(_ code: String) -> String {
        let lower = code.lowercased().replacingOccurrences(of: "_", with: "-")
        if let exact = all.first(where: { $0.code.lowercased() == lower }) { return exact.code.lowercased() }
        let base = String(lower.split(separator: "-").first ?? "")
        if let alias = threeLetterAliases[base] { return alias }
        if let exact = all.first(where: { $0.code.lowercased() == base }) { return exact.code.lowercased() }
        return base.isEmpty ? lower : base
    }

    /// The bibliographic 639-2 codes that differ from the terminological ones. Files label
    /// French tracks `fre` about as often as `fra`, and a viewer's preference has to match both.
    private static let threeLetterAliases: [String: String] = [
        "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "dut": "nl", "nld": "nl",
        "gre": "el", "ell": "el", "chi": "zh", "zho": "zh", "cze": "cs", "ces": "cs",
        "ice": "is", "isl": "is", "per": "fa", "fas": "fa", "rum": "ro", "ron": "ro",
        "slo": "sk", "slk": "sk", "alb": "sq", "sqi": "sq", "arm": "hy", "hye": "hy",
        "baq": "eu", "eus": "eu", "bur": "my", "mya": "my", "geo": "ka", "kat": "ka",
        "mac": "mk", "mkd": "mk", "may": "ms", "msa": "ms", "wel": "cy", "cym": "cy",
        "eng": "en", "spa": "es", "por": "pt", "ita": "it", "jpn": "ja", "kor": "ko",
        "rus": "ru", "pol": "pl", "swe": "sv", "dan": "da", "nor": "no", "fin": "fi",
        "hun": "hu", "tur": "tr", "ara": "ar", "heb": "he", "hin": "hi", "tha": "th",
        "vie": "vi", "ukr": "uk", "bul": "bg", "hrv": "hr", "srp": "sr", "slv": "sl",
        "est": "et", "lav": "lv", "lit": "lt", "ind": "id", "cat": "ca"
    ]
}
