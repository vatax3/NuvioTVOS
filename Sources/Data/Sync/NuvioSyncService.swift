import Foundation
import Observation
import os

/// Two-way sync against the Nuvio backend.
///
/// Ports the RPC surface the Android sync services use, with the same function names, parameter
/// names and row shapes: library items, watch progress, watched items, collections, addons,
/// plugin repositories and the per-profile settings blob.
///
/// Merge policy follows the Android services: the remote snapshot is authoritative for anything
/// the server already knows, and local rows the server has not seen are pushed. Watch progress
/// resolves per key by `last_watched`, so the furthest-along device wins rather than the last one
/// to sync.
@Observable
@MainActor
final class NuvioSyncService {
    enum Status: Equatable {
        case idle
        case syncing(String)
        case succeeded(Date)
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// Set when the viewer turns sync off; nothing is pushed or pulled while false.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "nuvio.sync_enabled"
    private let log = Logger(subsystem: "com.nuvio.tvos", category: "NuvioSync")
    private var runningTask: Task<Void, Never>?

    /// Stops a pass mid-flight. Signing out has to do this before the local data is removed,
    /// or a pull already in progress adopts rows into stores that are about to be deleted.
    func cancel() {
        runningTask?.cancel()
        runningTask = nil
    }

    // MARK: Entry point

