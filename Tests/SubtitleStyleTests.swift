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
    func testItalicTagsBecomeItalicText() {
        let text = MpvStyledSubtitleText.parse(#"{\i1}Italic line{\i0}\NPlain line"#)
        XCTAssertEqual(String(text.bottom.characters), "Italic line\nPlain line")
        let italic = text.bottom.runs.first { $0.inlinePresentationIntent?.contains(.emphasized) == true }
        XCTAssertEqual(italic.map { String(text.bottom[$0.range].characters) }, "Italic line")
    }

    func testTopAlignedEventsRenderAtTheTop() {
        let text = MpvStyledSubtitleText.parse("Dialogue\n{\\an8}Sign")
        XCTAssertEqual(String(text.top.characters), "Sign")
        XCTAssertEqual(String(text.bottom.characters), "Dialogue")
    }

    func testOtherOverrideTagsAreDroppedWithoutChangingTheStyle() {
        let text = MpvStyledSubtitleText.parse(#"{\bord2\blur3\an2}Plain {\b1}bold{\b0}"#)
        XCTAssertEqual(String(text.bottom.characters), "Plain bold")
        XCTAssertTrue(text.top.characters.isEmpty)
        let bold = text.bottom.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertEqual(bold.map { String(text.bottom[$0.range].characters) }, ["bold"])
    }

    func testPlainTextAndBlankInputAreHandled() {
        XCTAssertEqual(String(MpvStyledSubtitleText.parse(" Hello\nthere ").bottom.characters), "Hello\nthere")
        XCTAssertTrue(MpvStyledSubtitleText.parse("").isEmpty)
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
