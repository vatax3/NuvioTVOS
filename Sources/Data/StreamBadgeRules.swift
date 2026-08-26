import Foundation

/// Badge rules imported from a JSON file the viewer points us at.
///
/// `Stream.badges` has existed in the model since the first port and nothing has ever written to
/// it. This is what writes to it: a set of named regular expressions, each with its own colours
/// and optional logo, matched against everything an addon said about a stream. It is how a source
/// list gets to say "4K Remux · ATMOS · HDR10+" in the viewer's own vocabulary rather than ours.
///
/// The file format is upstream's, so a badge pack written for Android TV imports here unchanged.
enum StreamBadgeRuleLimits {
    /// Three imports, one active. Upstream's cap, and it exists because the rules are applied to
    /// every row of every source list — an unbounded set of user-authored regexes is a way to
    /// make the source list slow with no way to tell why.
    static let importLimit = 3
}

struct StreamBadgeFilter: Codable, Hashable, Sendable, Identifiable {
    var id: String = ""
    var groupId: String = ""
    var name: String = ""
    var pattern: String = ""
    var imageURL: String = ""
    var isEnabled: Bool = true
    var tagColor: String = ""
    var tagStyle: String = ""
    var textColor: String = ""
    var borderColor: String = ""

    var badge: StreamBadge {
        StreamBadge(
            name: name, imageURL: imageURL, tagColor: tagColor,
            tagStyle: tagStyle, textColor: textColor, borderColor: borderColor
        )
    }
}

struct StreamBadgeGroup: Codable, Hashable, Sendable, Identifiable {
    var id: String = ""
    var name: String = ""
    var color: String = ""
    var isExpanded: Bool = true
}

struct StreamBadgeImport: Codable, Hashable, Sendable, Identifiable {
    var sourceUrl: String = ""
    var filters: [StreamBadgeFilter] = []
    var groups: [StreamBadgeGroup] = []
    var isActive: Bool = true

    var id: String { sourceUrl }
    var enabledFilterCount: Int { filters.count(where: \.isEnabled) }
}

struct StreamBadgeRules: Codable, Hashable, Sendable {
    var imports: [StreamBadgeImport] = []

    var hasImport: Bool { !imports.isEmpty }

    /// The one whose filters are applied. Falls back to the first, so a set that somehow lost its
    /// active flag still draws badges rather than silently drawing none.
    var activeImport: StreamBadgeImport? {
        imports.first { $0.isActive } ?? imports.first
    }

    var enabledFilterCount: Int { activeImport?.enabledFilterCount ?? 0 }

    /// Drops empty imports, collapses duplicates by URL, enforces the cap, and guarantees exactly
    /// one active import. Every mutation runs through here, so those are invariants rather than
    /// things each call site has to remember.
    func normalized() -> StreamBadgeRules {
        var kept: [StreamBadgeImport] = []
        for candidate in imports {
            var entry = candidate
            entry.sourceUrl = candidate.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.sourceUrl.isEmpty, !entry.filters.isEmpty else { continue }
            if let existing = kept.firstIndex(where: { $0.sourceUrl.caseInsensitiveCompare(entry.sourceUrl) == .orderedSame }) {
                kept[existing] = entry
            } else if kept.count < StreamBadgeRuleLimits.importLimit {
                kept.append(entry)
            }
        }
        guard !kept.isEmpty else { return StreamBadgeRules(imports: []) }

        let activeIndex = kept.firstIndex(where: \.isActive) ?? 0
        return StreamBadgeRules(
            imports: kept.enumerated().map { index, entry in
                var entry = entry
                entry.isActive = index == activeIndex
                return entry
            }
        )
    }

    /// Adds an import, or replaces the one already loaded from the same URL — re-importing a URL
    /// is how a pack is *updated*, so it must not stack up three copies of itself and hit the cap.
    func upserting(_ entry: StreamBadgeImport, activate: Bool = true) -> StreamBadgeRules {
        let url = entry.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return normalized() }

        var replacement = entry
        replacement.sourceUrl = url
        replacement.isActive = activate

        let matches = { (existing: StreamBadgeImport) in
            existing.sourceUrl.caseInsensitiveCompare(url) == .orderedSame
        }
        var next = imports.contains(where: matches)
            ? imports.map { matches($0) ? replacement : $0 }
            : imports + [replacement]

