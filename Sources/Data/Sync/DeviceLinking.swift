import Foundation
import Observation
import os

/// Device linking — port of `SyncRepositoryImpl`'s sync-code surface.
///
/// Two devices end up sharing one account's rows: the owner generates a code guarded by a PIN,
/// the second device claims it, and from then on `get_sync_owner` resolves to the owner so both
/// write to the same library, progress and settings. RPC names, parameter names and result shapes
/// match the Android client.
struct LinkedDevice: Identifiable, Hashable, Sendable, Decodable {
    var id: String?
    var owner_id: String
    var device_user_id: String
    var device_name: String?
    var linked_at: String?

    /// `device_user_id` is the stable identity; `id` is absent on some server versions.
    var stableId: String { id ?? device_user_id }

    var displayName: String { device_name?.nilIfBlank ?? "Unnamed device" }

    var linkedDate: Date? { linked_at.flatMap { VideoDateParser.parse($0) } }
}

@Observable
@MainActor
final class DeviceLinkingStore {
    enum Phase: Equatable {
        case idle
        case working(String)
        /// The owner's code, ready to type on the other device.
        case generated(String)
        case claimed
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var linkedDevices: [LinkedDevice] = []

    private let log = Logger(subsystem: "com.nuvio.tvos", category: "DeviceLinking")

    // MARK: Owner side

    /// Pushes local data first, so the device that joins pulls a complete account rather than an
    /// empty one — the Android view model does the same before generating.
    func generateCode(
        pin: String,
        account: NuvioAccountStore,
        sync: NuvioSyncService,
        library: LibraryStore,
        collections: CollectionStore,
        addons: AddonStore,
        plugins: PluginStore,
        profiles: ProfileStore,
        settings: AppSettings
    ) async {
        guard account.isSignedIn else {
            phase = .failed("Sign in first.")
            return
        }
        let digits = pin.filter(\.isNumber)
        guard digits.count >= 4 else {
            phase = .failed("Choose a PIN of at least four digits.")
            return
        }

        phase = .working("Uploading this device's data…")
        sync.sync(
            account: account, library: library, collections: collections,
            addons: addons, plugins: plugins, profiles: profiles, settings: settings
        )

        phase = .working("Asking the server for a code…")
        do {
            let results = try await NuvioBackend.shared.rpc(
                "generate_sync_code",
                parameters: ["p_pin": .string(digits)],
                as: [SyncCodeResult].self
            )
            guard let code = results.first?.code.nilIfBlank else {
                phase = .failed("The server returned no code.")
                return
            }
            phase = .generated(code)
            await loadLinkedDevices(account: account)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Re-reads a code already issued for this account, so the owner can show it again without
    /// invalidating the previous one.
    func fetchExistingCode(pin: String) async {
        let digits = pin.filter(\.isNumber)
        guard digits.count >= 4 else {
            phase = .failed("Enter the PIN you set when you created the code.")
            return
        }
        phase = .working("Looking up your code…")
        do {
            let results = try await NuvioBackend.shared.rpc(
                "get_sync_code",
                parameters: ["p_pin": .string(digits)],
                as: [SyncCodeResult].self
            )
            guard let code = results.first?.code.nilIfBlank else {
                phase = .failed("No code exists for that PIN yet.")
                return
            }
            phase = .generated(code)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Joining side

    /// Claims the owner's code. On success the local rows are replaced by the account's, which is
    /// the point: this device is joining an existing library, not merging into it.
    func claim(
        code: String,
        pin: String,
        deviceName: String,
        account: NuvioAccountStore,
        sync: NuvioSyncService,
        library: LibraryStore,
        collections: CollectionStore,
        addons: AddonStore,
        plugins: PluginStore,
        profiles: ProfileStore,
        settings: AppSettings
    ) async {
        guard account.isSignedIn else {
            phase = .failed("Sign in on this device first, then claim the code.")
            return
        }
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let digits = pin.filter(\.isNumber)
        guard !trimmedCode.isEmpty, digits.count >= 4 else {
            phase = .failed("Enter both the code and its PIN.")
            return
        }

        phase = .working("Linking…")
        do {
            let results = try await NuvioBackend.shared.rpc(
                "claim_sync_code",
                parameters: [
                    "p_code": .string(trimmedCode),
                    "p_pin": .string(digits),
                    "p_device_name": .string(deviceName)
                ],
                as: [ClaimSyncResult].self
            )
            guard let result = results.first else {
                phase = .failed("The server returned no result.")
                return
            }
            guard result.success else {
                // A refused claim leaves the session pointing at the wrong owner, so the Android
                // client signs out rather than continuing in a half-linked state.
                account.signOut()
                phase = .failed(result.message.nilIfBlank ?? "That code was refused.")
                return
            }

            // The owner changed, so the cached one has to go before anything is pulled.
            await account.resolveSyncOwner()
            phase = .working("Downloading the account's library…")
            sync.sync(
                account: account, library: library, collections: collections,
                addons: addons, plugins: plugins, profiles: profiles, settings: settings
            )
            phase = .claimed
        } catch {
            account.signOut()
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Managing links

    func loadLinkedDevices(account: NuvioAccountStore) async {
        guard account.isSignedIn, let ownerId = account.syncOwnerId ?? account.session?.userId else {
            return
        }
        do {
            linkedDevices = try await NuvioBackend.shared.select(
                table: "linked_devices",
                filters: ["owner_id": ownerId],
                as: [Failable<LinkedDevice>].self
            ).compactMap(\.value)
        } catch {
            log.debug("linked devices failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func unlink(_ device: LinkedDevice, account: NuvioAccountStore) async {
        phase = .working("Unlinking \(device.displayName)…")
        do {
            try await NuvioBackend.shared.rpcVoid(
                "unlink_device",
                parameters: ["p_device_user_id": .string(device.device_user_id)]
            )
            await account.resolveSyncOwner()
            await loadLinkedDevices(account: account)
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func reset() { phase = .idle }

    // MARK: Wire types

    private struct SyncCodeResult: Decodable { let code: String }

    private struct ClaimSyncResult: Decodable {
        let result_owner_id: String?
        let success: Bool
        let message: String
    }
}
