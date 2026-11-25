import XCTest
@testable import Nuvio

/// Upstream's separate ASS/SSA style (1.2.0-beta.4, 233dd1f3b and 8ce69c2a1).
@MainActor
final class AssSubtitleStyleTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let suite = "AssSubtitleStyleTests.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    // MARK: applyAssSubtitleOverride

    func testATextTrackIsNeverOverridden() {
        XCTAssertEqual(AssSubtitleStyle(customize: true).mpvOverride(isAss: false), "no")
    }

    func testAStockStyledTrackKeepsItsScript() {
        XCTAssertEqual(AssSubtitleStyle().mpvOverride(isAss: true), "no")
        XCTAssertNil(AssSubtitleStyle().mpvBoldOverride(isAss: true))
    }

    func testOnlyTheSizeIsAppliedWhenItDiffersFromItsDefault() {
        XCTAssertEqual(AssSubtitleStyle(sizeScale: 1.5).mpvOverride(isAss: true), "scale")
    }

    func testCustomisingForcesTheWholeStyleAndItsWeight() {
        let style = AssSubtitleStyle(customize: true, sizeScale: 1.5, bold: true)
        XCTAssertEqual(style.mpvOverride(isAss: true), "force")
        XCTAssertEqual(style.mpvBoldOverride(isAss: true), true)
    }

    /// `subtitleStyle.copy(…)`: the ASS fields over the text style, which keeps the SDH filter
    /// and HDR colours.
    func testTheASSStyleReplacesTheAppearanceAndKeepsTheRest() {
        var style = SubtitleStyle(sizeScale: 1.25, bold: false, stripsSDH: true, hdrStyleEnabled: true)
        style.ass = AssSubtitleStyle(sizeScale: 1.0, bold: true, fontId: "serif")
        let applied = style.applyingASS()
        XCTAssertEqual(applied.sizeScale, 1.0)
        XCTAssertTrue(applied.bold)
        XCTAssertEqual(applied.fontId, "serif")
        XCTAssertTrue(applied.stripsSDH)
        XCTAssertTrue(applied.hdrStyleEnabled)
    }

    // MARK: Settings

    func testDefaultsAndRanges() throws {
        let store = PlayerSettingsStore(defaults: try defaults())
        XCTAssertFalse(store.subtitleCustomizeAss)
        XCTAssertEqual(store.assSubtitleSize, 1.0)
        XCTAssertEqual(store.assSubtitleOutlineWidth, 2)
        XCTAssertEqual(store.assSubtitleShadowOpacity, 75)
        store.assSubtitleSize = 5
        XCTAssertEqual(store.assSubtitleSize, 2.0)
        store.assSubtitleOutlineWidth = 9
        XCTAssertEqual(store.assSubtitleOutlineWidth, 5)
    }

    func testResettingTheASSStyleLeavesTheTextStyle() throws {
        let store = PlayerSettingsStore(defaults: try defaults())
        store.subtitleBold = true
        store.subtitleCustomizeAss = true
        store.assSubtitleBold = true
        store.resetAssSubtitleAppearance()
        XCTAssertFalse(store.subtitleCustomizeAss)
        XCTAssertFalse(store.assSubtitleBold)
        XCTAssertTrue(store.subtitleBold)
    }

    func testTheEditorWritesTheStyleInEffect() throws {
        let store = PlayerSettingsStore(defaults: try defaults())
        SubtitleStyleEditor(player: store, ass: true).size = 1.5
        XCTAssertEqual(store.assSubtitleSize, 1.5)
        XCTAssertEqual(store.subtitleSize, 1.0)
        XCTAssertFalse(SubtitleStyleEditor(player: store, ass: true).editsFullStyle)
        store.subtitleCustomizeAss = true
        XCTAssertTrue(SubtitleStyleEditor(player: store, ass: true).editsFullStyle)
    }

    // MARK: Migration from `subtitle_style_override`

    func testAnUnsetOverrideLeavesStyledTracksAsAuthored() throws {
        let defaults = try defaults()
        defaults.set(1.5, forKey: "player.subtitle_size")
        let store = PlayerSettingsStore(defaults: defaults)
        XCTAssertEqual(store.assSubtitleSize, 1.0)
        XCTAssertFalse(store.subtitleCustomizeAss)
    }

    func testAChosenScaleCarriesTheTextSize() throws {
        let defaults = try defaults()
        defaults.set("SCALE", forKey: "player.subtitle_style_override")
        defaults.set(1.5, forKey: "player.subtitle_size")
        let store = PlayerSettingsStore(defaults: defaults)
        XCTAssertEqual(store.assSubtitleSize, 1.5)
        XCTAssertFalse(store.subtitleCustomizeAss)
        XCTAssertNil(store.storedValue("subtitle_style_override"))
    }

    func testForcingCarriesTheWholeTextStyle() throws {
        let defaults = try defaults()
        defaults.set("FORCE", forKey: "player.subtitle_style_override")
        defaults.set("#FFFFFF00", forKey: "player.subtitle_text_color")
        defaults.set(true, forKey: "player.subtitle_bold")
        let store = PlayerSettingsStore(defaults: defaults)
        XCTAssertTrue(store.subtitleCustomizeAss)
        XCTAssertEqual(store.assSubtitleTextColor, "#FFFFFF00")
        XCTAssertTrue(store.assSubtitleBold)
        XCTAssertNil(store.storedValue("subtitle_style_override"))
    }
}
