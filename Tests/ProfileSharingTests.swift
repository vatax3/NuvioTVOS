import XCTest
@testable import Nuvio

/// `usesPrimaryAddons` was stored, decoded and synced to the server, and read by nothing — a
/// profile set to share the primary's addons quietly started from the default two instead.
/// These pin the two halves that make the flag mean something.
final class ProfileSharingTests: XCTestCase {
    private let defaults = UserDefaults.standard

    override func tearDown() {
        ProfileScope.activate(ProfileScope.primaryProfileId)
        ProfileScope.setSharing(addons: false, plugins: false)
        super.tearDown()
    }

    func testPrimaryNeverBorrowsFromItself() {
        ProfileScope.activate(ProfileScope.primaryProfileId)
        ProfileScope.setSharing(addons: true, plugins: true)
        XCTAssertFalse(ProfileScope.sharesPrimaryAddons)
        XCTAssertFalse(ProfileScope.sharesPrimaryPlugins)
        XCTAssertEqual(ProfileScope.addonStorage, .profile)
    }

    /// The primary's files sit unprefixed at the top level, so "share with the primary" and
    /// "global" have to resolve to the same place — that identity is the whole mechanism.
    func testABorrowingProfileReadsTheGlobalPath() {
        ProfileScope.activate("secondary-test")
        ProfileScope.setSharing(addons: true, plugins: false)

        XCTAssertTrue(ProfileScope.sharesPrimaryAddons)
        XCTAssertEqual(ProfileScope.addonStorage, .global)
        XCTAssertEqual(ProfileScope.pluginStorage, .profile)
        XCTAssertEqual(ProfileScope.storageSubdirectory, "profiles/secondary-test")
    }

    func testAProfileWithItsOwnDataKeepsItsOwnDirectory() {
        ProfileScope.activate("secondary-test")
        ProfileScope.setSharing(addons: false, plugins: false)

        XCTAssertEqual(ProfileScope.addonStorage, .profile)
        XCTAssertEqual(ProfileScope.pluginStorage, .profile)
    }
}
