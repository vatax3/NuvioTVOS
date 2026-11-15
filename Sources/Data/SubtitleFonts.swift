import CoreText
import Foundation
import Observation
import SwiftUI

/// A font the subtitles can be drawn in — upstream's `SubtitleFont` (1.2.0-beta.1).
struct SubtitleFont: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

/// Upstream's `SubtitleFonts`: three built-in faces and the ones imported from a phone.
enum SubtitleFonts {
    static let defaultId = "default"
    static let serifId = "serif"
    static let monoId = "mono"
    static let builtIn = [defaultId, serifId, monoId]
    static let maxBytes = 10 * 1024 * 1024

    static func isCustom(_ id: String) -> Bool {
        id.wholeMatch(of: /custom-[a-f0-9-]{36}/) != nil
    }

    /// `isSupportedSubtitleFont`, as upstream checks it: a `.ttf` or `.otf` name, a size the
    /// store accepts, a TrueType or CFF signature, and a table directory that stays in the file.
    static func isSupported(fileName: String, data: Data) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard ext == "ttf" || ext == "otf" else { return false }
        guard (12...maxBytes).contains(data.count) else { return false }
        let bytes = [UInt8](data)
        let trueType = bytes[0] == 0 && bytes[1] == 1 && bytes[2] == 0 && bytes[3] == 0
        let cff = bytes[0..<4].elementsEqual("OTTO".utf8)
        guard trueType || cff else { return false }
        func uint16(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        func uint32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 << 8 | Int(bytes[offset + $1]) }
        }
        let tables = uint16(4)
        guard tables > 0, 12 + tables * 16 <= bytes.count else { return false }
        return (0..<tables).allSatisfy { index in
            let offset = 12 + index * 16
            let start = uint32(offset + 8)
            let length = uint32(offset + 12)
            return start <= bytes.count && length <= bytes.count - start
        }
    }

    /// The SwiftUI font for an id at a size. A custom font that is not registered (removed, or
    /// its file lost) falls back to the default face, as upstream's typeface lookup does.
    @MainActor
    static func font(for id: String, size: CGFloat, weight: Font.Weight) -> Font {
        switch id {
        case serifId: return .system(size: size, weight: weight, design: .serif)
        case monoId: return .system(size: size, weight: weight, design: .monospaced)
        default:
            if let family = SubtitleFontStore.shared.family(for: id) {
                return .custom(family, fixedSize: size).weight(weight)
            }
            return .system(size: size, weight: weight)
        }
    }
}

/// Upstream's `SubtitleFontStore`: imported fonts in Application Support, an index beside them,
/// and each one registered with CoreText for this process so SwiftUI and mpv can name it.
@MainActor
@Observable
final class SubtitleFontStore {
    static let shared = SubtitleFontStore()

    private(set) var fonts: [SubtitleFont] = []
    @ObservationIgnored private var families: [String: String] = [:]

    private let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("subtitle-fonts", isDirectory: true)
        self.directory = base
        fonts = readIndex().filter { register($0.id) != nil }
    }

    func family(for id: String) -> String? {
        guard SubtitleFonts.isCustom(id) else { return nil }
        return families[id] ?? register(id)
    }

    /// Imports a font; returns the existing entry when the same bytes were imported before.
    @discardableResult
    func importFont(fileName: String, data: Data) throws -> SubtitleFont {
        guard SubtitleFonts.isSupported(fileName: fileName, data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let existing = fonts.first(where: { (try? Data(contentsOf: file($0.id))) == data }) {
            return existing
        }
        let base = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        let name = String((base.isEmpty ? fileName : base).prefix(80))
        let font = SubtitleFont(id: "custom-\(UUID().uuidString.lowercased())", name: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(font.id), options: .atomic)
        guard register(font.id) != nil else {
            try? FileManager.default.removeItem(at: file(font.id))
            throw CocoaError(.fileReadCorruptFile)
        }
        fonts.append(font)
        try writeIndex()
        return font
    }

    func remove(_ id: String) {
        if families.removeValue(forKey: id) != nil {
            CTFontManagerUnregisterFontsForURL(file(id) as CFURL, .process, nil)
        }
        try? FileManager.default.removeItem(at: file(id))
        fonts.removeAll { $0.id == id }
        try? writeIndex()
    }

    // MARK: Files

    private func file(_ id: String) -> URL { directory.appendingPathComponent(id) }
    private var indexFile: URL { directory.appendingPathComponent("fonts.json") }

    private func readIndex() -> [SubtitleFont] {
        guard let data = try? Data(contentsOf: indexFile),
              let list = try? JSONDecoder().decode([SubtitleFont].self, from: data)
        else { return [] }
        return list.filter { SubtitleFonts.isCustom($0.id) && FileManager.default.fileExists(atPath: file($0.id).path) }
    }

    private func writeIndex() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(fonts).write(to: indexFile, options: .atomic)
    }

    /// Registers the file for this process and remembers its family name.
    @discardableResult
    private func register(_ id: String) -> String? {
        let url = file(id)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let family = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
        else { return nil }
        // Already registered is fine: the family is what is needed.
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        families[id] = family
        return family
    }
}

/// Upstream's `SubtitleFontOptions`: the order fonts are offered in, and their names.
enum SubtitleFontOptions {
    static func ids(imported: [SubtitleFont]) -> [String] {
        SubtitleFonts.builtIn + imported.map(\.id)
    }

    static func label(for id: String, imported: [SubtitleFont]) -> String {
        switch id {
        case SubtitleFonts.serifId: return L10n.text("player.sub_font_serif", fallback: "Serif")
        case SubtitleFonts.monoId: return L10n.text("player.sub_font_mono", fallback: "Monospace")
        default:
            return imported.first { $0.id == id }?.name
                ?? L10n.text("player.sub_font_default", fallback: "Default")
        }
    }

    /// The chosen font was imported on another device, or removed here: the default draws.
    @MainActor
    static func isMissing(_ id: String) -> Bool {
        SubtitleFonts.isCustom(id) && SubtitleFontStore.shared.family(for: id) == nil
    }
}
