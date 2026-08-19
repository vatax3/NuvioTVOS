import Foundation
import Security

/// Device-local storage for credentials and authenticated sessions.
/// Preferences can be exported as account settings; secrets must never take that path.
enum KeychainStore {
    private static let service = "com.nuvio.tvos.secure-storage"

    static func data(forKey key: String) -> Data? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ data: Data, forKey key: String) {
        let query = baseQuery(forKey: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func removeValue(forKey key: String) {
        SecItemDelete(baseQuery(forKey: key) as CFDictionary)
    }

    static func string(forKey key: String) -> String? {
        data(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setString(_ value: String, forKey key: String) {
        guard !value.isEmpty else {
            removeValue(forKey: key)
            return
        }
        set(Data(value.utf8), forKey: key)
    }

    /// Drops every secret this app owns. Used when signing out: the debrid keys and tracking
    /// tokens belong to the account that is leaving, not to the television.
    static func removeAll() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
    }

    private static func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

struct KeychainCodableStore<Value: Codable> {
    let key: String

    func load() -> Value? {
        guard let data = KeychainStore.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        KeychainStore.set(data, forKey: key)
    }

    func delete() {
        KeychainStore.removeValue(forKey: key)
    }
}
