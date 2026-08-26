import XCTest
@testable import Nuvio

/// The franchise row on a film's detail screen.
final class FranchiseCollectionRowTests: XCTestCase {
    private func meta(id: String, name: String) -> Meta {
        Meta(id: id, type: .movie, rawType: "movie", name: name)
    }

    private let parts = [
        preview_("tmdb:1893", "The Phantom Menace", "1999"),
        preview_("tmdb:1894", "Attack of the Clones", "2002"),
        preview_("tmdb:1895", "Revenge of the Sith", "2005")
    ]

    private static func preview_(_ id: String, _ name: String, _ year: String?) -> MetaPreview {
        MetaPreview(id: id, type: .movie, rawType: "movie", name: name, releaseInfo: year)
    }

    /// A collection's parts are TMDB ids and the page is keyed on an IMDb id, so the ids never
    /// match and the film would otherwise be the first thing in a row about itself.
    func testTheFilmYouAreLookingAtIsNotInItsOwnRow() {
        let others = FranchiseCollectionRow.others(
            in: parts, excluding: meta(id: "tt0121766", name: "Revenge of the Sith")
        )
        XCTAssertEqual(others.map(\.name), ["The Phantom Menace", "Attack of the Clones"])
    }

    func testItIsAlsoDroppedWhenTheIdDoesMatch() {
        let others = FranchiseCollectionRow.others(
            in: parts, excluding: meta(id: "tmdb:1893", name: "Something else entirely")
        )
        XCTAssertEqual(others.count, 2)
        XCTAssertFalse(others.contains { $0.id == "tmdb:1893" })
    }

    /// Release order is the order somebody watches a franchise in. TMDB returns whatever it
    /// returns.
    func testTheRowIsInReleaseOrder() {
        let shuffled = [parts[2], parts[0], parts[1]]
        let others = FranchiseCollectionRow.others(
            in: shuffled, excluding: meta(id: "tt0", name: "Nothing")
        )
        XCTAssertEqual(others.map(\.releaseInfo), ["1999", "2002", "2005"])
    }

    /// A film with no year sorts first rather than being dropped — an unreleased sequel belongs
    /// in the row, and losing it would be worse than putting it in the wrong place.
    func testAFilmWithNoYearIsKept() {
        let withUnknown = parts + [Self.preview_("tmdb:1896", "Untitled sequel", nil)]
        let others = FranchiseCollectionRow.others(
            in: withUnknown, excluding: meta(id: "tt0", name: "Nothing")
        )
        XCTAssertEqual(others.count, 4)
        XCTAssertEqual(others.first?.name, "Untitled sequel")
    }

    /// TMDB registers a franchise before its second entry exists, so this is the common case and
    /// not a theoretical one: a row headed "part of a series" showing nothing.
    func testACollectionOfOnlyThisFilmIsNoRowAtAll() {
        let others = FranchiseCollectionRow.others(
            in: [parts[0]], excluding: meta(id: "tt0120915", name: "The Phantom Menace")
        )
        XCTAssertTrue(others.isEmpty)
        XCTAssertFalse(FranchiseCollectionRow.isWorthShowing(others))
    }

    func testARealFranchiseIsWorthShowing() {
        XCTAssertTrue(FranchiseCollectionRow.isWorthShowing(parts))
    }

    func testAnEmptyCollectionIsNoRow() {
        XCTAssertTrue(
            FranchiseCollectionRow.others(in: [], excluding: meta(id: "tt0", name: "X")).isEmpty
        )
    }
}
