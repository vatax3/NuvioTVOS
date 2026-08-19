import Foundation
import os

/// Returns the device to a blank slate when an account signs out.
///
/// A port of Android's `AccountLocalDataResetService`, and the behaviour matters more than the
/// mechanism: on the official app a television shows the signed-in account's content and
/// nothing else. Leaving the library, profiles, addons and debrid keys behind means the next
/// person to sign in inherits them, and — worse — that the previous account's saved titles and
/// watch history are still on screen while nobody is signed in at all.
///
/// Everything here is derived from a single fact about how this app stores things: it owns its
/// whole `UserDefaults` domain, one `Nuvio` directory in Caches and Application Support, and
/// one Keychain service. So the reset is "remove all of it", with an explicit list of what
/// survives, rather than an enumeration of stores that a future feature would silently escape.
@MainActor
enum AccountLocalDataReset {
    private static let log = Logger(subsystem: "com.nuvio.tvos", category: "AccountReset")

    /// The only things that outlive a sign-out. Both describe *which server to talk to*, not
    /// anything belonging to the account — without them the viewer could not sign back in, and
    /// on this build the publishable key is something they had to paste in by hand.
    private static let preservedDefaultsKeys = [
        "nuvio.store.nuvio-server.json"
    ]

    static func clearAfterSignOut() {
        let defaults = UserDefaults.standard
        let preserved = preservedDefaultsKeys.reduce(into: [String: Any]()) { kept, key in
            if let value = defaults.object(forKey: key) { kept[key] = value }
        }

        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in preserved {
            defaults.set(value, forKey: key)
        }

        let manager = FileManager.default
        for root in [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory] {
            guard let base = manager.urls(for: root, in: .userDomainMask).first else { continue }
            let directory = base.appendingPathComponent("Nuvio", isDirectory: true)
            do {
                if manager.fileExists(atPath: directory.path) {
                    try manager.removeItem(at: directory)
                }
            } catch {
                log.error("Could not remove \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Debrid keys, tracking tokens and the session itself.
        KeychainStore.removeAll()

        // The Top Shelf row, which is in the app-group container and so survives everything
        // above — Android clears its channel data on sign-out for the same reason.
        TopShelfSnapshotPublisher.clear()

        log.info("Local account data cleared")
    }
}
