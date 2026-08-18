import Foundation
import Observation

/// Port of `AvatarRepository` — the picture library profiles draw their avatars from.
///
/// Without this a synced profile falls back to an SF Symbol, which is why household members who
/// picked a real avatar on Android arrived here as generic glyphs. The catalogue is small and
/// changes rarely, so it is fetched once per launch and held.
@Observable
@MainActor
final class AvatarCatalog {
    private(set) var items: [AvatarCatalogItem] = []
    private var hasLoaded = false
    private var loadTask: Task<Void, Never>?

    struct AvatarCatalogItem: Identifiable, Hashable, Sendable {
        let id: String
        let displayName: String
        let imageURL: String
        let category: String
        let sortOrder: Int
        let backgroundHex: String?
    }

    /// The image for a profile: an explicit URL wins over a catalogue id, matching the way the
    /// server treats the two fields as mutually exclusive.
    func imageURL(for profile: Profile) -> String? {
        if let url = profile.avatarUrl?.nilIfBlank { return url }
        guard let id = profile.avatarId?.nilIfBlank else { return nil }
        return items.first { $0.id == id }?.imageURL
    }

    func loadIfNeeded(configuration: NuvioServerConfiguration) {
        guard !hasLoaded, loadTask == nil, configuration.isConfigured else { return }
        loadTask = Task {
            defer { loadTask = nil }
            let rows = try? await NuvioBackend.shared.rpc(
                "get_avatar_catalog", as: [Failable<RemoteAvatar>].self
            )
            guard let rows else { return }
            var base = configuration.avatarPublicBaseUrl
            while base.hasSuffix("/") { base.removeLast() }
            items = rows.compactMap(\.value).map { row in
                AvatarCatalogItem(
                    id: row.id,
                    displayName: row.display_name ?? row.id,
                    imageURL: Self.imageURL(storagePath: row.storage_path ?? "", base: base),
                    category: row.category ?? "",
                    sortOrder: row.sort_order ?? 0,
                    backgroundHex: row.bg_color
                )
            }
            .sorted { $0.sortOrder < $1.sortOrder }
            hasLoaded = true
        }
    }

    /// Storage paths are relative to the public avatars bucket unless already absolute.
    private static func imageURL(storagePath: String, base: String) -> String {
        let path = storagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.lowercased().hasPrefix("http") { return path }
        guard !base.isEmpty else { return path }
        return "\(base)/\(path)"
    }
}

private struct RemoteAvatar: Decodable {
    let id: String
    let display_name: String?
    let storage_path: String?
    let category: String?
    let sort_order: Int?
    let bg_color: String?
}
