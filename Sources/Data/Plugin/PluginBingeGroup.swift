import Foundation

/// A `bingeGroup` for plugin streams, which carry none of their own. Port of upstream's
/// `pluginBingeGroup` / `indexOfPluginBingeMatch` (`Plugin.kt`, 1.1.0-beta.10).
///
/// Without it, next-episode auto-play had nothing to hold a plugin source by. Plugin links are
/// mostly HLS or opaque CDN paths, so the filename rule in `NextEpisodeSourceMatch` finds nothing
/// either, and the next episode came from whatever ranked first: another provider, another
/// quality, another language.
///
/// Format, byte for byte upstream's, because watch parties carry `bingeGroup` between the two
/// apps: `local-plugin-{scraperId}|{sorted identity tokens}`. The tokens come from the fields a
/// plugin fills in itself (name, title, language, quality). Episode-specific words are *not*
/// stripped here; the matcher drops whatever the next episode's own results no longer share.
enum PluginBingeGroup {
    static let prefix = "local-plugin-"
    private static let separator: Character = "|"

    static func make(
        scraperId: String,
        name: String? = nil,
        title: String? = nil,
        language: String? = nil,
        quality: String? = nil
    ) -> String {
        let tokens = tokenize([name, title, language, quality])
        guard !tokens.isEmpty else { return prefix + scraperId }
        return prefix + scraperId + String(separator) + tokens.joined(separator: " ")
    }

    static func scraperId(of group: String?) -> String? {
        let value = (group ?? "").trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix(prefix) else { return nil }
        let rest = value.dropFirst(prefix.count)
        let id = rest.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? ""
        return id.isEmpty ? nil : id
    }

    /// The index of the next-episode candidate that continues `target`, or nil.
    ///
    /// Tokens every candidate shares are that episode's boilerplate; tokens of the saved choice
    /// that no candidate has were episode-specific. What is left is the plugin's own variant. The
    /// resolution that was playing has to be present — a higher quality listed first is a
    /// different variant, not a match — and a lone candidate, having no siblings to separate a
    /// title from a variant, matches whenever that resolution is still there.
    static func indexOfMatch(target: String?, candidates: [String?]) -> Int? {
        guard let targetId = scraperId(of: target) else { return nil }
        let indexed: [(index: Int, tokens: Set<String>)] = candidates.enumerated().compactMap { index, group in
            scraperId(of: group) == targetId ? (index, tokens(of: group)) : nil
        }
        guard let first = indexed.first else { return nil }
        let saved = tokens(of: target)
        if saved.isEmpty { return first.index }
        let savedResolution = Set(saved.filter(isResolution))
        if indexed.count == 1 {
            return savedResolution.isSubset(of: first.tokens) ? first.index : nil
        }

        let sets = indexed.map(\.tokens)
        let union = sets.reduce(Set<String>()) { $0.union($1) }
        let shared = sets.dropFirst().reduce(sets[0]) { $0.intersection($1) }
        let distinctive = saved.intersection(union).subtracting(shared)
        let availableResolution = savedResolution.intersection(union)
        if !savedResolution.isEmpty, availableResolution.isEmpty { return nil }

        let eligible = indexed.filter { availableResolution.isSubset(of: $0.tokens) }
        guard !eligible.isEmpty else { return nil }
        let labelDistinctive = distinctive.subtracting(savedResolution)
        let fullLabel = eligible.filter { labelDistinctive.isSubset(of: $0.tokens) }
        if !fullLabel.isEmpty {
            // Closest variant: fewest tokens of its own beyond the shared boilerplate, then order.
            return fullLabel.min {
                let left = $0.tokens.subtracting(shared).count, right = $1.tokens.subtracting(shared).count
                return left != right ? left < right : $0.index < $1.index
            }?.index
        }

        let scored = eligible.compactMap { candidate -> (index: Int, words: Int, total: Int)? in
            let matched = labelDistinctive.intersection(candidate.tokens)
            guard !matched.isEmpty else { return nil }
            return (candidate.index, matched.filter { $0.contains(where: \.isLetter) }.count, matched.count)
        }
        // `maxWithOrNull(compareBy(words, total))` replaces only on a strictly greater entry, so
        // the first of equal maxima wins; so does it here.
        var best: (index: Int, words: Int, total: Int)?
        for entry in scored {
            if let current = best, !((current.words, current.total) < (entry.words, entry.total)) { continue }
            best = entry
        }
        return best?.index
    }

