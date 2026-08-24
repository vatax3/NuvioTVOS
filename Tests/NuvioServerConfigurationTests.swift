import XCTest
@testable import Nuvio

/// The guard against the regression that locked a viewer out of their own Nuvio account.
///
/// An empty publishable key makes `isConfigured` false, and that refuses the QR flow *and*
/// email/password — so the failure had no way out from inside the app. It survived several
/// releases because nothing asserted that the shipped default was usable.
final class NuvioServerConfigurationTests: XCTestCase {
    func testShippedDefaultIsUsableWithoutTheViewerTypingAnything() {
        XCTAssertTrue(
            NuvioServerConfiguration.nuvioDefault.isConfigured,
            "A default that is not configured locks out both sign-in paths at once."
        )
    }

    func testNoStoredConfigurationFallsBackToTheDefault() {
        XCTAssertEqual(NuvioServerConfiguration.restored(from: nil), .nuvioDefault)
    }

    func testNuvioBackendThatLostItsKeyIsHealed() {
        let stored = NuvioServerConfiguration(backendUrl: "https://api.nuvio.tv", publishableKey: "")

        let restored = NuvioServerConfiguration.restored(from: stored)

        XCTAssertTrue(restored.isConfigured)
        XCTAssertEqual(restored.publishableKey, NuvioServerConfiguration.nuvioDefault.publishableKey)
    }

    func testEmptyBackendIsHealedToNuvioRatherThanLeftBlank() {
        let stored = NuvioServerConfiguration(backendUrl: "", publishableKey: "")

        let restored = NuvioServerConfiguration.restored(from: stored)

        XCTAssertEqual(restored.normalizedBackendUrl, "https://api.nuvio.tv")
        XCTAssertTrue(restored.isConfigured)
    }

    /// A trailing slash or a missing scheme is the same backend, and a viewer who typed it by
    /// hand should not be the one person the repair skips.
    func testHealingRecognisesNuvioThroughNormalisation() {
        let stored = NuvioServerConfiguration(backendUrl: "api.nuvio.tv/", publishableKey: "  ")

        XCTAssertTrue(NuvioServerConfiguration.restored(from: stored).isConfigured)
    }

    func testAKeyTheViewerSuppliedIsNeverOverwritten() {
        let stored = NuvioServerConfiguration(
            backendUrl: "https://api.nuvio.tv", publishableKey: "sb_publishable_theirs"
        )

        XCTAssertEqual(NuvioServerConfiguration.restored(from: stored).publishableKey, "sb_publishable_theirs")
    }

    /// Nuvio's key would not authenticate against somebody else's Supabase project, so writing it
    /// into a self-hosted configuration would trade a legible "not configured" for a 401.
    func testSelfHostedBackendWithNoKeyIsLeftAlone() {
        let stored = NuvioServerConfiguration(
            backendUrl: "https://sync.example.com", publishableKey: ""
        )

        let restored = NuvioServerConfiguration.restored(from: stored)

        XCTAssertEqual(restored, stored)
        XCTAssertFalse(restored.isConfigured)
    }

    /// The other fields are the viewer's, and a key repair is not a licence to reset them.
    func testRepairPreservesEveryOtherStoredField() {
        let stored = NuvioServerConfiguration(
            backendUrl: "https://api.nuvio.tv",
            publishableKey: "",
            supportsTvLogin: false,
            supportsEmailPassword: false,
            tvLoginWebBaseUrlOverride: "https://login.example.com"
        )

        let restored = NuvioServerConfiguration.restored(from: stored)

        XCTAssertFalse(restored.supportsTvLogin)
        XCTAssertFalse(restored.supportsEmailPassword)
        XCTAssertEqual(restored.tvLoginWebBaseUrl, "https://login.example.com")
    }
}
