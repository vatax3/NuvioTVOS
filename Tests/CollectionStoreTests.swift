import XCTest
@testable import Nuvio

/// Collections had no coverage at all until they started driving what Home shows. Order is the
/// part worth pinning: it decides the rail order, so an off-by-one or an unguarded swap is now
/// visible on the first screen of the app rather than inside one tab of the Library.
///
/// The store persists to the app container, so each test snapshots the real list and puts it
/// back — a test that quietly deleted someone's collections would be a poor trade for coverage.
@MainActor
final class CollectionStoreTests: XCTestCase {
    private var store: CollectionStore!
    private var saved: [MediaCollection] = []

    override func setUp() async throws {
        try await super.setUp()
        store = CollectionStore()
        saved = store.collections
        store.replaceAll(with: [])
    }

    override func tearDown() async throws {
        store.replaceAll(with: saved)
        store = nil
        try await super.tearDown()
    }

    private func seedThree() -> [MediaCollection] {
        ["Tonight", "Rewatch", "With the kids"].compactMap { store.create(name: $0) }
    }

    func testCreatingKeepsInsertionOrder() {
        XCTAssertEqual(seedThree().count, 3)
        XCTAssertEqual(store.collections.map(\.name), ["Tonight", "Rewatch", "With the kids"])
    }

    func testBlankNamesAreRefused() {
        XCTAssertNil(store.create(name: "   "))
        XCTAssertNil(store.create(name: ""))
        XCTAssertTrue(store.collections.isEmpty)
    }

    /// The name is what a viewer typed on a television remote, so it is trimmed rather than
    /// taken literally.
    func testNamesAreTrimmed() {
        XCTAssertEqual(store.create(name: "  Tonight  ")?.name, "Tonight")
    }

    func testMovingReordersTheList() {
        let created = seedThree()
        store.move(created[2].id, by: -1)
        XCTAssertEqual(store.collections.map(\.name), ["Tonight", "With the kids", "Rewatch"])

        store.move(created[0].id, by: 1)
        XCTAssertEqual(store.collections.map(\.name), ["With the kids", "Tonight", "Rewatch"])
    }

    /// Both ends. The editor offers Move up and Move down unconditionally, so the first and last
    /// collection each have a button that must do nothing rather than something wrong.
    func testMovingPastEitherEndIsANoOp() {
        let created = seedThree()
        let before = store.collections.map(\.name)

        store.move(created[0].id, by: -1)
        store.move(created[2].id, by: 1)
        store.move(created[0].id, by: -5)

        XCTAssertEqual(store.collections.map(\.name), before)
    }

    func testMovingAnUnknownCollectionIsANoOp() {
        seedThree()
        let before = store.collections.map(\.name)
        store.move("not-a-collection", by: 1)
        XCTAssertEqual(store.collections.map(\.name), before)
    }

    func testDeletingRemovesOnlyThatCollection() {
        let created = seedThree()
        store.delete(created[1].id)
        XCTAssertEqual(store.collections.map(\.name), ["Tonight", "With the kids"])
        XCTAssertNil(store.collection(id: created[1].id))
    }

    func testRenamingAndResymbolising() {
        let created = seedThree()
        store.rename(created[0].id, to: "  Later  ")
        store.setSymbol("flame.fill", for: created[0].id)

        XCTAssertEqual(store.collection(id: created[0].id)?.name, "Later")
        XCTAssertEqual(store.collection(id: created[0].id)?.symbol, "flame.fill")
    }

    /// Collections sync as one blob, so a newer remote snapshot replaces the list wholesale.
    func testReplaceAllSupersedesTheLocalList() {
        seedThree()
        let incoming = [
            MediaCollection(
                id: "remote", name: "From another device", symbol: "star.fill",
                itemKeys: [], createdAt: .distantPast, updatedAt: .distantPast
            )
        ]
        store.replaceAll(with: incoming)
        XCTAssertEqual(store.collections.map(\.name), ["From another device"])
    }
}
