import SwiftUI
import XCTest
@testable import Nuvio

/// The separate subtitle style for HDR and Dolby Vision pictures, ported with upstream's
/// `SubtitleStyleHdrOverrideTest`.
///
/// It matters more here than there: since 1.0.52 Dolby Vision is delivered natively rather than
/// tone-mapped, so subtitle white is the panel's PQ peak rather than SDR white — bright enough to
/// read as glare on exactly the televisions people buy for HDR.
final class SubtitleHDRStyleTests: XCTestCase {
    private var style: SubtitleStyle {
        var style = SubtitleStyle()
        style.textColor = .white
        style.backgroundColor = Color(argbHex: "#80646464")
        style.outlineColor = .white
        style.hdrStyleEnabled = true
        style.hdrTextColor = Color(argbHex: "#FFFFFF00")
        style.hdrBrightness = 100
        return style
    }

    private func components(_ color: Color) -> (Double, Double, Double, Double) {
        let rgb = color.rgbComponents ?? (0, 0, 0)
        return (rgb.red, rgb.green, rgb.blue, color.alphaComponent)
    }

    private func assertComponents(
        _ color: Color,
        _ expected: (Double, Double, Double, Double),
        accuracy: Double = 0.01,
        line: UInt = #line
    ) {
        let actual = components(color)
        XCTAssertEqual(actual.0, expected.0, accuracy: accuracy, "red", line: line)
        XCTAssertEqual(actual.1, expected.1, accuracy: accuracy, "green", line: line)
        XCTAssertEqual(actual.2, expected.2, accuracy: accuracy, "blue", line: line)
        XCTAssertEqual(actual.3, expected.3, accuracy: accuracy, "alpha", line: line)
    }

    func testSDRKeepsTheBaseStyle() {
        XCTAssertEqual(style.forVideo(isHDR: false), style)
    }

    func testHDRKeepsTheBaseStyleWhenTheOverrideIsOff() {
        var off = style
        off.hdrStyleEnabled = false
        XCTAssertEqual(off.forVideo(isHDR: true), off)
    }

    /// At full brightness the HDR colour is swapped in undimmed.
    func testFullBrightnessSwapsInTheHDRColour() {
        let effective = style.forVideo(isHDR: true)
        assertComponents(effective.textColor, (1, 1, 0, 1))
    }

    /// Zero is 30% of full, not nothing — the setting dims text, it does not remove it.
    func testZeroBrightnessDimsToThirtyPercentAndKeepsAlpha() {
        var dim = style
        dim.hdrBrightness = 0
        let effective = dim.forVideo(isHDR: true)
        assertComponents(effective.textColor, (0.3, 0.3, 0, 1))
        // 0x64 is 0.392; dimmed to 30% it is 0.118, and the 0x80 alpha is untouched.
        assertComponents(effective.backgroundColor, (0.118, 0.118, 0.118, 0.502))
    }

    func testTheDefaultBrightnessDimsToFiftyEightPercent() {
        var dim = style
        dim.hdrBrightness = SubtitleStyle.hdrBrightnessDefault
        assertComponents(dim.forVideo(isHDR: true).textColor, (0.58, 0.58, 0, 1))
    }

    /// Out-of-range values are clamped rather than trusted: the stepper is bounded, an imported
    /// preference from the shared account is not.
    func testBrightnessOutsideTheRangeIsClamped() {
        XCTAssertEqual(SubtitleStyle.hdrBrightnessFactor(-50), 0.3, accuracy: 0.001)
        XCTAssertEqual(SubtitleStyle.hdrBrightnessFactor(400), 1.0, accuracy: 0.001)
    }

    /// Dimming scales the colour rather than the opacity: an alpha-dimmed subtitle takes on
    /// whatever is behind it, which on a bright scene is the opposite of readable.
    func testDimmingNeverTouchesAlpha() {
        var dim = style
        dim.hdrBrightness = 0
        XCTAssertEqual(dim.forVideo(isHDR: true).backgroundColor.alphaComponent, 0.502, accuracy: 0.01)
    }
}
