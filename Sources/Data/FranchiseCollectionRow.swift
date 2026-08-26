import Foundation

/// The other films in a franchise, as the detail screen shows them.
///
/// Small enough to inline, kept out because the two rules in it are both ones that produce a
/// visibly wrong row rather than a crash: a franchise that lists the film you are looking at, and
/// a franchise of one.
enum FranchiseCollectionRow {
    /// The row's items, or nothing when there is no row worth drawing.
    ///
    /// - Parameters:
    ///   - parts: everything TMDB returned for the collection, including this film.
    ///   - excluding: the film whose page this is.
    static func others(in parts: [MetaPreview], excluding current: Meta) -> [MetaPreview] {
        parts
            // By name as well as id: a collection's parts are TMDB ids and the page is keyed on
            // an IMDb id, so the ids do not match and the film would list itself.
            .filter { $0.id != current.id && $0.name != current.name }
            // Release order, which is the order somebody watches a franchise in and not the
            // order TMDB happens to return them.
            .sorted { ($0.releaseInfo ?? "") < ($1.releaseInfo ?? "") }
    }

    /// Whether to draw the row at all.
    ///
    /// A collection of one is a row headed "part of a series" showing nothing — TMDB registers a
    /// franchise before its second entry exists, so this is common rather than theoretical.
    static func isWorthShowing(_ others: [MetaPreview]) -> Bool { !others.isEmpty }
}
