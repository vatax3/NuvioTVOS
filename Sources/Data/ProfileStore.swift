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

        // Both homes: the current one, and the pre-split one an upgraded install still has.
        let manager = FileManager.default
        let roots = [
            manager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ].compactMap { $0 }
        for root in roots {
            let directory = root
                .appendingPathComponent("Nuvio", isDirectory: true)
                .appendingPathComponent("profiles/\(profileId)", isDirectory: true)
            try? manager.removeItem(at: directory)
        }
        // Critical stores for this profile live in UserDefaults, keyed by the same path.
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("nuvio.store.profiles/\(profileId)/") {
            defaults.removeObject(forKey: key)
        }
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

    /// The server addresses profiles by a 1-based index rather than an id, and the primary is
    /// always 1. Held so a pull can match a remote row to the local profile it already created,
    /// instead of duplicating it — the local id has to stay put because it names the storage.
    var remoteIndex: Int? = nil
    /// `pin_enabled` from `sync_pull_profile_locks`. A PIN set on another device has no local
    /// hash to check against, so it is verified server-side instead.
    var hasRemoteLock: Bool = false
    /// Android's avatar catalogue has no SF Symbol equivalent, so its choice is carried through
    /// untouched rather than being lossily mapped and pushed back wrong.
    var avatarId: String? = nil
    var avatarUrl: String? = nil
    /// Whether this profile shares the primary's addon and plugin lists instead of its own.
    var usesPrimaryAddons: Bool = false
    var usesPrimaryPlugins: Bool = false

    var isLocked: Bool { pinHash != nil || hasRemoteLock }

    static let availableSymbols = [
        "person.fill", "person.2.fill", "figure.child", "star.fill",
        "gamecontroller.fill", "popcorn.fill", "pawprint.fill", "leaf.fill"
    ]

    /// Tolerant of documents written before a field existed — Swift's synthesised `Decodable`
    /// treats a missing key as an error even when the property has a default, so every field
    /// added to this struct used to wipe the whole profile list on the next launch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Me"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "person.fill"
        tintHex = try c.decodeIfPresent(String.self, forKey: .tintHex) ?? "#1E88E5"
        pinHash = try c.decodeIfPresent(String.self, forKey: .pinHash)
        isRestricted = try c.decodeIfPresent(Bool.self, forKey: .isRestricted) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        remoteIndex = try c.decodeIfPresent(Int.self, forKey: .remoteIndex)
        hasRemoteLock = try c.decodeIfPresent(Bool.self, forKey: .hasRemoteLock) ?? false
        avatarId = try c.decodeIfPresent(String.self, forKey: .avatarId)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        usesPrimaryAddons = try c.decodeIfPresent(Bool.self, forKey: .usesPrimaryAddons) ?? false
        usesPrimaryPlugins = try c.decodeIfPresent(Bool.self, forKey: .usesPrimaryPlugins) ?? false
    }

    init(
        id: String,
        name: String,
        symbol: String,
        tintHex: String,
        pinHash: String?,
        isRestricted: Bool,
        createdAt: Date,
        remoteIndex: Int? = nil,
        hasRemoteLock: Bool = false,
        avatarId: String? = nil,
        avatarUrl: String? = nil,
        usesPrimaryAddons: Bool = false,
        usesPrimaryPlugins: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tintHex = tintHex
        self.pinHash = pinHash
        self.isRestricted = isRestricted
        self.createdAt = createdAt
        self.remoteIndex = remoteIndex
        self.hasRemoteLock = hasRemoteLock
        self.avatarId = avatarId
        self.avatarUrl = avatarUrl
        self.usesPrimaryAddons = usesPrimaryAddons
        self.usesPrimaryPlugins = usesPrimaryPlugins
    }

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

    private let file = JSONFileStore<[Profile]>(
        filename: "profiles.json", scope: .global, durability: .critical
    )

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
                    createdAt: Date(),
                    remoteIndex: 1
                )
            ]
            persist()
        }
        // A profile deleted on another launch must not stay selected.
        if !profiles.contains(where: { $0.id == activeProfileId }) {
            activeProfileId = ProfileScope.primaryProfileId
            ProfileScope.activate(activeProfileId)
        }
        // `advanced_remember_last_profile`: with it off, every launch starts on the primary.
        // Read straight from defaults — the settings graph is built per profile, so it does not
        // exist yet at this point.
        if !Self.remembersLastProfile, activeProfileId != ProfileScope.primaryProfileId {
            activeProfileId = ProfileScope.primaryProfileId
            ProfileScope.activate(activeProfileId)
        }
        isLocked = activeProfile?.isLocked ?? false

        // The startup shortcut, matching Android's `LaunchedEffect(hasEverSelectedProfile, …)`:
        // with remembering on, a returning viewer goes straight in. A locked profile never
        // skips — a PIN that is only asked for once would not be protecting anything.
        if Self.remembersLastProfile, hasEverSelectedProfile, !isLocked {
            needsSelectionThisSession = false
        }
    }

    /// The primary profile's `app` namespace is unprefixed, so the key is the bare name.
    static var remembersLastProfile: Bool {
        UserDefaults.standard.object(forKey: "app.remember_last_profile") as? Bool ?? true
    }

    private static let everSelectedKey = "nuvio.has_ever_selected_profile"

    /// Whether a profile has ever been picked from the chooser. Android's
    /// `hasEverSelectedProfile`: the very first launch always asks, even with remembering on.
    private(set) var hasEverSelectedProfile =
        UserDefaults.standard.bool(forKey: "nuvio.has_ever_selected_profile")

    /// True while the chooser has not been answered in this run of the app. Android keeps this
    /// as `hasSelectedProfileThisSession`, reset by "Switch profile".
    private(set) var needsSelectionThisSession = true

    /// Android's `shouldShowProfileSelection`: only when there is a choice to make — more than
    /// one profile, or a PIN to enter.
    ///
    /// Deliberately says nothing about "remember last profile". That preference is a *startup*
    /// shortcut, applied once in `init`; folding it in here would also swallow an explicit
    /// "Switch profile", which is the one case the viewer definitely wants the chooser.
    var shouldPresentSelection: Bool {
        guard needsSelectionThisSession else { return false }
        return profiles.count > 1 || (activeProfile?.isLocked ?? false)
    }

    func markSelectionHandled() {
        needsSelectionThisSession = false
        guard !hasEverSelectedProfile else { return }
        hasEverSelectedProfile = true
        UserDefaults.standard.set(true, forKey: Self.everSelectedKey)
    }

    /// Sends the viewer back to the chooser — the "Switch profile" action.
    func requestSelection() { needsSelectionThisSession = true }

    /// Set when the chooser was left via "Add Profile" or a long press, so the app opens on the
    /// Profiles settings instead of Home. Consumed once by the root view.
    private(set) var wantsProfileManagement = false

    func requestProfileManagement() {
        wantsProfileManagement = true
        markSelectionHandled()
    }

    func consumeProfileManagementRequest() -> Bool {
        defer { wantsProfileManagement = false }
        return wantsProfileManagement
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

    // MARK: Sync

    /// One profile as the server stores it.
    struct RemoteProfile: Sendable {
        var index: Int
        var name: String
        var colorHex: String
        var usesPrimaryAddons: Bool
        var usesPrimaryPlugins: Bool
        var avatarId: String?
        var avatarUrl: String?
    }

    /// Merges a pull into the local list. Port of `ProfileSyncService.pullFromRemote` feeding
    /// `ProfileDataStore.replaceAllProfiles`.
    ///
    /// Rows are matched on the remote index, never on position or name: the local id is what
    /// names a profile's settings directory, so re-keying a profile here would silently orphan
    /// everything that belongs to it.
    func merge(remote: [RemoteProfile]) {
        guard !remote.isEmpty else { return }

        var merged: [Profile] = []
        for entry in remote.sorted(by: { $0.index < $1.index }) {
            if var existing = profiles.first(where: { $0.remoteIndex == entry.index })
                // A first sync has no indices stored yet, so index 1 adopts the primary.
                ?? (entry.index == 1 ? profiles.first(where: { $0.id == ProfileScope.primaryProfileId }) : nil) {
                existing.remoteIndex = entry.index
                existing.name = entry.name
                existing.tintHex = entry.colorHex
                existing.avatarId = entry.avatarId
                existing.avatarUrl = entry.avatarUrl
                existing.usesPrimaryAddons = entry.usesPrimaryAddons
                existing.usesPrimaryPlugins = entry.usesPrimaryPlugins
                merged.append(existing)
            } else {
                merged.append(Profile(
                    id: entry.index == 1 ? ProfileScope.primaryProfileId : UUID().uuidString,
                    name: entry.name,
                    symbol: Profile.availableSymbols[
                        (entry.index - 1) % Profile.availableSymbols.count
                    ],
                    tintHex: entry.colorHex,
                    pinHash: nil,
                    isRestricted: false,
                    createdAt: Date(),
                    remoteIndex: entry.index,
                    avatarId: entry.avatarId,
                    avatarUrl: entry.avatarUrl,
                    usesPrimaryAddons: entry.usesPrimaryAddons,
                    usesPrimaryPlugins: entry.usesPrimaryPlugins
                ))
            }
        }

        // Locally created profiles the server has never seen keep their place rather than being
        // dropped — the next push is what introduces them.
        let keptIndices = Set(merged.compactMap(\.remoteIndex))
        for profile in profiles where profile.remoteIndex == nil
            && !merged.contains(where: { $0.id == profile.id }) {
            merged.append(profile)
        }
        // A profile the server dropped is deleted here too, with its storage.
        for profile in profiles where profile.remoteIndex != nil
            && !keptIndices.contains(profile.remoteIndex ?? -1) {
            ProfileScope.eraseStorage(forProfileId: profile.id)
        }

        profiles = merged
        if !profiles.contains(where: { $0.id == activeProfileId }) {
            activeProfileId = ProfileScope.primaryProfileId
            ProfileScope.activate(activeProfileId)
        }
        persist()
    }

    /// The list as it should be pushed, with an index assigned to anything new.
    func remoteSnapshot() -> [RemoteProfile] {
        assignMissingRemoteIndices()
        return profiles.compactMap { profile in
            guard let index = profile.remoteIndex else { return nil }
            return RemoteProfile(
                index: index,
                name: profile.name,
                colorHex: profile.tintHex,
                usesPrimaryAddons: profile.usesPrimaryAddons,
                usesPrimaryPlugins: profile.usesPrimaryPlugins,
                avatarId: profile.avatarId,
                avatarUrl: profile.avatarUrl
            )
        }
    }

    /// The primary is always 1; everything else takes the lowest index not already in use.
    private func assignMissingRemoteIndices() {
        var used = Set(profiles.compactMap(\.remoteIndex))
        var changed = false
        for index in profiles.indices where profiles[index].remoteIndex == nil {
            let assigned: Int
            if profiles[index].id == ProfileScope.primaryProfileId {
                assigned = 1
            } else {
                var candidate = 2
                while used.contains(candidate) { candidate += 1 }
                assigned = candidate
            }
            used.insert(assigned)
            profiles[index].remoteIndex = assigned
            changed = true
        }
        if changed { persist() }
    }

    /// `sync_pull_profile_locks`: which profiles carry a PIN, wherever it was set.
    func applyRemoteLocks(_ locks: [Int: Bool]) {
        var changed = false
        for index in profiles.indices {
            guard let remoteIndex = profiles[index].remoteIndex,
                  let enabled = locks[remoteIndex],
                  profiles[index].hasRemoteLock != enabled else { continue }
            profiles[index].hasRemoteLock = enabled
            changed = true
        }
        if changed {
            persist()
            isLocked = activeProfile?.isLocked ?? false
        }
    }

    /// Unlock for a PIN that was set on another device: there is no local hash to compare, so
    /// the server decides. Falls back to the local check when the profile has one.
    func unlockRemotely(_ profile: Profile, pin: String) async -> Bool {
        if profile.pinHash != nil { return unlock(profile, pin: pin) }
        guard let index = profile.remoteIndex else { return false }
        let verified = await NuvioSyncService.verifyProfilePin(profileId: index, pin: pin)
        guard verified else { return false }
        return activate(profile, unlocked: true)
    }

    private func persist() { file.save(profiles) }

    /// SHA-256 of the PIN. Not a defence against an attacker with the device — it stops the PIN
    /// being visible to anyone who opens the preferences file, which is the actual threat here.
    private static func hash(_ pin: String) -> String {
        let salted = Data(("nuvio-profile-pin:" + pin).utf8)
        return SHA256.hash(data: salted).map { String(format: "%02x", $0) }.joined()
    }
}
