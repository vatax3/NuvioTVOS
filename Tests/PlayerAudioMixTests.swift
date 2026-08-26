import XCTest
@testable import Nuvio

/// The arithmetic between a dial the viewer turns and what libmpv is actually told.
///
/// Every one of these conversions is invisible in code review and very audible on a television,
/// which is the whole reason they live in a type of their own.
final class PlayerAudioMixTests: XCTestCase {

    // MARK: Amplification

    /// mpv wants a percentage of the source, and the control is in amplitude decibels — the same
    /// `10^(dB/20)` upstream's `GainAudioProcessor` uses.
    func testZeroDecibelsIsUnchangedAudio() {
        XCTAssertEqual(PlayerAudioMix.volumePercent(amplificationDb: 0), 100, accuracy: 0.001)
    }

    func testSixDecibelsIsAboutDoubleAmplitude() {
        XCTAssertEqual(PlayerAudioMix.volumePercent(amplificationDb: 6), 199.5, accuracy: 0.5)
    }

    func testTheTopOfTheRangeStaysUnderMpvsVolumeCeiling() {
        // `volume-max` is set to 400; a request mpv would refuse is silently no amplification.
        let loudest = PlayerAudioMix.volumePercent(
            amplificationDb: PlayerAudioMix.amplificationRangeDb.upperBound
        )
        XCTAssertLessThanOrEqual(loudest, 400)
        XCTAssertGreaterThan(loudest, 300, "10 dB should be most of the available headroom")
    }

    func testAmplificationIsClampedBothWays() {
        XCTAssertEqual(PlayerAudioMix.volumePercent(amplificationDb: -20), 100, accuracy: 0.001)
        XCTAssertEqual(
            PlayerAudioMix.volumePercent(amplificationDb: 99),
            PlayerAudioMix.volumePercent(amplificationDb: 10),
            accuracy: 0.001
        )
    }

    func testAmplificationRisesWithTheDial() {
        let values = (0...10).map { PlayerAudioMix.volumePercent(amplificationDb: $0) }
        XCTAssertEqual(values, values.sorted())
    }

    // MARK: Centre mix

    /// Zero on the dial must be libswresample's own default, or turning the setting on and
    /// leaving it alone would change the sound.
    func testZeroIsTheResamplersOwnDefault() {
        XCTAssertEqual(
            PlayerAudioMix.centerMixLevel(db: 0),
            PlayerAudioMix.defaultCenterMixLevel,
            accuracy: 0.0001
        )
    }

    /// And at zero nothing is passed at all — the point is not to build a resampler context for
    /// a setting nobody touched.
    func testZeroPassesNoOptionAtAll() {
        XCTAssertNil(PlayerAudioMix.swresampleOptions(centerMixDb: 0))
        XCTAssertNotNil(PlayerAudioMix.swresampleOptions(centerMixDb: 1))
        XCTAssertNotNil(PlayerAudioMix.swresampleOptions(centerMixDb: -1))
    }

    /// The option is a float in [-32, 32]. The top of the viewer's range has to land inside it,
    /// or the loudest dialogue setting is the one that silently does nothing.
    func testTheWholeRangeFitsWhatLibswresampleAccepts() {
        for db in PlayerAudioMix.centerMixRangeDb {
            let level = PlayerAudioMix.centerMixLevel(db: db)
            XCTAssertGreaterThan(level, 0, "\(db) dB")
            XCTAssertLessThanOrEqual(level, 32, "\(db) dB overflows the option")
        }
    }

    func testTheRangeIsAsymmetricBecauseTheProblemIs() {
        XCTAssertEqual(PlayerAudioMix.centerMixRangeDb.lowerBound, -10)
        XCTAssertEqual(PlayerAudioMix.centerMixRangeDb.upperBound, 30)
    }

    func testCentreLevelIsClamped() {
        XCTAssertEqual(
            PlayerAudioMix.centerMixLevel(db: -99),
            PlayerAudioMix.centerMixLevel(db: -10),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PlayerAudioMix.centerMixLevel(db: 99),
            PlayerAudioMix.centerMixLevel(db: 30),
            accuracy: 0.0001
        )
    }

    /// The string goes into an mpv option list, so it has to be the key libswresample knows and
    /// a decimal it can parse — no locale comma, no exponent.
    func testTheOptionStringIsShapedForLibswresample() throws {
        let option = try XCTUnwrap(PlayerAudioMix.swresampleOptions(centerMixDb: 6))
        let parts = option.split(separator: "=")

        XCTAssertEqual(parts.first, "center_mix_level")
        XCTAssertEqual(parts.count, 2)
        let level = String(parts[1])
        XCTAssertNotNil(Double(level), "\(option) is not a parseable level")
        // The key itself is full of letters, so only the number is checked: a locale decimal
        // comma or an exponent is what libswresample would refuse.
        XCTAssertFalse(level.contains(","))
        XCTAssertFalse(level.lowercased().contains("e"))
    }

    func testSixDecibelsOfDialogueIsAboutDoubleTheDefault() throws {
        let option = try XCTUnwrap(PlayerAudioMix.swresampleOptions(centerMixDb: 6))
        let level = try XCTUnwrap(Double(option.split(separator: "=")[1]))
        XCTAssertEqual(level, PlayerAudioMix.defaultCenterMixLevel * 2, accuracy: 0.01)
    }

    // MARK: The grouped value

    func testTheDefaultsChangeNothing() {
        let options = PlayerAudioMix.Options()

        XCTAssertEqual(options.amplificationDb, 0)
        XCTAssertEqual(options.centerMixLevelDb, 0)
        XCTAssertFalse(options.normalizesDownmix, "upstream's default, and the safer one")
        XCTAssertNil(PlayerAudioMix.swresampleOptions(centerMixDb: options.centerMixLevelDb))
    }
}
