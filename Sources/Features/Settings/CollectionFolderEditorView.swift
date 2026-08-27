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
        SettingsSheet(title: folder?.title ?? L10n.text("settings.folder.title", fallback: "Folder")) {
            if let folder {
                SettingsCard(title: L10n.text("settings.folder.details", fallback: "Details")) {
                    SettingsTextFieldRow(title: L10n.text("settings.folder.name", fallback: "Name"), text: text(\.title))
                    SettingsTextFieldRow(
                        title: L10n.text("settings.folder.cover_emoji", fallback: "Cover emoji"),
                        subtitle: L10n.text("settings.folder.cover_emoji_sub", fallback: "Shown when there is no cover image"),
                        placeholder: "🎬",
                        text: optionalText(\.coverEmoji)
                    )
                    SettingsOptionRow(title: L10n.text("settings.folder.tile_shape", fallback: "Tile shape"), selection: shape)
                    SettingsToggle(title: L10n.text("settings.folder.hide_title", fallback: "Hide the title on the tile"), isOn: flag(\.hideTitle))
                }

                SettingsCard(
                    title: L10n.text("settings.folder.sources", fallback: "Sources"),
                    footnote: L10n.text("settings.folder.sources_footnote", fallback: "Everything these return shows up in this folder.")
                ) {
                    ForEach(folder.sources) { source in
                        SettingsRow(
                            title: describe(source),
                            subtitle: providerName(source),
                            systemImage: icon(source),
                            trailing: { SettingsValueLabel(value: L10n.text("settings.folder.remove", fallback: "Remove")) },
                            action: {
                                collections.removeSource(source, fromFolder: folderId, in: collectionId)
                            }
                        )
                    }
                    SettingsRow(title: L10n.text("settings.folder.add_catalog", fallback: "Add an addon catalog"), systemImage: "square.grid.2x2", trailing: { EmptyView() }) {
                        addingSource = .addon
                    }
                    SettingsRow(title: L10n.text("settings.folder.add_tmdb", fallback: "Add a TMDB query"), systemImage: "magnifyingglass", trailing: { EmptyView() }) {
                        addingSource = .tmdb
                    }
                    SettingsRow(title: L10n.text("settings.folder.add_trakt", fallback: "Add a Trakt list"), systemImage: "list.bullet", trailing: { EmptyView() }) {
                        addingSource = .trakt
                    }
                }

                SettingsCard(
                    title: L10n.text("settings.folder.artwork", fallback: "Artwork"),
                    footnote: """
                    Optional. The cover is the tile; the backdrop and logo are the header of the \
                    folder's own screen.
                    """
                ) {
                    SettingsTextFieldRow(title: L10n.text("settings.folder.cover_url", fallback: "Cover image URL"), text: optionalText(\.coverImageUrl))
                    SettingsTextFieldRow(title: L10n.text("settings.folder.backdrop_url", fallback: "Backdrop URL"), text: optionalText(\.heroBackdropUrl))
                    SettingsTextFieldRow(title: L10n.text("settings.folder.logo_url", fallback: "Title logo URL"), text: optionalText(\.titleLogoUrl))
                }

                SettingsCard(title: L10n.text("settings.folder.order", fallback: "Order")) {
                    SettingsRow(title: L10n.text("settings.folder.move_up", fallback: "Move up"), systemImage: "arrow.up", trailing: { EmptyView() }) {
                        collections.moveFolder(folderId, in: collectionId, by: -1)
                    }
                    SettingsRow(title: L10n.text("settings.folder.move_down", fallback: "Move down"), systemImage: "arrow.down", trailing: { EmptyView() }) {
                        collections.moveFolder(folderId, in: collectionId, by: 1)
                    }
                }

                SettingsCard(title: nil) {
                    SettingsRow(title: L10n.text("settings.folder.delete", fallback: "Delete folder"), systemImage: "trash", trailing: { EmptyView() }) {
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
        .alert(L10n.text("settings.folder.delete_title", fallback: "Delete this folder?"), isPresented: $isConfirmingDelete) {
            Button(L10n.text("settings.folder.delete_confirm", fallback: "Delete"), role: .destructive) {
                collections.deleteFolder(folderId, from: collectionId)
                dismiss()
            }
            Button(L10n.text("settings.folder.keep", fallback: "Keep"), role: .cancel) {}
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
            return "TMDB · \(tmdb.mediaType == .tv ? L10n.text("settings.folder.series", fallback: "Series") : L10n.text("settings.folder.movies", fallback: "Movies"))"
        case .trakt(let trakt):
            return "Trakt · \(trakt.mediaType == .tv ? L10n.text("settings.folder.series", fallback: "Series") : L10n.text("settings.folder.movies", fallback: "Movies"))"
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
        case .poster: return L10n.text("settings.folder.shape_poster", fallback: "Poster")
        case .landscape: return L10n.text("settings.folder.shape_landscape", fallback: "Landscape")
        case .square: return L10n.text("settings.folder.shape_square", fallback: "Square")
        }
    }
}
