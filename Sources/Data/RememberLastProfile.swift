import Foundation

/// The one place the "remember last profile" key and default are written.
///
/// It had two of each, which is how a switch came to lie about itself. `SettingsStore` defaulted
/// it on; `ProfileStore` — which reads straight from `UserDefaults`, because the settings graph is
/// built per profile and does not exist that early in launch — defaulted it off. On a fresh
/// install the Advanced screen showed the switch on and every launch went to "Who's watching?"
/// anyway.
///
/// Off is the correct default and the one upstream has: a household with several profiles is
/// meant to be asked.
enum RememberLastProfile {
    /// Upstream's name. Ours was `remember_last_profile`, which `PreferenceStore`'s own comment
    /// promises will match Android's so the sync path stays wire-compatible — and did not, so a
    /// viewer syncing between the two apps silently lost this choice in one direction.
    static let key = "remember_last_profile_enabled"

    /// What we called it before. Read, never written: somebody who already set it keeps it.
    static let legacyKey = "remember_last_profile"

    static let defaultValue = false

    /// Resolves from whatever is stored, preferring the current key.
    ///
    /// Both may be present at once — a device that had set the old key and then synced a blob
    /// carrying the new one. The new key wins, because it is the one Android wrote.
    static func resolve(current: Any?, legacy: Any?) -> Bool {
        if let current = current as? Bool { return current }
        if let legacy = legacy as? Bool { return legacy }
        return defaultValue
    }

    /// The `UserDefaults` name for a namespace, for readers that cannot go through a store.
    static func defaultsKey(_ name: String, namespace: String = "app") -> String {
        "\(namespace).\(name)"
    }
}
