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

    static func requiresMPV(url: String) -> Bool {
        guard let components = URLComponents(string: url) else { return false }
        // Query strings on debrid links carry their own dots; only the path decides.
        let path = components.path.lowercased()
        guard let dot = path.lastIndex(of: ".") else { return false }
        let ext = String(path[path.index(after: dot)...])
        return unsupportedExtensions.contains(ext)
    }
}
