import Foundation

/// Central entry point for copy that is shared by navigation and playback.  Keeping keys here
/// prevents the Apple TV client from silently drifting back to English-only literals as new
/// panels are added.
///
/// `text` and `format` live in `AppLanguage.swift`, next to the bundle they resolve against —
/// the interface language is chosen in the app, so the lookup is not always `Bundle.main`.
enum L10n {}
