import XCTest
@testable import Nuvio

/// One key, one default, for a setting that had two of each.
final class RememberLastProfileTests: XCTestCase {

    /// The bug this exists to prevent. `SettingsStore` defaulted it on and `ProfileStore`
    /// defaulted it off, so a fresh install showed the switch on and went to "Who's watching?"
    /// every launch — a control that lied about its own state.
    func testTheDefaultIsOffAndThereIsOnlyOne() {
        XCTAssertFalse(RememberLastProfile.defaultValue)
        XCTAssertFalse(RememberLastProfile.resolve(current: nil, legacy: nil))
    }

    func testAStoredValueWins() {
        XCTAssertTrue(RememberLastProfile.resolve(current: true, legacy: nil))
        XCTAssertFalse(RememberLastProfile.resolve(current: false, legacy: nil))
    }

    /// Somebody who set it under the old name keeps their choice.
    func testTheOldKeyIsStillRead() {
        XCTAssertTrue(RememberLastProfile.resolve(current: nil, legacy: true))
        XCTAssertFalse(RememberLastProfile.resolve(current: nil, legacy: false))
    }

    /// Both can be present at once — a device that set the old key and then synced a blob
    /// carrying the new one. Android wrote the new one, so it wins.
    func testTheCurrentKeyBeatsTheOldOne() {
        XCTAssertTrue(RememberLastProfile.resolve(current: true, legacy: false))
        XCTAssertFalse(RememberLastProfile.resolve(current: false, legacy: true))
    }

    /// "Absent" and "false" have to stay different answers, which is why this reads untyped
    /// values rather than a `Bool` with a default baked in.
    func testAbsenceIsNotFalseness() {
        XCTAssertFalse(RememberLastProfile.resolve(current: nil, legacy: nil))
        XCTAssertTrue(
            RememberLastProfile.resolve(current: nil, legacy: true),
            "an absent current key must not shadow a stored old one"
        )
    }

    /// Anything that is not a boolean is not an answer.
    func testRubbishFallsThrough() {
        XCTAssertTrue(RememberLastProfile.resolve(current: "yes", legacy: true))
        XCTAssertFalse(RememberLastProfile.resolve(current: 1, legacy: "no"))
    }

    /// The reason for the rename: `PreferenceStore`'s own comment promises the keys match
    /// Android's so the sync path stays wire-compatible, and this one did not.
    func testTheKeyIsTheOneAndroidWrites() {
        XCTAssertEqual(RememberLastProfile.key, "remember_last_profile_enabled")
        XCTAssertEqual(RememberLastProfile.legacyKey, "remember_last_profile")
        XCTAssertNotEqual(RememberLastProfile.key, RememberLastProfile.legacyKey)
    }

    /// `ProfileStore` reads defaults directly, before the settings graph exists, so it has to
    /// build the same name the store would have written.
    func testTheDefaultsNameMatchesTheStoresNamespace() {
        XCTAssertEqual(
            RememberLastProfile.defaultsKey(RememberLastProfile.key),
            "app.remember_last_profile_enabled"
        )
        XCTAssertEqual(
            RememberLastProfile.defaultsKey(RememberLastProfile.legacyKey),
            "app.remember_last_profile"
        )
    }
}
