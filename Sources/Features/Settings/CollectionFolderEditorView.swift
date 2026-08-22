import SwiftUI

/// Sheet chrome shared by the collection editors — a title, then settings cards.
struct SettingsSheet<Content: View>: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.dismiss) private var dismiss

    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                Text(title)
                    .nuvioText(NuvioTextStyles.sectionTitle)
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
                content
            }
            .padding(.vertical, NuvioTheme.layout.tvSafeVertical)
        }
        .scrollClipDisabled()
        .background(colors.background)
        .onExitCommand { dismiss() }
    }
}

// MARK: - Folder editor

/// One folder: what it is called, what it looks like, and — the point of it — what it asks for.
struct CollectionFolderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CollectionStore.self) private var collections
    @Environment(AddonStore.self) private var addons

    let collectionId: String
    let folderId: String

    @State private var addingSource: SourceKind?
    @State private var isConfirmingDelete = false

    private enum SourceKind: String, Identifiable {
        case addon, tmdb, trakt
        var id: String { rawValue }
    }

    private var folder: CollectionFolder? {
        collections.folder(id: folderId)?.folder
    }

    var body: some View {
        SettingsSheet(title: folder?.title ?? "Folder") {
            if let folder {
                SettingsCard(title: "Details") {
                    SettingsTextFieldRow(title: "Name", text: text(\.title))
                    SettingsTextFieldRow(
                        title: "Cover emoji",
                        subtitle: "Shown when there is no cover image",
                        placeholder: "🎬",
                        text: optionalText(\.coverEmoji)
                    )
                    SettingsOptionRow(title: "Tile shape", selection: shape)
                    SettingsToggle(title: "Hide the title on the tile", isOn: flag(\.hideTitle))
                }

                SettingsCard(
                    title: "Sources",
                    footnote: "Everything these return shows up in this folder."
                ) {
                    ForEach(folder.sources) { source in
                        SettingsRow(
                            title: describe(source),
                            subtitle: providerName(source),
                            systemImage: icon(source),
                            trailing: { SettingsValueLabel(value: "Remove") },
                            action: {
                                collections.removeSource(source, fromFolder: folderId, in: collectionId)
                            }
                        )
                    }
                    SettingsRow(title: "Add an addon catalog", systemImage: "square.grid.2x2", trailing: { EmptyView() }) {
                        addingSource = .addon
                    }
                    SettingsRow(title: "Add a TMDB query", systemImage: "magnifyingglass", trailing: { EmptyView() }) {
                        addingSource = .tmdb
                    }
                    SettingsRow(title: "Add a Trakt list", systemImage: "list.bullet", trailing: { EmptyView() }) {
                        addingSource = .trakt
                    }
                }

                SettingsCard(
                    title: "Artwork",
                    footnote: """
                    Optional. The cover is the tile; the backdrop and logo are the header of the \
                    folder's own screen.
                    """
                ) {
                    SettingsTextFieldRow(title: "Cover image URL", text: optionalText(\.coverImageUrl))
                    SettingsTextFieldRow(title: "Backdrop URL", text: optionalText(\.heroBackdropUrl))
                    SettingsTextFieldRow(title: "Title logo URL", text: optionalText(\.titleLogoUrl))
                }

                SettingsCard(title: "Order") {
                    SettingsRow(title: "Move up", systemImage: "arrow.up", trailing: { EmptyView() }) {
                        collections.moveFolder(folderId, in: collectionId, by: -1)
                    }
                    SettingsRow(title: "Move down", systemImage: "arrow.down", trailing: { EmptyView() }) {
                        collections.moveFolder(folderId, in: collectionId, by: 1)
                    }
                }

                SettingsCard(title: nil) {
                    SettingsRow(title: "Delete folder", systemImage: "trash", trailing: { EmptyView() }) {
                        isConfirmingDelete = true
                    }
                }
            }
        }
        .sheet(item: $addingSource) { kind in
            switch kind {
            case .addon:
                AddonCatalogPickerView(collectionId: collectionId, folderId: folderId)
            case .tmdb:
                TmdbSourcePickerView(collectionId: collectionId, folderId: folderId)
            case .trakt:
                TraktSourcePickerView(collectionId: collectionId, folderId: folderId)
            }
        }
        .alert("Delete this folder?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                collections.deleteFolder(folderId, from: collectionId)
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        }
    }

    // MARK: Row labels

    private func describe(_ source: CollectionSource) -> String {
        switch source {
        case .addon(let addon):
            let catalog = addons.enabledAddons
                .first { $0.id == addon.addonId }?
                .catalogs.first { $0.id == addon.catalogId }
            let name = catalog?.name ?? addon.catalogId
            return addon.genre.map { "\(name) · \($0)" } ?? name
        case .tmdb(let tmdb):
            return tmdb.title.nilIfBlank ?? tmdb.sourceType.rawValue.capitalized
        case .trakt(let trakt):
            return trakt.title.nilIfBlank ?? "List \(trakt.traktListId)"
        }
    }

    private func providerName(_ source: CollectionSource) -> String {
        switch source {
        case .addon(let addon):
            return addons.enabledAddons.first { $0.id == addon.addonId }?.displayName ?? addon.addonId
        case .tmdb(let tmdb):
            return "TMDB · \(tmdb.mediaType == .tv ? "Series" : "Movies")"
        case .trakt(let trakt):
            return "Trakt · \(trakt.mediaType == .tv ? "Series" : "Movies")"
        }
    }

    private func icon(_ source: CollectionSource) -> String {
        switch source {
        case .addon: return "square.grid.2x2"
        case .tmdb: return "magnifyingglass"
        case .trakt: return "list.bullet"
        }
    }

    // MARK: Bindings

    private func text(_ keyPath: WritableKeyPath<CollectionFolder, String>) -> Binding<String> {
        Binding(
            get: { collections.folder(id: folderId)?.folder[keyPath: keyPath] ?? "" },
            set: { value in collections.updateFolder(folderId, in: collectionId) { $0[keyPath: keyPath] = value } }
        )
    }

    /// Blank clears the field rather than storing an empty string, so a cleared cover is absent
    /// from the payload instead of being an empty URL the other apps would try to load.
    private func optionalText(_ keyPath: WritableKeyPath<CollectionFolder, String?>) -> Binding<String> {
        Binding(
            get: { collections.folder(id: folderId)?.folder[keyPath: keyPath] ?? "" },
            set: { value in
                collections.updateFolder(folderId, in: collectionId) { $0[keyPath: keyPath] = value.nilIfBlank }
            }
        )
    }

    private func flag(_ keyPath: WritableKeyPath<CollectionFolder, Bool>) -> Binding<Bool> {
        Binding(
            get: { collections.folder(id: folderId)?.folder[keyPath: keyPath] ?? false },
            set: { value in collections.updateFolder(folderId, in: collectionId) { $0[keyPath: keyPath] = value } }
        )
    }

    private var shape: Binding<PosterShape> {
        Binding(
            get: { collections.folder(id: folderId)?.folder.tileShape ?? .square },
            set: { value in collections.updateFolder(folderId, in: collectionId) { $0.tileShape = value } }
        )
    }
}

extension PosterShape: SettingsOption {
    var displayName: String {
        switch self {
        case .poster: return "Poster"
        case .landscape: return "Landscape"
        case .square: return "Square"
        }
    }
}
