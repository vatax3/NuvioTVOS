import Foundation
import Observation

/// Base for the settings stores.
///
/// NuvioTV spreads ~280 preferences across a dozen Jetpack DataStores. Declaring each one as a
/// separate `@Observable` stored property with a `didSet` would be thousands of lines of
/// boilerplate, so values live in one observed dictionary and each setting is a thin computed
/// property over it. Reads are still tracked by Observation because they all touch `storage`.
///
/// Keys deliberately match the Android preference names, so an import/sync path stays
/// wire-compatible with the phone and TV apps.
@Observable
@MainActor
class PreferenceStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let namespace: String
    private var storage: [String: Any] = [:]

    init(namespace: String, defaults: UserDefaults = .standard) {
        self.namespace = namespace
        self.defaults = defaults
        // Hydrate synchronously so the first frame renders the user's real configuration.
        let prefix = "\(namespace)."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            storage[String(key.dropFirst(prefix.count))] = value
        }
    }

    private func persist(_ key: String, _ value: Any?) {
        storage[key] = value
        if let value {
            defaults.set(value, forKey: "\(namespace).\(key)")
        } else {
            defaults.removeObject(forKey: "\(namespace).\(key)")
        }
    }

    // MARK: Typed accessors

    func bool(_ key: String, default fallback: Bool) -> Bool {
        storage[key] as? Bool ?? fallback
    }

    func setBool(_ key: String, _ value: Bool) { persist(key, value) }

    func int(_ key: String, default fallback: Int) -> Int {
        storage[key] as? Int ?? fallback
    }

    func setInt(_ key: String, _ value: Int) { persist(key, value) }

    func double(_ key: String, default fallback: Double) -> Double {
        storage[key] as? Double ?? fallback
    }

    func setDouble(_ key: String, _ value: Double) { persist(key, value) }

    func string(_ key: String, default fallback: String) -> String {
        storage[key] as? String ?? fallback
    }

    func setString(_ key: String, _ value: String) { persist(key, value) }

    func stringList(_ key: String, default fallback: [String] = []) -> [String] {
        storage[key] as? [String] ?? fallback
    }

    func setStringList(_ key: String, _ value: [String]) { persist(key, value) }

    func option<T: SettingsOption>(_ key: String, default fallback: T) -> T {
        guard let raw = storage[key] as? String, let value = T(rawValue: raw) else { return fallback }
        return value
    }

    func setOption<T: SettingsOption>(_ key: String, _ value: T) { persist(key, value.rawValue) }

    func optionList<T: SettingsOption>(_ key: String, default fallback: [T]) -> [T] {
        guard let raws = storage[key] as? [String] else { return fallback }
        return raws.compactMap { T(rawValue: $0) }
    }

    func setOptionList<T: SettingsOption>(_ key: String, _ value: [T]) {
        persist(key, value.map(\.rawValue))
    }

    /// JSON-backed slot for the composite values (stream preferences, badge rules).
    func codable<T: Codable>(_ key: String, default fallback: T) -> T {
        guard let data = storage[key] as? Data,
              let decoded = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return decoded
    }

    func setCodable<T: Codable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        persist(key, data)
    }

    /// Restores every key in this namespace to its built-in default.
    func resetAll() {
        let prefix = "\(namespace)."
        for key in storage.keys {
            defaults.removeObject(forKey: prefix + key)
        }
        storage.removeAll()
    }
}
