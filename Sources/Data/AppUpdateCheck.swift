import Foundation

/// Whether a newer build has been published, read from the same sideloading feed AltStore uses.
///
/// The feed rather than the GitHub releases API for two reasons: it is already the artefact that
/// has to be correct for anyone to install an update at all, so a check that reads it fails
/// loudly if the feed is wrong; and it is a single small JSON file with no rate limit worth
/// worrying about.
///
/// Nothing here installs anything. tvOS has no route from an app to sideloading itself, so the
/// most this can honestly do is tell the viewer a newer build exists and where to get it.
enum AppUpdateCheck {
    static let feedURL = "https://raw.githubusercontent.com/vatax3/NuvioTVOS/main/altstore-source.json"

    struct Available: Equatable {
        var version: String
        var notes: String
        var downloadURL: String
    }

    /// Compares two dotted version strings numerically.
    ///
    /// Not a string compare: "1.0.9" sorts after "1.0.23" lexically, which would announce an
    /// update *backwards* for nine releases out of every ten.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(candidate)
        let right = components(current)
        for (a, b) in zip(left, right) where a != b { return a > b }
        return left.count > right.count && left.dropFirst(right.count).contains { $0 > 0 }
    }

    private static func components(_ version: String) -> [Int] {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        // Padded so "1.1" and "1.1.0" compare equal rather than the shorter one losing.
        return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
    }

    /// Reads the newest published version out of a feed payload.
    static func newest(in payload: Data) -> Available? {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: payload),
              let app = feed.apps.first,
              let newest = app.versions.first,
              !newest.version.isEmpty, !newest.downloadURL.isEmpty
        else { return nil }
        return Available(
            version: newest.version,
            notes: newest.localizedDescription ?? "",
            downloadURL: newest.downloadURL
        )
    }

    /// The update to announce, or nothing.
    static func available(in payload: Data, current: String) -> Available? {
        guard let newest = newest(in: payload), isNewer(newest.version, than: current) else {
            return nil
        }
        return newest
    }

    static func fetch(current: String) async -> Available? {
        guard let url = URL(string: feedURL),
              let (data, _) = try? await IntegrationHTTP.session.data(from: url)
        else { return nil }
        return available(in: data, current: current)
    }

    /// The running build's marketing version.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private struct Feed: Decodable {
        var apps: [App] = []
        struct App: Decodable {
            var versions: [Version] = []
        }
        struct Version: Decodable {
            var version: String = ""
            var downloadURL: String = ""
            var localizedDescription: String?
        }
    }
}
