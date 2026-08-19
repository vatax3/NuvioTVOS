#if canImport(Libmpv)
import CoreText
import Foundation

/// Resolves subtitle faces that libass/FreeType can actually open on tvOS.
///
/// CoreText can silently substitute a missing system family, while libass then receives a face
/// with no glyphs for the requested script.  This was the reason CJK subtitles were rendered as
/// squares in the tvOS port.  The iOS reference app solves it by bundling Noto Sans CJK and
/// probing every candidate; this is the same policy, adapted for the standalone tvOS target.
final class MPVSubtitleFontResolver {
    enum Script: Hashable {
        case han, japanese, korean, thai, arabic, hebrew, devanagari

        var systemFamilies: [String] {
            switch self {
            case .han: return ["PingFang SC", "PingFang TC", "Hiragino Sans"]
            case .japanese: return ["Hiragino Sans", "Hiragino Maru Gothic ProN"]
            case .korean: return ["Apple SD Gothic Neo", "AppleGothic"]
            case .thai: return ["Thonburi", "Sukhumvit Set"]
            case .arabic: return ["Geeza Pro", "Al Nile", "Damascus"]
            case .hebrew: return ["Arial Hebrew"]
            case .devanagari: return ["Kohinoor Devanagari", "Devanagari Sangam MN"]
            }
        }

        var probeScalars: [UnicodeScalar] {
            switch self {
            case .han: return ["\u{4E2D}", "\u{4EEC}", "\u{8FD9}"]
            case .japanese: return ["\u{3042}", "\u{6F22}"]
            case .korean: return ["\u{AC00}"]
            case .thai: return ["\u{0E01}"]
            case .arabic: return ["\u{0627}"]
            case .hebrew: return ["\u{05D0}"]
            case .devanagari: return ["\u{0915}"]
            }
        }
    }

    private static let lock = NSLock()
    private static var registeredFamilies: [String] = []
    private static var didRegister = false
    private static var familyCache: [Script: String?] = [:]

    private var activeFamily: String?
    private var scriptFromLanguage: Script?
    private var scriptFromText: Script?

    /// Registers Noto from the app bundle and returns a baseline covering CJK and Latin.  The
    /// font file is intentionally bundled: protected system CJK faces are not readable by
    /// FreeType inside a sandboxed tvOS app.
    func prepare() -> String? {
        Self.registerBundledFontsIfNeeded()
        let family = Self.family(for: .han)
        activeFamily = family
        return family
    }

    func familyForLanguage(_ language: String?) -> String? {
        let script = Self.script(forLanguageTag: language)
        guard script != scriptFromLanguage else { return nil }
        scriptFromLanguage = script
        scriptFromText = nil
        return resolve(script)
    }

    func familyForText(_ text: String?) -> String? {
        guard let text, !text.isEmpty, let script = Self.script(forText: text), script != scriptFromText else {
            return nil
        }
        scriptFromText = script
        return resolve(script)
    }

    private func resolve(_ script: Script?) -> String? {
        let family = script.flatMap(Self.family(for:)) ?? Self.family(for: .han)
        guard family != activeFamily else { return nil }
        activeFamily = family
        return family
    }

    private static func registerBundledFontsIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRegister else { return }
        didRegister = true

        let urls = [
            Bundle.main.url(forResource: "NotoSansCJKsc-Regular", withExtension: "otf", subdirectory: "SubtitleFonts"),
            Bundle.main.url(forResource: "NotoSansCJKsc-Regular", withExtension: "otf")
        ].compactMap { $0 }

        var families = Set<String>()
        for url in urls {
            var error: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            for descriptor in descriptors {
                if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String {
                    families.insert(family)
                }
            }
        }
        registeredFamilies = families.sorted()
    }

    private static func family(for script: Script) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = familyCache[script] { return cached }

        // One Noto CJK face deliberately stays active across Chinese, Japanese and Korean
        // dialogue. Switching system families per cue causes a font-cache rebuild in libass,
        // which is visible as audio underruns on the simulator and slower Apple TV hardware.
        let bundledFirst = script == .han || script == .japanese || script == .korean
        let candidates = bundledFirst
            ? registeredFamilies + script.systemFamilies
            : script.systemFamilies + registeredFamilies
        let resolved = candidates.first { isUsable($0, for: script) }
        familyCache[script] = resolved
        return resolved
    }

    private static func script(forLanguageTag tag: String?) -> Script? {
        guard let tag, !tag.isEmpty else { return nil }
        let code = tag.lowercased().replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init) ?? tag.lowercased()
        switch code {
        case "zh", "zho", "chi", "cmn", "yue", "nan", "hak": return .han
        case "ja", "jpn", "jp": return .japanese
        case "ko", "kor": return .korean
        case "th", "tha": return .thai
        case "ar", "ara", "fa", "fas", "per", "ur", "urd", "ps", "pus", "ku": return .arabic
        case "he", "heb", "iw", "yi", "yid": return .hebrew
        case "hi", "hin", "mr", "mar", "ne", "nep", "sa", "san": return .devanagari
        default: return nil
        }
    }

    private static func script(forText text: String) -> Script? {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            guard let script = script(for: scalar) else { continue }
            counts[script, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func script(for scalar: UnicodeScalar) -> Script? {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF: return .japanese
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return .han
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return .korean
        case 0x0E00...0x0E7F: return .thai
        case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x0590...0x05FF: return .hebrew
        case 0x0900...0x097F: return .devanagari
        default: return nil
        }
    }

    private static func isUsable(_ family: String, for script: Script) -> Bool {
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        guard (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(family) == .orderedSame,
              script.probeScalars.allSatisfy({ hasGlyph(font, $0) })
        else { return false }

        let descriptor = CTFontCopyFontDescriptor(font)
        guard let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL else { return false }
        // Faces in private framework bundles look valid to CoreText but cannot be opened by
        // libass's FreeType backend. The bundled Noto face remains the safe fallback.
        return FileManager.default.isReadableFile(atPath: url.path)
            && !url.path.hasPrefix("/System/Library/PrivateFrameworks/")
    }

    private static func hasGlyph(_ font: CTFont, _ scalar: UnicodeScalar) -> Bool {
        var characters = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else { return false }
        return glyphs.allSatisfy { $0 != 0 }
    }
}
#endif
