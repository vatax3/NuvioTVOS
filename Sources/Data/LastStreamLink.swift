import Foundation

/// The link a title last played from, so reopening it within a few hours plays it again
/// directly. Port of upstream's `stream_reuse_last_link_enabled` / `StreamLinkCacheDataStore`.
///
/// This was ported once and removed in August as a setting nothing read (a6aff47); nothing
/// recorded the decision, so the 1.1.0-beta.11 pass found the gap. What it stores now includes
/// what upstream's beta.10 fix (7242ff8b) added: the addon, its logo and the description. Without
/// them a reused link played with an empty stream-info panel and no current-source marker.
struct LastStreamLink: Codable, Equatable, Sendable {
    var url: String
    var streamName: String
    var filename: String?
    var headers: [String: String]
    var addonName: String?
    var addonLogo: String?
    var description: String?
    var bingeGroup: String?
    /// The row it was chosen from, so the Sources panel marks the same row as current.
    var sourceStableKey: String?
    var cachedAt: Date
}

/// Per profile: `JSONFileStore` scopes the file to the profile active when it is built.
@MainActor
enum LastStreamLinkStore {
    /// Upstream's range for `stream_reuse_last_link_cache_hours`.
    nonisolated static let hoursRange = 1...168
    private static let limit = 200

    static func key(contentType: String, videoId: String) -> String {
        "\(contentType.lowercased())|\(videoId)"
    }

    private static var file: JSONFileStore<[String: LastStreamLink]> {
        JSONFileStore(filename: "last-stream-links.json")
    }

    static func save(_ link: LastStreamLink, contentType: String, videoId: String) {
        var all = file.load() ?? [:]
        all[key(contentType: contentType, videoId: videoId)] = link
        // Nothing older than the longest window can ever be reused.
        let floor = link.cachedAt.addingTimeInterval(-Double(hoursRange.upperBound) * 3_600)
        all = all.filter { $0.value.cachedAt >= floor }
        if all.count > limit {
            let kept = all.sorted { $0.value.cachedAt > $1.value.cachedAt }.prefix(limit)
            all = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        file.save(all)
    }

    static func valid(
        contentType: String, videoId: String, maxAgeHours: Int, now: Date = Date()
    ) -> LastStreamLink? {
        guard let link = file.load()?[key(contentType: contentType, videoId: videoId)] else { return nil }
        return isFresh(link, maxAgeHours: maxAgeHours, now: now) ? link : nil
    }

    nonisolated static func isFresh(_ link: LastStreamLink, maxAgeHours: Int, now: Date) -> Bool {
        let hours = min(hoursRange.upperBound, max(hoursRange.lowerBound, maxAgeHours))
        let age = now.timeIntervalSince(link.cachedAt)
        return age >= 0 && age <= Double(hours) * 3_600
            && !link.url.isEmpty && !link.streamName.isEmpty
    }
}
