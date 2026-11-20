import SwiftUI
import XCTest
@testable import Nuvio

/// Upstream's `SubtitleFontValidationTest` (1.2.0-beta.1), against `SubtitleFonts.isSupported`.
final class SubtitleFontValidationTests: XCTestCase {
    private let trueType: [UInt8] = [0, 1, 0, 0]
    private let openType: [UInt8] = Array("OTTO".utf8)

    private func fontBytes(_ signature: [UInt8], tables: Int = 1, tableLength: Int = 16) -> Data {
        let dataOffset = 12 + tables * 16
        var bytes = signature
        func u16(_ value: Int) { bytes += [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func u32(_ value: Int) { bytes += (0..<4).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) } }
        u16(tables); u16(0); u16(0); u16(0)
        for index in 0..<tables {
            bytes += Array("tb\(index) ".prefix(4).utf8)
            u32(0)
            u32(dataOffset + index * 16)
            u32(tableLength)
        }
        bytes += [UInt8](repeating: 0, count: tables * 16)
        return Data(bytes)
    }

    func testTrueTypeAndOpenTypeWithAValidTableDirectoryAreAccepted() {
        XCTAssertTrue(SubtitleFonts.isSupported(fileName: "Font.ttf", data: fontBytes(trueType)))
        XCTAssertTrue(SubtitleFonts.isSupported(fileName: "Font.OTF", data: fontBytes(openType)))
    }

    func testOtherExtensionsAreRejected() {
        XCTAssertFalse(SubtitleFonts.isSupported(fileName: "Font.woff", data: fontBytes(trueType)))
        XCTAssertFalse(SubtitleFonts.isSupported(fileName: "Font", data: fontBytes(trueType)))
    }

    func testUnknownSignaturesAreRejected() {
        XCTAssertFalse(SubtitleFonts.isSupported(fileName: "Font.ttf", data: fontBytes(Array("wOFF".utf8))))
    }

    func testATruncatedTableDirectoryIsRejected() {
        XCTAssertFalse(SubtitleFonts.isSupported(fileName: "Font.ttf", data: fontBytes(trueType, tables: 4).prefix(40)))
    }

    func testTablesPointingOutsideTheFileAreRejected() {
        XCTAssertFalse(SubtitleFonts.isSupported(fileName: "Font.ttf", data: fontBytes(trueType, tableLength: 4_096)))
    }

    func testFilesOverTheLimitAreRejected() {
        var data = fontBytes(trueType)
        data.append(Data(count: SubtitleFonts.maxBytes + 1 - data.count))
        XCTAssertFalse(SubtitleFonts.isSupported(fileName: "Font.ttf", data: data))
    }

    func testOnlyUUIDShapedIdsAreCustom() {
        XCTAssertTrue(SubtitleFonts.isCustom("custom-123e4567-e89b-12d3-a456-426614174000"))
        XCTAssertFalse(SubtitleFonts.isCustom("serif"))
        XCTAssertFalse(SubtitleFonts.isCustom("custom-../fonts.json"))
    }
}

/// Upstream's `MpvSubtitleTextTest`, against `MpvStyledSubtitleText`.
final class MpvSubtitleTextTests: XCTestCase {
    private func text(
        _ parsed: MpvStyledSubtitleText,
        _ vertical: MpvStyledSubtitleText.Vertical = .bottom,
        _ horizontal: MpvStyledSubtitleText.Horizontal = .center
    ) -> AttributedString {
        parsed.blocks.first { $0.vertical == vertical && $0.horizontal == horizontal }?.text ?? AttributedString()
    }