    static func matches(candidate: String?, target: String?) -> Bool {
        let left = (candidate ?? "").trimmingCharacters(in: .whitespaces)
        let right = (target ?? "").trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || indexOfMatch(target: right, candidates: [left]) != nil
    }

    // MARK: Tokens

    private static func tokens(of group: String?) -> Set<String> {
        let value = (group ?? "").trimmingCharacters(in: .whitespaces)
        guard let cut = value.firstIndex(of: separator) else { return [] }
        let payload = value[value.index(after: cut)...]
        return Set(payload.split(separator: " ").map { canonical(String($0)) }.filter { !$0.isEmpty })
    }

    /// Lower-cased runs of letters and digits, de-duplicated and sorted.
    static func tokenize(_ parts: [String?]) -> [String] {
        var tokens = Set<String>()
        for part in parts {
            guard let part, !part.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var current = ""
            for character in part.lowercased() {
                if character.isLetter || character.isNumber {
                    current.append(character)
                } else if !current.isEmpty {
                    let token = canonical(current)
                    if !token.isEmpty { tokens.insert(token) }
                    current = ""
                }
            }
            if !current.isEmpty {
                let token = canonical(current)
                if !token.isEmpty { tokens.insert(token) }
            }
        }
        return tokens.sorted()
    }

    private static let resolutionHeights: Set<Int> = [360, 480, 540, 576, 720, 800, 900, 1080, 1440, 2160, 4320]

    private static func isResolution(_ token: String) -> Bool {
        if token.allSatisfy(\.isNumber) {
            return Int(token).map(resolutionHeights.contains) ?? false
        }
        if token.count >= 2, token.last == "k", token.dropLast().allSatisfy(\.isNumber) {
            return Int(token.dropLast()).map { [1, 2, 4, 8].contains($0) } ?? false
        }
        return false
    }

    /// `1080p` and `1080` are the same token.
    private static func canonical(_ token: String) -> String {
        let digits = token.prefix { $0.isNumber }.count
        guard digits > 0 else { return token }
        if digits == token.count { return String(token.prefix(digits)) }
        if digits == token.count - 1, token.last == "p" { return String(token.prefix(digits)) }
        return token
    }
}

/// Provider headings inside a repository section. Port of upstream's `StreamProviderGrouping`
/// (1.1.0-beta.10): with `group_streams_by_repository` on, one repository's scrapers shared a
/// single section, interleaved, with nothing saying which provider a row came from.
enum PluginProviderHeading {
    /// Rows of one section, each provider's together, providers in name order, each provider's
    /// own order kept. Rows with no provider (a section that is a single scraper) stay as they are.
    static func grouped(_ streams: [Stream]) -> [Stream] {
        guard streams.contains(where: { $0.pluginSourceName?.nilIfBlank != nil }) else { return streams }
        var order: [String] = []
        var buckets: [String: [Stream]] = [:]
        for stream in streams {
            let key = stream.pluginSourceName?.nilIfBlank ?? stream.addonName
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(stream)
        }
        return order
            .sorted { $0.lowercased() < $1.lowercased() }
            .flatMap { buckets[$0] ?? [] }
    }

    /// The heading to draw above `stream`, when it starts a new provider within its section.
    static func heading(for stream: Stream, after previous: Stream?) -> String? {
        guard let name = stream.pluginSourceName?.nilIfBlank, name != stream.addonName else { return nil }
        if let previous, previous.addonName == stream.addonName, previous.pluginSourceName == name {
            return nil
        }
        return name
    }
}
