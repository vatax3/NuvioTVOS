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
        // Non-primary profiles get their own key space; the primary keeps the bare names.
        self.namespace = ProfileScope.preferenceKeyPrefix + namespace
        self.defaults = defaults
        // Hydrate synchronously so the first frame renders the user's real configuration.
        let prefix = "\(self.namespace)."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            storage[String(key.dropFirst(prefix.count))] = value
        }
    }

    /// Credential keys are device-local, excluded from account sync, and migrated away from
    /// `UserDefaults` on first access.
    var secureKeys: Set<String> { [] }

    private func persist(_ key: String, _ value: Any?) {
        storage[key] = value
        if let value {
            defaults.set(value, forKey: "\(namespace).\(key)")
        } else {
            defaults.removeObject(forKey: "\(namespace).\(key)")
        }
        if !isApplyingSyncedValues {
            // Stamps the local settings revision so account sync can tell which side is newer.
            // Suppressed while applying a pulled blob, which would otherwise look like a change.
            defaults.set(Date().timeIntervalSince1970, forKey: PreferenceStore.syncStampKey)
        }
    }

    static let syncStampKey = "nuvio.settings_updated_at"
    @ObservationIgnored private var isApplyingSyncedValues = false

    // MARK: Sync

    /// Every set value, for the account settings blob. Only scalars and string arrays are
    /// exported — those are the only shapes the typed accessors ever write.
    func exportForSync() -> [String: AnyJSONValue] {
        var out: [String: AnyJSONValue] = [:]
        for (key, value) in storage {
            guard !secureKeys.contains(key) else { continue }
            switch value {
            case let bool as Bool: out[key] = .bool(bool)
            case let int as Int: out[key] = .int(int)
            case let double as Double: out[key] = .double(double)
            case let string as String: out[key] = .string(string)
            case let list as [String]: out[key] = .array(list.map { .string($0) })
            case let data as Data:
                // Composite slots (`setCodable`) hold JSON bytes. Carry them as their decoded
                // JSON so the other platform reads a real object, not an opaque blob.
                if let json = try? JSONDecoder().decode(AnyJSONValue.self, from: data) {
                    out[key] = json
                }
            default: continue
            }
        }
        return out
    }

    /// Applies a synced blob. Values go through `persist` so both the observed dictionary and
    /// UserDefaults stay in step and the UI updates immediately.
    func importFromSync(_ values: [String: AnyJSON]) {
        isApplyingSyncedValues = true
        defer { isApplyingSyncedValues = false }
        for (key, value) in values {
            guard !secureKeys.contains(key) else { continue }
            switch value {
            case .bool(let bool):
                persist(key, bool)
            case .number(let number):
                // JSON has one number type; keep integral values as Int so `int(_:)` reads them.
                if number == number.rounded(), abs(number) < 9e15 {
                    persist(key, Int(number))
                } else {
                    persist(key, number)
                }
            case .string(let string):
                persist(key, string)
            case .array(let items):
                // The only arrays written locally are string lists.
                let strings = items.compactMap { item -> String? in
                    if case .string(let value) = item { return value }
                    return nil
                }
                guard strings.count == items.count else { continue }
                persist(key, strings)
            case .object:
                // Round-trips a composite slot back into the Data form `codable(_:)` reads.
                guard let data = try? JSONEncoder().encode(value) else { continue }
                persist(key, data)
            case .null:
                continue
            }
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

    func secureString(_ key: String, default fallback: String) -> String {
        precondition(secureKeys.contains(key), "Only declared secure keys may use secureString")
        let namespacedKey = "\(namespace).\(key)"
        if let legacy = storage[key] as? String {
            KeychainStore.setString(legacy, forKey: namespacedKey)
            defaults.removeObject(forKey: namespacedKey)
            return legacy
        }
        if let value = KeychainStore.string(forKey: namespacedKey) {
            storage[key] = value
            return value
        }
        return fallback
    }

    func setSecureString(_ key: String, _ value: String) {
        precondition(secureKeys.contains(key), "Only declared secure keys may use setSecureString")
        storage[key] = value
        let namespacedKey = "\(namespace).\(key)"
        KeychainStore.setString(value, forKey: namespacedKey)
        defaults.removeObject(forKey: namespacedKey)
    }

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
        for key in secureKeys {
            KeychainStore.removeValue(forKey: prefix + key)
        }
        storage.removeAll()
    }
}