    /// Full two-way pass. Serialised — a second request while one is running is a no-op.
    func sync(
        account: NuvioAccountStore,
        library: LibraryStore,
        collections: CollectionStore,
        addons: AddonStore,
        plugins: PluginStore,
        profiles: ProfileStore,
        settings: AppSettings
    ) {
        guard isEnabled, account.isSignedIn, runningTask == nil else { return }

        runningTask = Task {
            defer { runningTask = nil }
            await account.ensureFreshSession()
            guard account.isSignedIn else {
                status = .failed("Not signed in.")
                return
            }
            if account.syncOwnerId == nil { await account.resolveSyncOwner() }

            do {
                // First: it decides the index every other table is keyed on, and a profile the
                // server added has to exist locally before its rows are pulled.
                status = .syncing("Profiles")
                try await syncProfiles(profiles: profiles)

                let profileId = Self.remoteProfileId(for: profiles)

                status = .syncing("Library")
                try await syncLibrary(library: library, profileId: profileId)

                status = .syncing("Watch progress")
                try await syncWatchProgress(library: library, profileId: profileId)

                status = .syncing("Collections")
                try await syncCollections(collections: collections, library: library, profileId: profileId)

                // A profile that borrows the primary's addons shares its rows too. Syncing the
                // shared list under the borrowing profile's own index would fork it on the
                // server the first time either side changed.
                status = .syncing("Addons")
                try await syncAddons(
                    addons: addons,
                    profileId: ProfileScope.sharesPrimaryAddons ? 1 : profileId,
                    ownerId: account.syncOwnerId
                )

                status = .syncing("Plugins")
                try await syncPlugins(
                    plugins: plugins,
                    profileId: ProfileScope.sharesPrimaryPlugins ? 1 : profileId,
                    ownerId: account.syncOwnerId
                )

                status = .syncing("Settings")
                try await syncSettings(settings: settings, profileId: profileId)

                status = .succeeded(Date())
            } catch {
                log.error("sync failed: \(error.localizedDescription, privacy: .public)")
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// The server addresses profiles by a 1-based index; the primary is always 1. The index is
    /// stored on the profile rather than derived from its position, which would silently
    /// re-point a profile's rows the moment the list is reordered.
    static func remoteProfileId(for profiles: ProfileStore) -> Int {
        profiles.activeProfile?.remoteIndex ?? 1
    }

    private var originParameters: [String: AnyJSONValue] {
        ["p_origin_client_id": .string(SyncClientIdentity.current)]
    }

    // MARK: Library

    private func syncLibrary(library: LibraryStore, profileId: Int) async throws {
        // Deletions go first: otherwise the pull would hand back the rows this device removed
        // and they would be re-adopted before the delete was ever sent.
        let pendingDeletions = library.pendingLibraryDeletions
        if !pendingDeletions.isEmpty {
            try await pushLibraryDeletions(keys: pendingDeletions, profileId: profileId)
            library.clearPendingLibraryDeletions(pendingDeletions)
        }

        let remote = try await NuvioBackend.shared.rpc(
            "sync_pull_library",
            parameters: [
                "p_profile_id": .int(profileId),
                "p_limit": .int(1000),
                "p_offset": .int(0)
            ],
            as: [Failable<RemoteLibraryItem>].self
        ).compactMap(\.value)

        let remoteByKey = Dictionary(
            remote.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let localByKey = Dictionary(
            library.library.map { ($0.preview.rowKey, $0) }, uniquingKeysWith: { first, _ in first }
        )

        // Anything the server has and this device does not, arrives.
        for (key, item) in remoteByKey where localByKey[key] == nil {
            library.adoptSavedItem(item.asSavedItem())
        }
        // Anything this device has and the server does not, is pushed up.
        let missingRemotely = library.library.filter { remoteByKey[$0.preview.rowKey] == nil }
        if !missingRemotely.isEmpty {
            try await pushLibrary(items: missingRemotely, profileId: profileId)
        }
    }

    private func pushLibraryDeletions(keys: [String], profileId: Int) async throws {
        // A row key is `<type>|<id>`, which is exactly the pair the delete RPC wants.
        let payload = keys.compactMap { key -> AnyJSONValue? in
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return .object([
                "content_type": .string(String(parts[0])),
                "content_id": .string(String(parts[1]))
            ])
        }
        guard !payload.isEmpty else { return }
        for chunk in payload.chunked(into: 100) {
            var parameters = originParameters
            parameters["p_keys"] = .array(chunk)
            parameters["p_profile_id"] = .int(profileId)
            try await NuvioBackend.shared.rpcVoid("sync_delete_library_items", parameters: parameters)
        }
    }

    private func pushLibrary(items: [SavedLibraryItem], profileId: Int) async throws {
        // Batched the way the Android data source batches its mutations.
        for chunk in items.chunked(into: 100) {
            let payload = chunk.map { item -> AnyJSONValue in
                let preview = item.preview
                return .object([
                    "content_id": .string(preview.id),
                    "content_type": .string(preview.apiType),
                    "name": .string(preview.name),
                    "poster": .optionalString(preview.poster),
                    "poster_shape": .string(preview.posterShape.rawValue.uppercased()),
                    "background": .optionalString(preview.background),
                    "description": .optionalString(preview.description),
                    "release_info": .optionalString(preview.releaseInfo),
                    "imdb_rating": preview.imdbRating.map { .double(Double($0)) } ?? .null,
                    "genres": .array(preview.genres.map { .string($0) }),
                    "addon_base_url": .optionalString(preview.sourceAddonBaseUrl),
                    "added_at": .int64(Int64(item.addedAt.timeIntervalSince1970 * 1000))
                ])
            }
            var parameters = originParameters
            parameters["p_items"] = .array(payload)
            parameters["p_profile_id"] = .int(profileId)
            try await NuvioBackend.shared.rpcVoid("sync_push_library_items", parameters: parameters)
        }
    }

    // MARK: Watch progress

    private func syncWatchProgress(library: LibraryStore, profileId: Int) async throws {
        let remote = try await NuvioBackend.shared.rpc(
            "sync_pull_watch_progress",
            parameters: ["p_profile_id": .int(profileId), "p_limit": .int(2000)],
            as: [Failable<RemoteWatchProgress>].self
        ).compactMap(\.value)

        var toPush: [WatchProgress] = []
        var remoteKeys = Set<String>()

        for entry in remote {
            remoteKeys.insert(entry.progress_key)
            let incoming = entry.asWatchProgress()
            guard let local = library.progress(forVideoId: incoming.videoId) else {
                library.adoptProgress(incoming)
                continue
            }
            // Whichever side watched more recently wins; equal timestamps keep the local row.
            if incoming.updatedAt > local.updatedAt {
                library.adoptProgress(incoming)
            } else if local.updatedAt > incoming.updatedAt {
                toPush.append(local)
            }
        }

        // Local rows the server has never seen.
        for (_, progress) in library.progress where !remoteKeys.contains(Self.progressKey(progress)) {
            toPush.append(progress)
        }

        guard !toPush.isEmpty else { return }
        for chunk in toPush.chunked(into: 200) {
            let payload = chunk.map { progress -> AnyJSONValue in
                var object: [String: AnyJSONValue] = [
                    "content_id": .string(progress.contentId),
                    "content_type": .string(progress.contentType),
                    "video_id": .string(progress.videoId),
                    // The server stores milliseconds.
                    "position": .int64(Int64(progress.positionSeconds * 1000)),
                    "duration": .int64(Int64(progress.durationSeconds * 1000)),
                    "last_watched": .int64(Int64(progress.updatedAt.timeIntervalSince1970 * 1000)),
                    "progress_key": .string(Self.progressKey(progress))
                ]
                if let season = progress.season { object["season"] = .int(season) }
                if let episode = progress.episode { object["episode"] = .int(episode) }
                return .object(object)
            }
            var parameters = originParameters
            parameters["p_entries"] = .array(payload)
            parameters["p_profile_id"] = .int(profileId)
            try await NuvioBackend.shared.rpcVoid("sync_push_watch_progress", parameters: parameters)
        }
    }

    /// Matches the Android key: the video id identifies one playable item across devices.
    static func progressKey(_ progress: WatchProgress) -> String {
        progress.videoId
    }

    // MARK: Collections

    private func syncCollections(
        collections: CollectionStore,
        library: LibraryStore,
        profileId: Int
    ) async throws {
        // Collections travel as one JSON blob, so the newer side replaces the other outright.
        let remote = try await NuvioBackend.shared.rpc(
            "sync_pull_collections",
            parameters: ["p_profile_id": .int(profileId)],
            as: [Failable<RemoteCollectionsBlob>].self
        ).compactMap(\.value).first

        let remoteUpdatedAt = remote?.updated_at.flatMap { VideoDateParser.parse($0) }

        if let remote, let payload = remote.collections_json,
           remoteUpdatedAt ?? .distantPast > collections.updatedAt {
            // Not marked as a local change: accepting a pull is not an edit, and stamping it as
            // one would make this device look newer next time and push the same rows back.
            collections.replaceAll(with: payload, markChanged: false)
            return
        }

        guard !collections.collections.isEmpty else { return }
        // Encoded through the model rather than rebuilt by hand. Collections are three levels
        // deep and their sources use a flat, provider-discriminated encoding that Android's
        // importer validates field by field — a second hand-written copy of that shape here is a
        // second thing to get wrong.
        guard let payload = AnyJSONValue.encoding(collections.collections) else { return }
        var parameters = originParameters
        parameters["p_profile_id"] = .int(profileId)
        parameters["p_collections_json"] = payload
        try await NuvioBackend.shared.rpcVoid("sync_push_collections", parameters: parameters)
    }

    // MARK: Profiles

    /// Port of `ProfileSyncService`. The profile list is account-wide rather than per-profile,
    /// so it syncs once regardless of who is active — and it has to run before everything else,
    /// since every other table is addressed by profile index.
    private func syncProfiles(profiles: ProfileStore) async throws {
        let remote = try await NuvioBackend.shared.rpc(
            "sync_pull_profiles", as: [Failable<RemoteProfileRow>].self
        ).compactMap(\.value)

        profiles.merge(remote: remote.map {
            ProfileStore.RemoteProfile(
                index: $0.profile_index,
                name: $0.name ?? "",
                colorHex: $0.avatar_color_hex ?? "#1E88E5",
                usesPrimaryAddons: $0.uses_primary_addons ?? false,
                usesPrimaryPlugins: $0.uses_primary_plugins ?? false,
                avatarId: $0.avatar_id,
                avatarUrl: $0.avatar_url
            )
        })

        let payload = profiles.remoteSnapshot().map { profile -> AnyJSONValue in
            AnyJSONValue.object([
                "profile_index": .int(profile.index),
                "name": .string(profile.name),
                "avatar_color_hex": .string(profile.colorHex),
                "uses_primary_addons": .bool(profile.usesPrimaryAddons),
                "uses_primary_plugins": .bool(profile.usesPrimaryPlugins),
                // The server treats these as mutually exclusive; a custom image wins.
                "avatar_id": profile.avatarUrl?.nilIfBlank == nil
                    ? .optionalString(profile.avatarId) : .null,
                "avatar_url": .optionalString(profile.avatarUrl?.nilIfBlank)
            ])
        }
        var parameters = originParameters
        parameters["p_client_max_profiles"] = .int(Self.maxProfiles)
        parameters["p_profiles"] = .array(payload)
        try await NuvioBackend.shared.rpcVoid("sync_push_profiles", parameters: parameters)

        // Which profiles are PIN-locked is separate from the list itself, because the PIN never
        // leaves the server — only the fact that one exists.
        let locks = try await NuvioBackend.shared.rpc(
            "sync_pull_profile_locks", as: [Failable<RemoteProfileLock>].self
        ).compactMap(\.value)
        profiles.applyRemoteLocks(
            Dictionary(
                locks.map { ($0.profile_index, $0.pin_enabled ?? false) },
                uniquingKeysWith: { _, latest in latest }
            )
        )
    }

    /// `ProfileManager.MAX_PROFILES`.
    static let maxProfiles = 5

    /// Server-side PIN check, for a lock that was set on another device.
    static func verifyProfilePin(profileId: Int, pin: String) async -> Bool {
        let result = try? await NuvioBackend.shared.rpc(
            "verify_profile_pin",
            parameters: ["p_profile_id": .int(profileId), "p_pin": .string(pin)],
            as: [Failable<RemotePinVerification>].self
        )
        return result?.compactMap(\.value).first?.unlocked ?? false
    }

    // MARK: Addons

    private func syncAddons(addons: AddonStore, profileId: Int, ownerId: String?) async throws {
        // Pulled with a table read, not an RPC — the schema has no pull function for addons and
        // this is what the Android client does. RLS scopes the rows; the owner filter matters
        // only for a device linked to somebody else's account.
        var filters = ["profile_id": String(profileId)]
        if let ownerId { filters["user_id"] = ownerId }
        let remoteAddons = try await NuvioBackend.shared.select(
            table: "addons", filters: filters, as: [Failable<RemoteAddon>].self
        ).compactMap(\.value)

        for entry in remoteAddons.sorted(by: { ($0.sort_order ?? 0) < ($1.sort_order ?? 0) }) {
            guard addons.addon(withBaseUrl: entry.url) == nil else { continue }
            _ = await addons.install(url: entry.url)
            if entry.enabled == false {
                addons.setEnabled(false, baseUrl: StremioURL.canonicalize(entry.url))
            }
        }

        let payload = addons.installed.enumerated().map { index, record -> AnyJSONValue in
            var object: [String: AnyJSONValue] = [
                "url": .string(record.baseUrl),
                "sort_order": .int(index),
                "enabled": .bool(record.enabled)
            ]
            if let name = record.manifest?.displayName.nilIfBlank { object["name"] = .string(name) }
            return .object(object)
        }
        var parameters = originParameters
        parameters["p_addons"] = .array(payload)
        parameters["p_profile_id"] = .int(profileId)
        try await NuvioBackend.shared.rpcVoid("sync_push_addons", parameters: parameters)
    }

    // MARK: Plugins

    private func syncPlugins(plugins: PluginStore, profileId: Int, ownerId: String?) async throws {
        var filters = ["profile_id": String(profileId)]
        if let ownerId { filters["user_id"] = ownerId }
        let remote = try await NuvioBackend.shared.select(
            table: "plugins", filters: filters, as: [Failable<RemotePlugin>].self
        ).compactMap(\.value)

        for entry in remote.sorted(by: { ($0.sort_order ?? 0) < ($1.sort_order ?? 0) }) {
            let canonical = PluginStore.canonicalizeManifestUrl(entry.url)
            guard !plugins.repositories.contains(where: {
                $0.manifestUrl.caseInsensitiveCompare(canonical) == .orderedSame
            }) else { continue }
            await plugins.addRepository(url: entry.url)
        }

        let payload = plugins.repositories.enumerated().map { index, repository -> AnyJSONValue in
            .object([
                "url": .string(repository.manifestUrl),
                "sort_order": .int(index),
                "enabled": .bool(repository.enabled),
                "name": .string(repository.name),
                // The Android column distinguishes JS repos from DEX extensions.
                "repo_type": .string("NUVIO_JS")
            ])
        }
        var parameters = originParameters
        parameters["p_plugins"] = .array(payload)
        parameters["p_profile_id"] = .int(profileId)
        try await NuvioBackend.shared.rpcVoid("sync_push_plugins", parameters: parameters)
    }

    // MARK: Settings

    private func syncSettings(settings: AppSettings, profileId: Int) async throws {
        let remote = try await NuvioBackend.shared.rpc(
            "sync_pull_profile_settings_blob",
            parameters: [
                "p_profile_id": .int(profileId),
                // The server keeps one blob per platform; "tv" is what the Android TV app uses,
                // and this client is the same form factor with the same preference keys.
                "p_platform": .string("tv")
            ],
            as: [Failable<RemoteSettingsBlob>].self
        ).compactMap(\.value).first

        let remoteUpdatedAt = remote?.updated_at.flatMap { VideoDateParser.parse($0) }
        let localUpdatedAt = settings.settingsUpdatedAt

        if let payload = remote?.settings_json,
           (remoteUpdatedAt ?? .distantPast) > (localUpdatedAt ?? .distantPast) {
            settings.importSyncedSettings(payload)
            return
        }

        var parameters = originParameters
        parameters["p_profile_id"] = .int(profileId)
        parameters["p_platform"] = .string("tv")
        parameters["p_settings_json"] = .object(settings.exportSyncedSettings())
        try await NuvioBackend.shared.rpcVoid("sync_push_profile_settings_blob", parameters: parameters)
    }
}

// MARK: - Remote row shapes

private struct RemoteLibraryItem: Decodable {
    let content_id: String
    let content_type: String
    let name: String?
    let poster: String?
    let poster_shape: String?
    let background: String?
    let description: String?
    let release_info: String?
    let imdb_rating: Double?
    let genres: [String]?
    let addon_base_url: String?
    let added_at: Int64?

    var key: String { "\(content_type)|\(content_id)" }

    func asSavedItem() -> SavedLibraryItem {
        SavedLibraryItem(
            preview: MetaPreview(
                id: content_id,
                type: ContentType.from(content_type),
                rawType: content_type,
                name: name?.nilIfBlank ?? content_id,
                poster: poster,
                posterShape: PosterShape(rawValue: (poster_shape ?? "poster").lowercased()) ?? .poster,
                background: background,
                description: description,
                releaseInfo: release_info,
                imdbRating: imdb_rating.map { Float($0) },
                genres: genres ?? [],
                sourceAddonBaseUrl: addon_base_url
            ),
            addedAt: added_at.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
        )
    }
}

private struct RemoteWatchProgress: Decodable {
    let content_id: String
    let content_type: String
    let video_id: String
    let season: Int?
    let episode: Int?
    let position: Int64
    let duration: Int64
    let last_watched: Int64
    let progress_key: String

    func asWatchProgress() -> WatchProgress {
        WatchProgress(
            contentId: content_id,
            contentType: content_type,
            videoId: video_id.nilIfBlank ?? progress_key,
            season: season,
            episode: episode,
            positionSeconds: Double(position) / 1000,
            durationSeconds: Double(duration) / 1000,
            updatedAt: Date(timeIntervalSince1970: Double(last_watched) / 1000)
        )
    }
}

private struct RemoteCollectionsBlob: Decodable {
    let collections_json: [MediaCollection]?
    let updated_at: String?
}

private struct RemoteSettingsBlob: Decodable {
    let settings_json: [String: AnyJSON]?
    let updated_at: String?
}

private struct RemoteProfileRow: Decodable {
    let profile_index: Int
    let name: String?
    let avatar_color_hex: String?
    let uses_primary_addons: Bool?
    let uses_primary_plugins: Bool?
    let avatar_id: String?
    let avatar_url: String?
}

private struct RemoteProfileLock: Decodable {
    let profile_index: Int
    let pin_enabled: Bool?
}

private struct RemotePinVerification: Decodable {
    let unlocked: Bool?
}

private struct RemoteAddon: Decodable {
    let url: String
    let name: String?
    let enabled: Bool?
    let sort_order: Int?
}

private struct RemotePlugin: Decodable {
    let url: String
    let name: String?
    let enabled: Bool?
    let sort_order: Int?
}

// MARK: - Helpers

extension Array {
    /// Mutation batching, matching the server-side limits the Android client respects.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