        if activate {
            next = next.map { existing in
                var existing = existing
                existing.isActive = matches(existing)
                return existing
            }
        }
        return StreamBadgeRules(imports: next).normalized()
    }

    func settingActive(_ sourceUrl: String) -> StreamBadgeRules {
        let url = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = { (existing: StreamBadgeImport) in
            existing.sourceUrl.caseInsensitiveCompare(url) == .orderedSame
        }
        guard !url.isEmpty, imports.contains(where: matches) else { return normalized() }
        return StreamBadgeRules(
            imports: imports.map { existing in
                var existing = existing
                existing.isActive = matches(existing)
                return existing
            }
        ).normalized()
    }

    func removing(_ sourceUrl: String) -> StreamBadgeRules {
        let url = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return StreamBadgeRules(
            imports: imports.filter { $0.sourceUrl.caseInsensitiveCompare(url) != .orderedSame }
        ).normalized()
    }

    /// Flips one filter of the active import without disturbing the others.
    func settingFilter(id: String, enabled: Bool) -> StreamBadgeRules {
        StreamBadgeRules(
            imports: imports.map { entry in
                guard entry.isActive else { return entry }
                var entry = entry
                entry.filters = entry.filters.map { filter in
                    guard filter.id == id else { return filter }
                    var filter = filter
                    filter.isEnabled = enabled
                    return filter
                }
                return entry
            }
        )
    }
}

// MARK: - Parsing

enum StreamBadgeRulesParser {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Tolerant by design: a pack is written by a third party, and one malformed entry in fifty
    /// should cost that entry rather than the import. A filter with no name or no pattern is the
    /// one thing that cannot be salvaged — it would draw a nameless badge on everything or
    /// nothing at all.
    static func parse(sourceUrl: String, payload: Data) throws -> StreamBadgeImport {
        let decoded: Payload
        do {
            decoded = try JSONDecoder().decode(Payload.self, from: payload)
        } catch {
            throw Failure(message: "This does not look like a badge file.")
        }

        let filters: [StreamBadgeFilter] = decoded.filters.compactMap { raw in
            let name = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pattern = raw.pattern?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, !pattern.isEmpty else { return nil }
            return StreamBadgeFilter(
                id: raw.id ?? "", groupId: raw.groupId ?? "", name: name, pattern: pattern,
                imageURL: raw.imageURL ?? "", isEnabled: raw.isEnabled ?? true,
                tagColor: raw.tagColor ?? "", tagStyle: raw.tagStyle ?? "",
                textColor: raw.textColor ?? "", borderColor: raw.borderColor ?? ""
            )
        }
        guard !filters.isEmpty else {
            throw Failure(message: "That file contains no usable badge rules.")
        }

        return StreamBadgeImport(
            sourceUrl: sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            filters: filters,
            groups: decoded.groups.map {
                StreamBadgeGroup(
                    id: $0.id ?? "", name: $0.name ?? "",
                    color: $0.color ?? "", isExpanded: $0.isExpanded ?? true
                )
            }
        )
    }

    private struct Payload: Decodable {
        var filters: [FilterPayload] = []
        var groups: [GroupPayload] = []
    }

    private struct FilterPayload: Decodable {
        var id: String?
        var groupId: String?
        var name: String?
        var pattern: String?
        var imageURL: String?
        var isEnabled: Bool?
        var tagColor: String?
        var tagStyle: String?
        var textColor: String?
        var borderColor: String?
    }

    private struct GroupPayload: Decodable {
        var id: String?
        var name: String?
        var color: String?
        var isExpanded: Bool?
    }
}

// MARK: - Matching

/// One filter with its expression compiled and a cheap pre-screen attached.
struct CompiledStreamBadgeFilter {
    let badge: StreamBadge
    let expression: NSRegularExpression
    /// A lowercase substring every match must contain. When a pattern is plain enough to yield
    /// one, a substring test rejects most candidates before the regex engine is asked — the rules
    /// run against every field of every row of every source list, so the cheap test is worth it.
    let literalHint: String?
}

