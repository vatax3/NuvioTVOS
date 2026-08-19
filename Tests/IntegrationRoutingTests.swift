import XCTest
@testable import Nuvio

final class IntegrationRoutingTests: XCTestCase {
    func testTMDBBrowseFiltersUseTheExpectedDiscoverParameters() {
        XCTAssertEqual(TMDBClient.BrowseFilter.network(213).queryItem, "with_networks=213")
        XCTAssertEqual(TMDBClient.BrowseFilter.company(420).queryItem, "with_companies=420")
        XCTAssertEqual(TMDBClient.BrowseFilter.genre(18).queryItem, "with_genres=18")
    }

    func testDebridCapabilitiesMatchProviderIntegrations() {
        XCTAssertFalse(DebridProvider.realDebrid.supportsCacheCheck)
        XCTAssertFalse(DebridProvider.realDebrid.supportsCloudLibrary)

        XCTAssertTrue(DebridProvider.premiumize.supportsCacheCheck)
        XCTAssertTrue(DebridProvider.premiumize.supportsCloudLibrary)
        XCTAssertTrue(DebridProvider.torbox.supportsCacheCheck)
        XCTAssertTrue(DebridProvider.torbox.supportsCloudLibrary)
    }
}
