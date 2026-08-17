import Foundation
import Observation

/// A user-made folder of titles — Nuvio's collections. Membership is by `rowKey` so an entry
/// survives artwork or metadata changes, and the artwork itself comes from the library's preview
/// cache rather than being duplicated here.
struct MediaCollection: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    var itemKeys: [String]
    var createdAt: Date
    var updatedAt: Date

    var count: Int { itemKeys.count }

    static let availableSymbols = [
        "folder.fill", "star.fill", "heart.fill", "bookmark.fill",
        "film.stack", "sparkles", "flame.fill", "moon.stars.fill"
    ]
}

@Observable
@MainActor
final class CollectionStore {
    private(set) var collections: [MediaCollection] = []

    private let file = JSONFileStore<[MediaCollection]>(filename: "collections.json")

    init() {
        collections = file.load() ?? []
    }

    // MARK: Queries

    func collection(id: String) -> MediaCollection? {
        collections.first { $0.id == id }
    }

    func contains(_ preview: MetaPreview, in collectionId: String) -> Bool {
        collection(id: collectionId)?.itemKeys.contains(preview.rowKey) ?? false
    }

    /// Every collection the title belongs to — drives the checkmarks in the picker.
    func collections(containing preview: MetaPreview) -> [MediaCollection] {
        collections.filter { $0.itemKeys.contains(preview.rowKey) }
    }

    /// Resolves membership into previews, dropping keys whose artwork is no longer cached.
    func items(in collectionId: String, library: LibraryStore) -> [MetaPreview] {
        guard let collection = collection(id: collectionId) else { return [] }
        let saved = Dictionary(
            library.library.map { ($0.preview.rowKey, $0.preview) },
            uniquingKeysWith: { first, _ in first }
        )
        return collection.itemKeys.compactMap { key in
            saved[key] ?? library.previewCache[key]
        }
    }

    // MARK: Mutations

    @discardableResult
    func create(name: String, symbol: String = "folder.fill") -> MediaCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collection = MediaCollection(
            id: UUID().uuidString,
            name: trimmed,
            symbol: symbol,
            itemKeys: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        collections.append(collection)
        persist()
        return collection
    }

    func rename(_ collectionId: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: collectionId) else { return }
        collections[index].name = trimmed
        collections[index].updatedAt = Date()
        persist()
    }

    func setSymbol(_ symbol: String, for collectionId: String) {
        guard let index = index(of: collectionId) else { return }
        collections[index].symbol = symbol
        persist()
    }

    func delete(_ collectionId: String) {
        collections.removeAll { $0.id == collectionId }
        persist()
    }

    /// Newest additions sit at the top, which is how the folder reads on Android.
    func add(_ preview: MetaPreview, to collectionId: String, library: LibraryStore) {
        guard let index = index(of: collectionId) else { return }
        guard !collections[index].itemKeys.contains(preview.rowKey) else { return }
        collections[index].itemKeys.insert(preview.rowKey, at: 0)
        collections[index].updatedAt = Date()
        // Cache the artwork, otherwise the folder cannot draw an item the viewer never saved.
        library.cache(preview)
        persist()
    }

    func remove(_ preview: MetaPreview, from collectionId: String) {
        guard let index = index(of: collectionId) else { return }
        collections[index].itemKeys.removeAll { $0 == preview.rowKey }
        collections[index].updatedAt = Date()
        persist()
    }

    func toggle(_ preview: MetaPreview, in collectionId: String, library: LibraryStore) {
        if contains(preview, in: collectionId) {
            remove(preview, from: collectionId)
        } else {
            add(preview, to: collectionId, library: library)
        }
    }

    func move(_ collectionId: String, by offset: Int) {
        guard let index = index(of: collectionId) else { return }
        let target = index + offset
        guard collections.indices.contains(target) else { return }
        collections.swapAt(index, target)
        persist()
    }

    /// Replaces every collection with the account's copy — collections sync as one blob, so a
    /// newer remote snapshot supersedes the local list wholesale.
    func replaceAll(with incoming: [MediaCollection]) {
        collections = incoming
        persist()
    }

    private func index(of collectionId: String) -> Int? {
        collections.firstIndex { $0.id == collectionId }
    }

    private func persist() { file.save(collections) }
}
