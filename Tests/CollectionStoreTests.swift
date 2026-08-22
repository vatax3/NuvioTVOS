import XCTest
@testable import Nuvio

/// The store's own behaviour. The wire format — which is the part that decides whether the two
/// apps share collections or destroy each other's — is in `CollectionCodableTests`.
///
/// The store persists to the app container, so each test snapshots the real list and puts it
/// back. A test that quietly deleted someone's collections would be a poor trade for coverage.
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

    @discardableResult
    private func seedThree() -> [MediaCollection] {
        ["Tonight", "Rewatch", "With the kids"].compactMap { store.create(title: $0) }
    }

    func testCreatingKeepsInsertionOrder() {
        XCTAssertEqual(seedThree().count, 3)
        XCTAssertEqual(store.collections.map(\.title), ["Tonight", "Rewatch", "With the kids"])
    }

    func testBlankTitlesAreRefused() {
        XCTAssertNil(store.create(title: "   "))
        XCTAssertTrue(store.collections.isEmpty)
    }

    func testTitlesAreTrimmed() {
        XCTAssertEqual(store.create(title: "  Tonight  ")?.title, "Tonight")
    }

    func testMovingReordersTheList() {
        let created = seedThree()
        store.move(created[2].id, by: -1)
        XCTAssertEqual(store.collections.map(\.title), ["Tonight", "With the kids", "Rewatch"])
    }

    /// Both ends. The editor offers Move up and Move down unconditionally, so the first and last
    /// collection each have a button that must do nothing rather than something wrong.
    func testMovingPastEitherEndIsANoOp() {
        let created = seedThree()
        let before = store.collections.map(\.title)
        store.move(created[0].id, by: -1)
        store.move(created[2].id, by: 1)
        store.move("not-a-collection", by: 1)
        XCTAssertEqual(store.collections.map(\.title), before)
    }

    /// Pinned collections lead, and the rest keep their order behind them — this is what the
    /// home screen renders.
    func testPinnedCollectionsComeFirst() {
        let created = seedThree()
        store.update(created[2].id) { $0.pinToTop = true }
        XCTAssertEqual(store.ordered.map(\.title), ["With the kids", "Tonight", "Rewatch"])
    }

    // MARK: Folders and sources

    func testFoldersAreAddedRemovedAndReordered() {
        guard let collection = store.create(title: "Tonight") else { return XCTFail("create") }
        let comedies = store.addFolder(title: "Comedies", to: collection.id)
        let horror = store.addFolder(title: "Horror", to: collection.id)
        XCTAssertEqual(store.collection(id: collection.id)?.folders.map(\.title), ["Comedies", "Horror"])

        store.moveFolder(horror!.id, in: collection.id, by: -1)
        XCTAssertEqual(store.collection(id: collection.id)?.folders.map(\.title), ["Horror", "Comedies"])

        store.deleteFolder(comedies!.id, from: collection.id)
        XCTAssertEqual(store.collection(id: collection.id)?.folders.map(\.title), ["Horror"])
    }

    func testSourcesAreAddedOnceAndRemovable() {
        guard let collection = store.create(title: "Tonight"),
              let folder = store.addFolder(title: "Comedies", to: collection.id)
        else { return XCTFail("seed") }

        let source = CollectionSource.addon(AddonCollectionSource(
            addonId: "com.linvo.cinemeta", type: "movie", catalogId: "top", genre: "Comedy"
        ))
        store.addSource(source, toFolder: folder.id, in: collection.id)
        store.addSource(source, toFolder: folder.id, in: collection.id)
        XCTAssertEqual(store.folder(id: folder.id)?.folder.sources.count, 1, "the same source twice is still one source")

        store.removeSource(source, fromFolder: folder.id, in: collection.id)
        XCTAssertTrue(store.folder(id: folder.id)?.folder.sources.isEmpty ?? false)
    }

    func testFolderLookupFindsItsCollection() {
        guard let collection = store.create(title: "Tonight"),
              let folder = store.addFolder(title: "Comedies", to: collection.id)
        else { return XCTFail("seed") }

        XCTAssertEqual(store.folder(id: folder.id)?.collection.id, collection.id)
        XCTAssertNil(store.folder(id: "nope"))
    }

    // MARK: Sync bookkeeping

    /// Accepting a pull is not a local edit. Stamping it as one would make this device look
    /// newer than the server on the next pass and push the same rows straight back.
    func testAcceptingARemoteSnapshotDoesNotCountAsALocalChange() {
        store.create(title: "Tonight")
        let afterLocalEdit = store.updatedAt

        store.replaceAll(with: [MediaCollection(title: "From another device")], markChanged: false)
        XCTAssertEqual(store.updatedAt, afterLocalEdit)

        store.create(title: "Later")
        XCTAssertGreaterThan(store.updatedAt, afterLocalEdit)
    }
}
