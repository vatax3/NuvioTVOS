import Foundation
import os

/// Codable persistence for the stores, with the durability tvOS actually offers.
///
/// tvOS is not iOS here. An app gets almost no guaranteed local storage: `UserDefaults` is the
/// only store the system promises to keep (and caps at roughly 500 KB), while everything under
/// `Library` is purgeable — the system reclaims it whenever it wants the space back. There is no
/// Documents directory to fall back on.
///
/// So the two tiers are deliberate, not an optimisation:
///
/// - `.critical` — small state that must survive: which server, which session, which profiles.
///   Kept in `UserDefaults`, where it is safe. Losing any of it signs the viewer out and strands
///   them on a setup screen, which is exactly what a purge used to do.
/// - `.purgeable` — the library, watch progress, image caches, installed addons. Too big for the
///   `UserDefaults` budget, and it does not need that guarantee: account sync restores it.
///
/// The previous version put everything in Application Support and, when that failed to resolve,
/// silently fell back to `temporaryDirectory` — where the system wipes it between launches.
struct JSONFileStore<Value: Codable> {
    enum Durability {
        /// Survives whatever the system does. Budgeted, so keep it small.
        case critical
        /// Fast and unbounded, but the system may reclaim it. Must be reconstructible.
        case purgeable
    }

    private let url: URL?
    private let defaultsKey: String?
    /// Where builds before the durability split wrote. Read once, then migrated forward.
    private let legacyURL: URL?
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "JSONFileStore")

    /// Anything above this goes to disk regardless: `UserDefaults` is a property list read
    /// wholesale on every access, and filling it degrades the whole app, not just this store.
    private static var criticalByteBudget: Int { 128 * 1024 }

    /// `global` files (the profile list itself) live at the top level; everything else is
    /// scoped to the active profile so each one keeps its own library and progress.
    init(
        filename: String,
        scope: ProfileScope.Storage = .profile,
        durability: Durability = .purgeable
    ) {
        var scopedName = filename
        if case .profile = scope, let subdirectory = ProfileScope.storageSubdirectory {
            scopedName = "\(subdirectory)/\(filename)"
        }

        legacyURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nuvio", isDirectory: true)
            .appendingPathComponent(scopedName, isDirectory: false)

        switch durability {
        case .critical:
            defaultsKey = "nuvio.store.\(scopedName)"
            url = nil
        case .purgeable:
            defaultsKey = nil
            // Caches, not Application Support: on tvOS both are purgeable, and Caches is the
            // one Apple documents as the place to put this. Never `temporaryDirectory` — that
            // is cleared out from under a running app.
            let base = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first
            guard let base else {
                url = nil
                return
            }
            let directory = base
                .appendingPathComponent("Nuvio", isDirectory: true)
                .appendingPathComponent(scopedName, isDirectory: false)
                .deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            url = directory.appendingPathComponent(filename)
        }
    }

    func load() -> Value? {
        var data: Data?
        if let defaultsKey {
            data = UserDefaults.standard.data(forKey: defaultsKey)
        } else if let url, FileManager.default.fileExists(atPath: url.path) {
            data = try? Data(contentsOf: url)
        }

        // Nothing in the new home: an install that predates the durability split still has its
        // library, addons and session in Application Support. Read it there once and write it
        // forward, so upgrading does not look like the app forgot everything.
        var migrating = false
        if data == nil, let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) {
            data = try? Data(contentsOf: legacyURL)
            migrating = data != nil
        }

        guard let data else { return nil }
        do {
            let value = try JSONDecoder().decode(Value.self, from: data)
            if migrating { save(value) }
            return value
        } catch {
            log.error("Failed decoding \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ value: Value) {
        do {
            let data = try JSONEncoder().encode(value)
            if let defaultsKey {
                guard data.count <= Self.criticalByteBudget else {
                    log.error("\(name, privacy: .public) is \(data.count) bytes, over the durable budget")
                    return
                }
                UserDefaults.standard.set(data, forKey: defaultsKey)
                return
            }
            guard let url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Failed writing \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete() {
        if let defaultsKey {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private var name: String { defaultsKey ?? url?.lastPathComponent ?? "store" }
}
