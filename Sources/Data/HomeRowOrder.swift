import Foundation

/// One row of the home screen, as the saved order refers to it.
///
/// Home is not a list of catalogues with collections bolted on either end — upstream keeps a
/// single ordered list of keys where a collection sits between two catalogues as an equal.
/// `collection_<id>` is their key format, and it is kept verbatim so a saved order stays legible
/// next to theirs.
enum HomeRowKey: Hashable, Sendable, Identifiable {
    /// `"<addonBaseUrl>#<descriptorKey>"`, the same string `CatalogRowState.id` produces.
    case catalog(String)
    case collection(String)

    var id: String {
        switch self {
        case .catalog(let key): return key
        case .collection(let id): return "collection_\(id)"
        }
    }

    var isCollection: Bool {
        if case .collection = self { return true }
        return false
    }

    var collectionId: String? {
        if case .collection(let id) = self { return id }
        return nil
    }

    var catalogKey: String? {
        if case .catalog(let key) = self { return key }
        return nil
    }
}

/// Port of `rebuildCatalogOrder` and `normalizeCollectionBoundaries` from
/// `HomeViewModelCatalogUtils.kt`.
///
/// Pure on purpose. The rules here are the kind that look obvious written down and go wrong in a
/// view: a collection that has never been reordered belongs at the end, one that has belongs
/// exactly where it was put, and in follow-the-addon-order mode a collection may not be left
/// inside somebody's block of catalogues.
enum HomeRowOrder {
    /// A home-eligible catalogue and the addon that owns it, in manifest order.
    struct Catalog: Hashable, Sendable {
        var key: String
        /// The addon this catalogue came from — what defines a "block" for normalisation.
        var owner: String

        init(key: String, owner: String) {
            self.key = key
            self.owner = owner
        }
    }

    /// The order Home renders in.
    ///
    /// - `saved`: what the viewer arranged, which may name rows that no longer exist.
    /// - `catalogs`: every home-eligible catalogue of every enabled addon, in manifest order.
    /// - `collections`: collection ids in creation order, **excluding pinned ones**, which are
    ///   rendered ahead of this whole list and would otherwise appear twice.
    /// - `followsAddonOrder`: the `follow_addons_order` preference. Catalogues then keep manifest
    ///   order no matter what the saved order says, and only the collections move.
    static func merge(
        saved: [HomeRowKey],
        catalogs: [Catalog],
        collections: [String],
        followsAddonOrder: Bool
    ) -> [HomeRowKey] {
        let defaultOrder = catalogs.map { HomeRowKey.catalog($0.key) }
        let collectionKeys = collections.map { HomeRowKey.collection($0) }
        let available = Set(defaultOrder + collectionKeys)

        // A saved row for a catalogue that has since been uninstalled, or a collection that was
        // deleted, is dropped rather than carried forward as a gap.
        var seen = Set<HomeRowKey>()
        let savedValid = saved.filter { available.contains($0) && seen.insert($0).inserted }

        guard followsAddonOrder else {
            let savedSet = Set(savedValid)
            return savedValid
                + defaultOrder.filter { !savedSet.contains($0) }
                + collectionKeys.filter { !savedSet.contains($0) }
        }

        guard !savedValid.isEmpty else { return defaultOrder + collectionKeys }

        // Catalogues stay in manifest order; the saved order only says where the collections
        // fall between them. Walking a pointer through the manifest is how a saved catalogue
        // position translates into "everything up to here comes first".
        var result: [HomeRowKey] = []
        var placed = Set<HomeRowKey>()
        var pointer = 0

        func append(_ key: HomeRowKey) {
            guard placed.insert(key).inserted else { return }
            result.append(key)
        }

        for key in savedValid {
            if key.isCollection {
                append(key)
            } else if let target = defaultOrder.firstIndex(of: key) {
                while pointer <= target {
                    append(defaultOrder[pointer])
                    pointer += 1
                }
            }
        }
        while pointer < defaultOrder.count {
            append(defaultOrder[pointer])
            pointer += 1
        }
        for key in collectionKeys { append(key) }

        return normalizingCollectionBoundaries(result, owners: ownerMap(catalogs))
    }

    private static func ownerMap(_ catalogs: [Catalog]) -> [String: String] {
        Dictionary(catalogs.map { ($0.key, $0.owner) }, uniquingKeysWith: { first, _ in first })
    }

    /// Pushes a collection that ended up *inside* one addon's run of catalogues to the end of
    /// that run.
    ///
    /// Only in follow-the-addon-order mode, and the reason is that mode's whole premise: the
    /// viewer has said an addon's catalogues belong together in the order the addon publishes
    /// them. A collection dropped into the middle of Cinemeta's four rails splits them, which is
    /// the one thing that mode exists to prevent. Between two different addons is fine — that is
    /// a boundary, not a split.
    static func normalizingCollectionBoundaries(
        _ order: [HomeRowKey],
        owners: [String: String]
    ) -> [HomeRowKey] {
        var result = order
        var changed = true
        while changed {
            changed = false
            var index = 0
            while index < result.count {
                guard result[index].isCollection else {
                    index += 1
                    continue
                }
                let previous = owner(in: result, before: index, owners: owners)
                let next = owner(in: result, after: index, owners: owners)
                guard let previous, let next, previous == next else {
                    index += 1
                    continue
                }
                let key = result.remove(at: index)
                var insertion = index
                while insertion < result.count,
                      !result[insertion].isCollection,
                      result[insertion].catalogKey.flatMap({ owners[$0] }) == previous {
                    insertion += 1
                }
                result.insert(key, at: insertion)
                if insertion != index { changed = true }
                index += 1
            }
        }
        return result
    }

    private static func owner(
        in order: [HomeRowKey], before index: Int, owners: [String: String]
    ) -> String? {
        for position in stride(from: index - 1, through: 0, by: -1) {
            if let key = order[position].catalogKey { return owners[key] }
        }
        return nil
    }

    private static func owner(
        in order: [HomeRowKey], after index: Int, owners: [String: String]
    ) -> String? {
        for position in (index + 1)..<order.count {
            if let key = order[position].catalogKey { return owners[key] }
        }
        return nil
    }
}
