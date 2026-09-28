import Foundation

/// The completions offered above the search field.
///
/// Port of `rankedSuggestions` / `suggestionRank` / `mergedCatalogNames`. Ours offered only the
/// viewer's own recent searches, which helps the second time you look for something and never the
/// first — and the first is when typing on a television hurts most.
///
/// One adaptation, and it removes a request rather than adding one. Upstream fetches suggestions
/// on a shorter debounce than the search itself, so they arrive before the results do, at the cost
/// of a second round of catalog requests per keystroke burst. Ours ranks the titles the search has
/// *already* returned: no extra request, and the strip fills as each addon answers, because the
/// results are published that way too.
enum SearchSuggestions {
    /// Upstream's `MAX_SUGGESTIONS`. A strip is crossed one press at a time, so the ninth
    /// completion is one nobody reaches.
    static let maximum = 8

    /// How well `title` answers `query`, lower being better, or `nil` for no match.
    ///
    /// The four tiers are upstream's and the ordering is the whole value: an exact match, then a
    /// prefix, then a substring, then words matched out of order.
    static func rank(title: String, query: String) -> Int? {
        let titleLower = title.lowercased()
        let queryLower = query.lowercased()
        guard !queryLower.isEmpty else { return nil }
        if titleLower == queryLower { return 0 }
        if titleLower.hasPrefix(queryLower) { return 1 }
        if titleLower.contains(queryLower) { return 2 }

        // "wolf wall" → "The Wolf of Wall Street". Each query word has to consume a *different*
        // title word, or "the the" would match anything containing one "the".
        let queryWords = words(in: queryLower)
        guard queryWords.count >= 2 else { return nil }
        var remaining = words(in: titleLower)
        for word in queryWords {
            guard let index = remaining.firstIndex(where: { $0.hasPrefix(word) }) else {
                return nil
            }
            remaining.remove(at: index)
        }
        return 3
    }

    /// Anything that is not a letter or a digit separates words, so punctuation and apostrophes
    /// do not hide a match.
    static func words(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The strip contents, best match first.
    ///
    /// **Ties keep the order they arrived in**, which is the addon's own relevance order. Sorting
    /// equal ranks alphabetically is the mistake upstream records: it put five titles ahead of
    /// *Jurassic Park* for "juras", past the few completions a television keyboard shows.
    static func ranked(
        names: [String], query: String, limit: Int = maximum
    ) -> [String] {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0.lowercased()).inserted }
        return unique
            .enumerated()
            .compactMap { position, name in
                rank(title: name, query: query).map { (name: name, rank: $0, position: position) }
            }
            // `sorted(by:)` is not stable, so the arrival position is carried and compared rather
            // than relied on. This is exactly the tie upstream got wrong.
            .sorted { ($0.rank, $0.position) < ($1.rank, $1.position) }
            .prefix(limit)
            .map(\.name)
    }

    /// Every catalog's titles, one position at a time: each catalog's first, then each one's
    /// second, and so on.
    ///
    /// Concatenating instead would let whichever addon answered first fill the strip, so the
    /// suggestions would depend on network timing rather than on relevance.
    static func merged(byCatalog catalogs: [[String]]) -> [String] {
        let depth = catalogs.map(\.count).max() ?? 0
        var seen = Set<String>()
        var merged: [String] = []
        for position in 0..<depth {
            for catalog in catalogs where position < catalog.count {
                let name = catalog[position]
                guard seen.insert(name.lowercased()).inserted else { continue }
                merged.append(name)
            }
        }
        return merged
    }
}