enum StreamBadgeMatcher {
    private static let metaCharacters = Set(#"\[](){}*+?|^$."#)

    static func compile(_ rules: StreamBadgeRules) -> [CompiledStreamBadgeFilter] {
        guard rules.hasImport else { return [] }
        return rules.normalized().imports
            .filter(\.isActive)
            .flatMap(\.filters)
            .compactMap { filter in
                guard filter.isEnabled, !filter.name.isEmpty, !filter.pattern.isEmpty,
                      // A pattern the engine refuses is dropped, not fatal: one bad rule in an
                      // imported pack must not cost the viewer the other forty-nine.
                      let expression = try? NSRegularExpression(pattern: filter.pattern)
                else { return nil }
                return CompiledStreamBadgeFilter(
                    badge: filter.badge,
                    expression: expression,
                    literalHint: literalHint(for: filter.pattern)
                )
            }
    }

    /// The literal a pattern must contain, when it has one.
    static func literalHint(for pattern: String) -> String? {
        if pattern.count >= 2, !pattern.contains(where: metaCharacters.contains) {
            return pattern.lowercased()
        }
        // An alternation matches any of several literals, so no single one is required.
        if pattern.contains("|") { return nil }

        var stripped = pattern
        for token in [#"\b"#, "(?i)", "(?:", "(", ")"] {
            stripped = stripped.replacingOccurrences(of: token, with: "")
        }
        guard stripped.count >= 2, !stripped.contains(where: metaCharacters.contains) else {
            return nil
        }
        return stripped.lowercased()
    }

    /// Every piece of text an addon gave us about this stream, plus all of them joined.
    ///
    /// The join is not redundant: a pattern like `2160p.*ATMOS` is written expecting one string,
    /// and addons scatter those two facts across the title and the description.
    static func candidates(for stream: Stream, attributes: ParsedStreamAttributes?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let pieces: [String?] = [
            stream.behaviorHints?.filename,
            stream.name,
            stream.title,
            stream.description,
            stream.quality,
            attributes?.releaseGroup,
            attributes.map { $0.resolution.displayName },
            attributes.map { $0.quality.displayName },
            attributes.map { $0.encode.displayName },
            attributes.map { $0.visualTags.map(\.displayName).joined(separator: " ") },
            attributes.map { $0.audioTags.map(\.displayName).joined(separator: " ") },
            attributes.map { $0.audioChannels.map(\.displayName).joined(separator: " ") },
            stream.addonName
        ]
        for piece in pieces {
            let text = piece?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            out.append(text)
        }
        guard out.count > 1 else { return out }
        return out + [out.joined(separator: " ")]
    }

    /// The badges a stream earns, in filter order, deduplicated.
    static func badges(
        for stream: Stream,
        attributes: ParsedStreamAttributes?,
        filters: [CompiledStreamBadgeFilter]
    ) -> [StreamBadge] {
        guard !filters.isEmpty else { return [] }
        let candidates = candidates(for: stream, attributes: attributes)
        guard !candidates.isEmpty else { return [] }

        var seen = Set<String>()
        var out: [StreamBadge] = []
        for filter in filters where matches(filter, candidates) {
            // Two rules pointing at the same logo are the same badge wearing two names — showing
            // it twice is the bug the key exists to prevent.
            let key = filter.badge.imageURL.isEmpty ? filter.badge.name : filter.badge.imageURL
            guard seen.insert(key).inserted else { continue }
            out.append(filter.badge)
        }
        return out
    }

    private static func matches(_ filter: CompiledStreamBadgeFilter, _ candidates: [String]) -> Bool {
        for candidate in candidates {
            if let hint = filter.literalHint,
               candidate.range(of: hint, options: .caseInsensitive) == nil {
                continue
            }
            let range = NSRange(candidate.startIndex..., in: candidate)
            if filter.expression.firstMatch(in: candidate, range: range) != nil { return true }
        }
        return false
    }
}

// MARK: - Importing

enum StreamBadgeImporter {
    /// Fetches a badge pack and parses it.
    ///
    /// The URL comes from a phone on the local network and points anywhere, so the failures worth
    /// distinguishing are the ones a viewer can act on: a URL that is not one, a host that did not
    /// answer, and a file that answered but was not a badge pack.
    static func load(from urlString: String) async throws -> StreamBadgeImport {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            throw StreamBadgeRulesParser.Failure(message: "That is not a web address.")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await IntegrationHTTP.session.data(from: url)
        } catch {
            throw StreamBadgeRulesParser.Failure(message: "Could not reach that address.")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StreamBadgeRulesParser.Failure(message: "That address answered \(http.statusCode).")
        }

        return try StreamBadgeRulesParser.parse(sourceUrl: trimmed, payload: data)
    }
}
