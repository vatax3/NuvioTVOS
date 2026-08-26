import Foundation

/// When two content ids name the same show.
///
/// Addons key the same series differently — Cinemeta gives `tt0903747`, an anime addon gives
/// `kitsu:12345`, a TMDB-sourced row gives `tmdb:1396`. Watch two episodes from two addons and
/// the rail holds two rows for one show, each offering a different next episode. To us they are
/// two series; to the viewer they are one, and the second row is simply wrong.
///
/// The bridge is the IMDb id, which the metadata carries even when the addon's own id is in
/// another namespace. Nothing here re-keys storage: progress records stay under the id they were
/// written with, because that is the id the addon will ask for at playback. This is a display
/// rule, applied where rows are emitted.
enum SeriesIdentity {
    /// The key two rows for the same show agree on.
    ///
    /// The IMDb id when one is known, because it is the only namespace every source can be
    /// translated into. A title with none keys on itself, which means it groups with nothing —
    /// the right answer, since there is no evidence it is anybody's sibling.
    static func canonicalKey(contentId: String, imdbId: String?) -> String {
        if let imdb = normalised(imdbId), imdb.hasPrefix("tt") { return "imdb:\(imdb)" }

        let id = normalised(contentId) ?? ""
        // An addon may hand back the IMDb id as the content id itself.
        if id.hasPrefix("tt") { return "imdb:\(id)" }
        return id
    }

    private static func normalised(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One row per show, keeping the most recently active.
    ///
    /// Most recent rather than most complete: the row a viewer last touched is the addon they
    /// are actually watching it on, and that is the one whose next episode they want offered.
    /// Ties keep the incoming order, so the result is stable across redraws — a rail that
    /// reshuffles on every refresh is its own bug.
    static func deduplicated<Row>(
        _ rows: [Row],
        contentId: (Row) -> String,
        imdbId: (Row) -> String?,
        activity: (Row) -> Date
    ) -> [Row] {
        var best: [String: Int] = [:]
        var kept: [Row?] = rows.map { $0 }

        for (index, row) in rows.enumerated() {
            let key = canonicalKey(contentId: contentId(row), imdbId: imdbId(row))
            guard !key.isEmpty else { continue }
            guard let incumbent = best[key] else {
                best[key] = index
                continue
            }
            if activity(row) > activity(rows[incumbent]) {
                kept[incumbent] = nil
                best[key] = index
            } else {
                kept[index] = nil
            }
        }
        return kept.compactMap { $0 }
    }
}
