import Foundation
import TVServices

/// Dynamic Apple TV Top Shelf content.  The app publishes a tiny snapshot whenever watch
/// progress changes; the extension then has no network dependency and can answer tvOS quickly
/// while the main app is suspended.
final class NuvioTopShelfProvider: TVTopShelfContentProvider {
    private static let appGroupIdentifier = "group.com.nuvio.tvos"
    private static let defaultsKey = "topshelf.snapshot.v1"

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let entries = loadSnapshot().entries
        guard !entries.isEmpty else { return nil }

        let items = entries.compactMap { entry -> TVTopShelfItem? in
            guard let detailURL = URL(string: entry.detailURL) else { return nil }
            let item = TVTopShelfItem(identifier: entry.id)
            item.displayAction = TVTopShelfAction(url: detailURL)
            if let playURL = URL(string: entry.playURL) {
                item.playAction = TVTopShelfAction(url: playURL)
            }
            if let artwork = entry.artworkURL.flatMap(URL.init(string:)) {
                item.setImageURL(artwork, for: [.screenScale1x, .screenScale2x])
            }
            return item
        }
        guard !items.isEmpty else { return nil }
        return TVTopShelfInsetContent(items: items)
    }

    private func loadSnapshot() -> Snapshot {
        let defaults = UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return Snapshot(entries: []) }
        return snapshot
    }

    private struct Snapshot: Decodable {
        var entries: [Entry]
    }

    private struct Entry: Decodable {
        var id: String
        var title: String
        var subtitle: String?
        var artworkURL: String?
        var detailURL: String
        var playURL: String
    }
}
