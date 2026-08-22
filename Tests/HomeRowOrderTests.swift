import XCTest
@testable import Nuvio

/// The single order Home renders in, where a collection is an equal of a catalogue rather than
/// something appended after the list.
///
/// Ported from `rebuildCatalogOrder` and `normalizeCollectionBoundaries`. The rules read as
/// obvious and are not: a collection that was never moved belongs at the end, one that was
/// belongs exactly where it was put, and in follow-the-addon-order mode it may not be left
/// sitting inside one addon's run of catalogues.
final class HomeRowOrderTests: XCTestCase {
    // Two addons, so "inside a block" and "between blocks" are both expressible.
    private let catalogs = [
        HomeRowOrder.Catalog(key: "https://a#movie/top", owner: "https://a"),
        HomeRowOrder.Catalog(key: "https://a#series/top", owner: "https://a"),
        HomeRowOrder.Catalog(key: "https://b#movie/new", owner: "https://b")
    ]

    private var a1: HomeRowKey { .catalog("https://a#movie/top") }
    private var a2: HomeRowKey { .catalog("https://a#series/top") }
    private var b1: HomeRowKey { .catalog("https://b#movie/new") }
    private var collection: HomeRowKey { .collection("c1") }

    private func merge(
        saved: [HomeRowKey],
        collections: [String] = ["c1"],
        followsAddonOrder: Bool = false
    ) -> [HomeRowKey] {
        HomeRowOrder.merge(
            saved: saved,
            catalogs: catalogs,
            collections: collections,
            followsAddonOrder: followsAddonOrder
        )
    }

    // MARK: Defaults

    /// The default nobody has touched: catalogues in manifest order, collections after them.
    /// This is what upstream does too, and it is why "my collections are at the bottom" is only
    /// a bug once something has been pinned or moved.
    func testWithNoSavedOrderCollectionsFollowTheCatalogues() {
        XCTAssertEqual(merge(saved: []), [a1, a2, b1, collection])
    }

    func testWithNoSavedOrderAndFollowAddonsOrderTheAnswerIsTheSame() {
        XCTAssertEqual(merge(saved: [], followsAddonOrder: true), [a1, a2, b1, collection])
    }

    // MARK: Saved order

    /// The whole point of the change: a collection can sit between two catalogues.
    func testACollectionCanSitBetweenTwoCatalogues() {
        XCTAssertEqual(merge(saved: [a1, collection, a2, b1]), [a1, collection, a2, b1])
    }

    func testACollectionCanLeadTheListWithoutBeingPinned() {
        XCTAssertEqual(merge(saved: [collection, a1, a2, b1]), [collection, a1, a2, b1])
    }

    /// A newly installed addon's catalogue, and a newly created collection, are appended rather
    /// than dropped — and the collections land after the catalogues, as upstream orders them.
    func testRowsNotYetInTheSavedOrderAreAppended() {
        let merged = HomeRowOrder.merge(
            saved: [collection, a1],
            catalogs: catalogs,
            collections: ["c1", "c2"],
            followsAddonOrder: false
        )
        XCTAssertEqual(merged, [collection, a1, a2, b1, .collection("c2")])
    }

    /// An uninstalled addon or a deleted collection leaves a saved row pointing at nothing.
    func testSavedRowsThatNoLongerExistAreDropped() {
        let merged = merge(saved: [.catalog("https://gone#movie/x"), .collection("deleted"), a1])
        XCTAssertEqual(merged, [a1, a2, b1, collection])
    }

    func testADuplicatedSavedRowAppearsOnce() {
        XCTAssertEqual(merge(saved: [a1, a1, collection]), [a1, collection, a2, b1])
    }

    // MARK: Follow the addon order

    /// In this mode the viewer has said an addon's catalogues belong in the order the addon
    /// publishes them, so a saved catalogue order is ignored — only the collection moves.
    func testFollowingAddonOrderIgnoresASavedCatalogueOrder() {
        XCTAssertEqual(
            merge(saved: [b1, a2, a1], followsAddonOrder: true),
            [a1, a2, b1]  + [collection]
        )
    }

    /// Dropped between two of Cinemeta's rails, a collection would split them — which is the one
    /// thing this mode exists to prevent. It is pushed to the end of that addon's run.
    func testACollectionInsideOneAddonsBlockIsPushedToTheBlockBoundary() {
        XCTAssertEqual(
            merge(saved: [a1, collection, a2, b1], followsAddonOrder: true),
            [a1, a2, collection, b1]
        )
    }

    /// Between two different addons is a boundary, not a split, so it stays put.
    func testACollectionBetweenTwoAddonsIsLeftWhereItIs() {
        XCTAssertEqual(
            merge(saved: [a1, a2, collection, b1], followsAddonOrder: true),
            [a1, a2, collection, b1]
        )
    }

    func testACollectionBeforeEveryCatalogueIsLeftWhereItIs() {
        XCTAssertEqual(
            merge(saved: [collection, a1, a2, b1], followsAddonOrder: true),
            [collection, a1, a2, b1]
        )
    }

    /// Normalisation runs to a fixed point: moving one collection can leave the next one mid-block.
    func testNormalisationSettlesWhenSeveralCollectionsAreMidBlock() {
        let second = HomeRowKey.collection("c2")
        let merged = HomeRowOrder.merge(
            saved: [a1, collection, second, a2, b1],
            catalogs: catalogs,
            collections: ["c1", "c2"],
            followsAddonOrder: true
        )
        XCTAssertEqual(merged, [a1, a2, collection, second, b1])
    }

    // MARK: Pinned collections

    /// Pinned collections are rendered ahead of this whole list, so they are not handed in here.
    /// Passing them anyway would draw them twice, which is what excluding them prevents.
    func testAPinnedCollectionIsSimplyAbsentFromTheMergedOrder() {
        XCTAssertEqual(merge(saved: [a1, collection], collections: []), [a1, a2, b1])
    }
}
