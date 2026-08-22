import Foundation
import Observation

@Observable
@MainActor
final class CollectionStore {
    private(set) var collections: [MediaCollection] = []

    /// When this device last changed its collections, which is what decides a sync conflict.
    ///
    /// The model carries no timestamps — upstream's does not either — so the previous
    /// per-collection `updatedAt` is gone. This is local bookkeeping and is deliberately not part
    /// of the synced payload: putting it there would change the shared shape.
    private(set) var updatedAt: Date = .distantPast

    private let file = JSONFileStore<[MediaCollection]>(filename: "collections.json")
    private let stamp = JSONFileStore<Date>(filename: "collections-updated-at.json")
    /// Where the manual collections this replaced were left. They are not readable by anything
    /// any more — the model has no notion of a hand-picked list — but deleting a viewer's folders
    /// as a side effect of a format change is not ours to do. See `retireManualCollections`.
    private static let retiredFilename = "collections-manual-retired.json"

    init() {
        Self.retireManualCollections()
        collections = file.load() ?? []
        updatedAt = stamp.load() ?? .distantPast
    }

    // MARK: Queries

    func collection(id: String) -> MediaCollection? {
        collections.first { $0.id == id }
    }

    func folder(id: String) -> (collection: MediaCollection, folder: CollectionFolder)? {
        for collection in collections {
            if let folder = collection.folders.first(where: { $0.id == id }) {
                return (collection, folder)
            }
        }
        return nil
    }

    /// Pinned collections first, insertion order otherwise — the order the manager lists them in.
    var ordered: [MediaCollection] {
        collections.filter(\.pinToTop) + collections.filter { !$0.pinToTop }
    }

    /// How Home splits collections around the addon catalogues.
    ///
    /// Upstream builds its home rows by adding every `pinToTop` collection **first**, before the
    /// ordered catalogue keys, and letting the unpinned ones fall wherever the saved catalogue
    /// order puts them — which, with no saved order, is the end. So "pinned" does not mean
    /// "first among collections", it means first on the screen, ahead of every catalogue.
    ///
    /// Getting this wrong is invisible until someone pins one: we had all collections after all
    /// catalogues, so pinning changed the order collections appeared in among themselves and
    /// nothing else.
    ///
    /// A collection with no folders is dropped from both halves: a heading over nothing is not an
    /// invitation to fill it, and Home is not where you would.
    nonisolated static func homePlacement(
        _ collections: [MediaCollection]
    ) -> (leading: [MediaCollection], trailing: [MediaCollection]) {
        let worthARail = collections.filter { !$0.folders.isEmpty }
        return (
            leading: worthARail.filter(\.pinToTop),
            trailing: worthARail.filter { !$0.pinToTop }
        )
    }

    var homePlacement: (leading: [MediaCollection], trailing: [MediaCollection]) {
        Self.homePlacement(collections)
    }

    // MARK: Collection mutations

    @discardableResult
    func create(title: String) -> MediaCollection? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collection = MediaCollection(title: trimmed)
        collections.append(collection)
        persist()
        return collection
    }

    func rename(_ collectionId: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: collectionId) else { return }
        collections[index].title = trimmed
        persist()
    }

    func update(_ collectionId: String, _ mutate: (inout MediaCollection) -> Void) {
        guard let index = index(of: collectionId) else { return }
        mutate(&collections[index])
        persist()
    }

    func delete(_ collectionId: String) {
        collections.removeAll { $0.id == collectionId }
        persist()
    }

    func move(_ collectionId: String, by offset: Int) {
        guard let index = index(of: collectionId) else { return }
        let target = index + offset
        guard collections.indices.contains(target) else { return }
        collections.swapAt(index, target)
        persist()
    }

    // MARK: Folder mutations

    @discardableResult
    func addFolder(title: String, to collectionId: String) -> CollectionFolder? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: collectionId) else { return nil }
        let folder = CollectionFolder(title: trimmed)
        collections[index].folders.append(folder)
        persist()
        return folder
    }

    func updateFolder(_ folderId: String, in collectionId: String, _ mutate: (inout CollectionFolder) -> Void) {
        guard let index = index(of: collectionId),
              let folderIndex = collections[index].folders.firstIndex(where: { $0.id == folderId })
        else { return }
        mutate(&collections[index].folders[folderIndex])
        persist()
    }

    func deleteFolder(_ folderId: String, from collectionId: String) {
        guard let index = index(of: collectionId) else { return }
        collections[index].folders.removeAll { $0.id == folderId }
        persist()
    }

    func moveFolder(_ folderId: String, in collectionId: String, by offset: Int) {
        guard let index = index(of: collectionId),
              let folderIndex = collections[index].folders.firstIndex(where: { $0.id == folderId })
        else { return }
        let target = folderIndex + offset
        guard collections[index].folders.indices.contains(target) else { return }
        collections[index].folders.swapAt(folderIndex, target)
        persist()
    }

    // MARK: Source mutations

    func addSource(_ source: CollectionSource, toFolder folderId: String, in collectionId: String) {
        updateFolder(folderId, in: collectionId) { folder in
            guard !folder.sources.contains(source) else { return }
            folder.sources.append(source)
        }
    }

    func removeSource(_ source: CollectionSource, fromFolder folderId: String, in collectionId: String) {
        updateFolder(folderId, in: collectionId) { folder in
            folder.sources.removeAll { $0 == source }
        }
    }

    // MARK: Sync and transfer

    /// Replaces every collection with the account's copy — collections sync as one blob, so a
    /// newer remote snapshot supersedes the local list wholesale.
    ///
    /// `markChanged` is false when the incoming list *is* the remote one: accepting a pull is not
    /// a local edit, and stamping it as one would make this device look newer than the server on
    /// the next pass and push the same data straight back.
    func replaceAll(with incoming: [MediaCollection], markChanged: Bool = true) {
        collections = incoming
        persist(markChanged: markChanged)
    }

    /// The interchange format, and the same bytes that go to the account. This is how a
    /// collection built on Android arrives, so it is a plain array with no envelope.
    func exportJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(collections) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns the collections rather than applying them, so the caller can show what is about
    /// to be imported before it replaces anything.
    nonisolated static func decode(_ json: String) throws -> [MediaCollection] {
        try JSONDecoder().decode([MediaCollection].self, from: Data(json.utf8))
    }

    private func index(of collectionId: String) -> Int? {
        collections.firstIndex { $0.id == collectionId }
    }

    private func persist(markChanged: Bool = true) {
        file.save(collections)
        guard markChanged else { return }
        updatedAt = Date()
        stamp.save(updatedAt)
    }

    /// Moves a pre-parity `collections.json` aside on first launch after the upgrade.
    ///
    /// The old file held hand-picked lists of titles, a shape this model cannot express and
    /// upstream never had. Decoding it now yields collections with an empty title and no folders,
    /// which would then be pushed to the account and land on Android as empty rows. Recognising
    /// it by its `itemKeys` key and setting it aside is what stops that, and leaves the data
    /// somewhere a viewer could still get at it.
    private static func retireManualCollections() {
        let store = JSONFileStore<[MediaCollection]>(filename: "collections.json")
        guard let raw = store.rawData(),
              let array = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]],
              array.contains(where: { $0["itemKeys"] != nil })
        else { return }
        store.moveAside(to: retiredFilename)
    }
}
