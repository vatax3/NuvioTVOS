import Foundation

/// The part of a library entry that cannot be fetched again.
///
/// `library.json` holds whole `MetaPreview`s — posters, backdrops, descriptions, genres — and
/// lives in Caches, which tvOS is documented as free to reclaim under storage pressure. For a
/// viewer signed into a Nuvio account that is survivable: the next sync brings the rows back. For
/// a viewer who never connected one, **a reclaim takes their entire library and there is nothing
/// to rebuild it from.**
///
/// This is the same defect the addon list had until 1.0.37, and it takes the same shape of fix:
/// separate what the viewer *made* from what can be fetched again, and put only the first in
/// durable storage. See `AddonChoice`, which is the precedent in this tree.
///
/// tvOS leaves one durable place — `UserDefaults`, read wholesale on every access and therefore
/// budgeted. A whole preview would not fit a library of any size; four fields do.
struct LibraryEntryRef: Codable, Hashable, Identifiable, Sendable {
    var rowKey: String
    var id: String
    var rawType: String
    var name: String
    var addedAt: Date

    init(_ item: SavedLibraryItem) {
        rowKey = item.preview.rowKey
        id = item.preview.id
        rawType = item.preview.rawType
        name = item.preview.name
        addedAt = item.addedAt
    }

    /// The entry as the library screen can draw it, with whatever artwork survived.
    ///
    /// A row restored from a ref alone has no poster, which is visibly worse than one that kept
    /// its artwork — and enormously better than a row that is gone. The preview cache usually
    /// still has it, and the next visit to the title refills it either way.
    func restored(preview cached: MetaPreview?) -> SavedLibraryItem {
        SavedLibraryItem(
            preview: cached ?? MetaPreview(
                id: id,
                type: ContentType.from(rawType),
                rawType: rawType,
                name: name
            ),
            addedAt: addedAt
        )
    }
}

/// How much of a durable store may be spent before entries are dropped, and which go first.
///
/// `JSONFileStore` refuses a write over its budget and **logs rather than throws** — so a store
/// that quietly outgrows it simply stops persisting, which is worse than the purgeable location
/// it was moved out of. Nothing may be handed to a durable store without having been bounded
/// first, and the bound has to be a rule rather than a hope.
enum DurableLibraryBudget {
    /// Deliberately under `JSONFileStore.criticalByteBudget`. The margin absorbs a long title or
    /// two arriving between the measurement and the write.
    static let byteBudget = 112 * 1024

    /// Trims oldest-first until the encoded list fits.
    ///
    /// Oldest-first because recency is the only ordering that matches what a viewer would choose:
    /// the title added last night is the one they would miss, and the one added two years ago is
    /// the one they have forgotten saving. Nothing is dropped while the list fits, which is every
    /// library short of roughly a thousand titles.
    static func fitting(_ refs: [LibraryEntryRef]) -> [LibraryEntryRef] {
        longestFittingPrefix(of: refs.sorted { $0.addedAt > $1.addedAt })
    }

    /// Same rule for resume points, ordered by when they were last touched.
    static func fitting(_ rows: [WatchProgress]) -> [WatchProgress] {
        longestFittingPrefix(of: rows.sorted { $0.updatedAt > $1.updatedAt })
    }

    /// Binary search rather than dropping one at a time: trimming by re-encoding after every
    /// removal is quadratic, and this runs on the main actor on every library write.
    private static func longestFittingPrefix<T: Encodable>(of ordered: [T]) -> [T] {
        guard encodedSize(ordered) > byteBudget else { return ordered }
        var low = 0
        var high = ordered.count
        while low < high {
            let mid = (low + high + 1) / 2
            if encodedSize(Array(ordered.prefix(mid))) <= byteBudget {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return Array(ordered.prefix(low))
    }

    static func encodedSize<T: Encodable>(_ value: T) -> Int {
        (try? JSONEncoder().encode(value))?.count ?? 0
    }
}
