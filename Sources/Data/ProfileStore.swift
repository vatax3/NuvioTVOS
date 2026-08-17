import Foundation
import CryptoKit
import Observation

// MARK: - Scope

/// Decides where a store's data lives. Exactly one profile is active at a time, so the scope is
/// read from a single global rather than threaded through every store's constructor — that also
/// means a store created during view initialisation cannot miss it.
enum ProfileScope {
    enum Storage {
        /// Per-profile: library, progress, addons, settings.
        case profile
        /// Shared across profiles: the profile list itself.
        case global
    }

    static let primaryProfileId = "primary"

    @ObservationIgnored private static let activeKey = "nuvio.active_profile_id"

    static var activeProfileId: String {
        UserDefaults.standard.string(forKey: activeKey) ?? primaryProfileId
    }

    static func activate(_ profileId: String) {
        UserDefaults.standard.set(profileId, forKey: activeKey)
    }

    /// The primary profile deliberately keeps the original, unprefixed keys and paths: its
    /// preference names stay wire-compatible with the Android app, and an install that never
    /// creates a second profile is byte-identical to one from before profiles existed.
    static var isPrimaryActive: Bool { activeProfileId == primaryProfileId }

    static var storageSubdirectory: String? {
        isPrimaryActive ? nil : "profiles/\(activeProfileId)"
    }

    static var preferenceKeyPrefix: String {
        isPrimaryActive ? "" : "profile.\(activeProfileId)."
    }

    /// Wipes everything belonging to one profile — used when it is deleted.
    static func eraseStorage(forProfileId profileId: String) {
        guard profileId != primaryProfileId else { return }

        let defaults = UserDefaults.standard
        let prefix = "profile.\(profileId)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }

        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("Nuvio", isDirectory: true)
            .appendingPathComponent("profiles/\(profileId)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Model

struct Profile: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// SF Symbol shown on the switcher tile.
    var symbol: String
    /// Accent applied to the tile, as a hex string so it survives encoding.
    var tintHex: String
    /// Four-digit lock. Stored hashed — a profile PIN keeps a household member out of someone
    /// else's library, and it should not be readable from the preferences file either way.
    var pinHash: String?
    /// Restricted profiles cannot reach the settings that would let them undo the restriction.
    var isRestricted: Bool
    var createdAt: Date

    var isLocked: Bool { pinHash != nil }

    static let availableSymbols = [
        "person.fill", "person.2.fill", "figure.child", "star.fill",
        "gamecontroller.fill", "popcorn.fill", "pawprint.fill", "leaf.fill"
    ]

    static let availableTints = [
        "#E50914", "#1E88E5", "#8E44AD", "#2ECC71", "#F39C12", "#EC407A", "#00ACC1", "#FFFFFF"
    ]
}

// MARK: - Store

/// The profile list plus the active selection. Deliberately global: switching profiles rebuilds
/// every other store, so this one cannot itself be per-profile.
@Observable
@MainActor
final class ProfileStore {
    private(set) var profiles: [Profile] = []
    private(set) var activeProfileId: String = ProfileScope.activeProfileId
    /// True while a locked profile has not yet been unlocked in this session.
    private(set) var isLocked = false

    private let file = JSONFileStore<[Profile]>(filename: "profiles.json", scope: .global)

    init() {
        profiles = file.load() ?? []
        if profiles.isEmpty {
            profiles = [
                Profile(
                    id: ProfileScope.primaryProfileId,
                    name: "Me",
                    symbol: "person.fill",
                    tintHex: "#E50914",
                    pinHash: nil,
                    isRestricted: false,
                    createdAt: Date()
                )
            ]
            persist()
        }
        // A profile deleted on another launch must not stay selected.
        if !profiles.contains(where: { $0.id == activeProfileId }) {
            activeProfileId = ProfileScope.primaryProfileId
            ProfileScope.activate(activeProfileId)
        }
        isLocked = activeProfile?.isLocked ?? false
    }

    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileId }
    }

    var hasMultipleProfiles: Bool { profiles.count > 1 }

    // MARK: Switching

    /// Returns false when the target needs a PIN, so the caller can present the keypad.
    @discardableResult
    func activate(_ profile: Profile, unlocked: Bool = false) -> Bool {
        if profile.isLocked && !unlocked {
            return false
        }
        ProfileScope.activate(profile.id)
        activeProfileId = profile.id
        isLocked = false
        return true
    }

    func unlock(_ profile: Profile, pin: String) -> Bool {
        guard let hash = profile.pinHash, hash == Self.hash(pin) else { return false }
        return activate(profile, unlocked: true)
    }

    func verifyPin(_ pin: String, for profile: Profile) -> Bool {
        guard let hash = profile.pinHash else { return true }
        return hash == Self.hash(pin)
    }

    // MARK: Editing

    func add(name: String, symbol: String, tintHex: String, pin: String?, isRestricted: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles.append(Profile(
            id: UUID().uuidString,
            name: trimmed,
            symbol: symbol,
            tintHex: tintHex,
            pinHash: pin.flatMap { $0.isEmpty ? nil : Self.hash($0) },
            isRestricted: isRestricted,
            createdAt: Date()
        ))
        persist()
    }

    func update(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persist()
    }

    func setPin(_ pin: String?, for profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].pinHash = pin.flatMap { $0.isEmpty ? nil : Self.hash($0) }
        persist()
    }

    /// The primary profile cannot be deleted — it owns the unprefixed storage.
    func delete(_ profile: Profile) {
        guard profile.id != ProfileScope.primaryProfileId else { return }
        profiles.removeAll { $0.id == profile.id }
        ProfileScope.eraseStorage(forProfileId: profile.id)
        if activeProfileId == profile.id {
            activeProfileId = ProfileScope.primaryProfileId
            ProfileScope.activate(activeProfileId)
        }
        persist()
    }

    private func persist() { file.save(profiles) }

    /// SHA-256 of the PIN. Not a defence against an attacker with the device — it stops the PIN
    /// being visible to anyone who opens the preferences file, which is the actual threat here.
    private static func hash(_ pin: String) -> String {
        let salted = Data(("nuvio-profile-pin:" + pin).utf8)
        return SHA256.hash(data: salted).map { String(format: "%02x", $0) }.joined()
    }
}
