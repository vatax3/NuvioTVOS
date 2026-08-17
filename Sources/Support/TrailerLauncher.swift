import UIKit

/// Trailers in the Stremio protocol are YouTube ids, and tvOS has no in-app way to play one:
/// AVPlayer cannot resolve a YouTube watch page and WKWebView does not exist on the platform.
/// The workable path is a hand-off to the YouTube tvOS app, which is what the button does.
enum TrailerLauncher {
    /// True when the YouTube app is installed and can take the hand-off.
    @MainActor
    static var isAvailable: Bool {
        guard let probe = URL(string: "youtube://") else { return false }
        return UIApplication.shared.canOpenURL(probe)
    }

    @MainActor
    static func open(youTubeId: String) {
        let candidates = [
            URL(string: "youtube://\(youTubeId)"),
            URL(string: "https://www.youtube.com/watch?v=\(youTubeId)")
        ].compactMap { $0 }

        for url in candidates where UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            return
        }
    }
}
