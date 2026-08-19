import Foundation

/// Central entry point for copy that is shared by navigation and playback.  Keeping keys here
/// prevents the Apple TV client from silently drifting back to English-only literals as new
/// panels are added.  The catalogue deliberately starts with the always-visible shell/player
/// vocabulary and is extended screen by screen.
enum L10n {
    static func text(_ key: String, fallback: String? = nil) -> String {
        NSLocalizedString(key, bundle: .main, value: fallback ?? key, comment: "")
    }

    static func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        String(format: text(key, fallback: fallback), locale: .current, arguments: arguments)
    }
}
