import XCTest
@testable import Nuvio

final class SearchHistoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SearchHistoryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testNewestSearchIsFirstAndDuplicatesMoveForward() {
        _ = SearchHistoryStore.record("Alien", defaults: defaults)
        _ = SearchHistoryStore.record("Arrival", defaults: defaults)
        let values = SearchHistoryStore.record("alien", defaults: defaults)
        XCTAssertEqual(values, ["alien", "Arrival"])
    }

    func testHistoryIsCapped() {
        for index in 0..<12 {
            SearchHistoryStore.record("Query \(index)", defaults: defaults)
        }
        XCTAssertEqual(SearchHistoryStore.load(defaults: defaults).count, SearchHistoryStore.maximumCount)
    }

    func testBlankAndSingleCharacterQueriesAreIgnored() {
        SearchHistoryStore.record(" ", defaults: defaults)
        SearchHistoryStore.record("a", defaults: defaults)
        XCTAssertTrue(SearchHistoryStore.load(defaults: defaults).isEmpty)
    }
}
