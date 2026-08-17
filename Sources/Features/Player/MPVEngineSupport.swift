import Foundation

/// Decides when a source has to go through MPV regardless of the viewer's engine preference.
///
/// AVFoundation has no Matroska demuxer and never gained one, so an `.mkv` handed to it fails
/// with an opaque error. Rather than surface that, Nuvio routes those containers to MPV — the
/// setting picks the engine for everything AVFoundation *can* open.
enum MPVEngineSupport {
    /// False when the app was built without the MPVKit package, in which case every source has
    /// to go through AVFoundation and the engine setting is inert.
    static var isAvailable: Bool {
        #if canImport(Libmpv)
        return true
        #else
        return false
        #endif
    }

    /// Containers AVFoundation cannot demux. Extension-based because a debrid link exposes the
    /// filename and nothing has been fetched yet at this point.
    private static let unsupportedExtensions: Set<String> = [
        "mkv", "avi", "flv", "wmv", "ts", "m2ts", "mts", "vob", "ogm", "rmvb", "divx", "webm"
    ]

    /// A debrid provider hands back links like `/download/<token>` with the container nowhere in
    /// the path, so the addon-supplied filename is checked as well. Neither is authoritative —
    /// `PlayerView` also falls back to MPV if AVFoundation refuses the source outright.
    static func requiresMPV(url: String, filename: String? = nil) -> Bool {
        if let filename, hasUnsupportedExtension(filename) { return true }
        guard let components = URLComponents(string: url) else { return false }
        // Query strings on debrid links carry their own dots; only the path decides.
        return hasUnsupportedExtension(components.path)
    }

    private static func hasUnsupportedExtension(_ value: String) -> Bool {
        let lowered = value.lowercased()
        guard let dot = lowered.lastIndex(of: ".") else { return false }
        let ext = String(lowered[lowered.index(after: dot)...])
        return unsupportedExtensions.contains(ext)
    }
}