    func testItalicTagsBecomeItalicText() {
        let bottom = text(MpvStyledSubtitleText.parse(#"{\i1}Italic line{\i0}\NPlain line"#))
        XCTAssertEqual(String(bottom.characters), "Italic line\nPlain line")
        let italic = bottom.runs.first { $0.inlinePresentationIntent?.contains(.emphasized) == true }
        XCTAssertEqual(italic.map { String(bottom[$0.range].characters) }, "Italic line")
    }

    func testTopAlignedEventsRenderAtTheTop() {
        let parsed = MpvStyledSubtitleText.parse("Dialogue\n{\\an8}Sign")
        XCTAssertEqual(String(text(parsed, .top).characters), "Sign")
        XCTAssertEqual(String(text(parsed).characters), "Dialogue")
    }

    func testOtherOverrideTagsAreDroppedWithoutChangingTheStyle() {
        let parsed = MpvStyledSubtitleText.parse(#"{\bord2\blur3\an2}Plain {\b1}bold{\b0}"#)
        let bottom = text(parsed)
        XCTAssertEqual(String(bottom.characters), "Plain bold")
        XCTAssertEqual(parsed.blocks.count, 1)
        let bold = bottom.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertEqual(bold.map { String(bottom[$0.range].characters) }, ["bold"])
    }

    func testPlainTextAndBlankInputAreHandled() {
        XCTAssertEqual(String(text(MpvStyledSubtitleText.parse(" Hello\nthere ")).characters), "Hello\nthere")
        XCTAssertTrue(MpvStyledSubtitleText.parse("").isEmpty)
    }

    /// 2c5398e85: all nine `\an` positions, the last one in an event winning.
    func testEveryAlignmentHasItsOwnPosition() {
        let parsed = MpvStyledSubtitleText.parse("{\\an1}Left sign\n{\\an6}Right middle\n{\\an2\\an9}Top right")
        XCTAssertEqual(String(text(parsed, .bottom, .start).characters), "Left sign")
        XCTAssertEqual(String(text(parsed, .middle, .end).characters), "Right middle")
        XCTAssertEqual(String(text(parsed, .top, .end).characters), "Top right")
    }

    /// `\c&HBBGGRR&` is the file's colour, read back to front; `\r` resets it.
    func testFileColoursAreKeptAndReset() {
        let bottom = text(MpvStyledSubtitleText.parse(#"{\c&H0000FF&}Red{\r} plain {\1c&HFF0000&}blue"#))
        let colours = bottom.runs.map { run -> String in
            guard let color = run.uiKit.foregroundColor else { return "none" }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return "\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255))"
        }
        XCTAssertEqual(colours, ["255,0,0", "none", "0,0,255"])
    }
}

final class SubtitleStyleRulesTests: XCTestCase {
    func testTheOverlayDrawsMpvTextOnlyForAFontABackgroundOrAShadow() {
        XCTAssertFalse(SubtitleStyle().usesStyledRenderer)
        var style = SubtitleStyle()
        style.fontId = SubtitleFonts.serifId
        XCTAssertTrue(style.usesStyledRenderer)
        style = SubtitleStyle()
        style.backgroundColor = Color(argbHex: "#BF000000")
        XCTAssertTrue(style.usesStyledRenderer)
        style = SubtitleStyle()
        style.shadowEnabled = true
        XCTAssertTrue(style.usesStyledRenderer)
    }

    func testABackgroundPresetKeepsItsOpacityOrTakesTheDefault() {
        XCTAssertEqual(SubtitleColors.background("FFD700", current: "#00000000"), "#BFFFD700")
        XCTAssertEqual(SubtitleColors.background("FFD700", current: "#80000000"), "#80FFD700")
        XCTAssertNil(SubtitleColors.selectedBackground("#00000000"))
        XCTAssertEqual(SubtitleColors.selectedBackground("#BF3A3A3A"), "3A3A3A")
    }

    func testTheUploadHeadersAreRead() {
        let raw = "POST /api/font HTTP/1.1\r\nX-File-Name: My%20Font.ttf\r\nContent-Length: 3\r\n\r\nabc"
        let request = HTTPRequest(Data(raw.utf8))
        XCTAssertEqual(request?.path, "/api/font")
        XCTAssertEqual(request?.headers["x-file-name"], "My%20Font.ttf")
        XCTAssertEqual(request?.body, Data("abc".utf8))
    }
}
