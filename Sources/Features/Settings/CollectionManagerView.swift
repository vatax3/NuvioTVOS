import SwiftUI

/// Where collections are built.
///
/// This sits with Add-ons and Plugins rather than in the Library, because that is what it is:
/// choosing which catalogues, TMDB queries and Trakt lists a folder stands for. The Library
/// browses the result.
struct CollectionManagerView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(CollectionStore.self) private var collections
    @Environment(Router.self) private var router

    @State private var editing: MediaCollection?
    @State private var isCreating = false
    @State private var newTitle = ""
    @State private var transfer: TransferSheet?

    private enum TransferSheet: String, Identifiable {
        case importing, exporting
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                Text(L10n.text("settings.collections.title", fallback: "Collections"))
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

                SettingsCard(
                    title: L10n.text("settings.collections.yours", fallback: "Your collections"),
                    footnote: """
                    A collection holds folders, and a folder is a live query — an addon catalog, \
                    a TMDB search, a Trakt list. Collections appear on Home as a row of their \
                    folders, and sync with the Android and mobile apps.
                    """
                ) {
                    ForEach(collections.collections) { collection in
                        SettingsRow(
                            title: collection.title,
                            subtitle: subtitle(for: collection),
                            systemImage: collection.pinToTop ? "pin.fill" : "folder",
                            trailing: { SettingsValueLabel(value: "") },
                            action: { editing = collection }
                        )
                    }
                    SettingsRow(
                        title: L10n.text("settings.collections.new", fallback: "New collection"),
                        systemImage: "plus",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { newTitle = ""; isCreating = true }
                    )
                }

                SettingsCard(
                    title: L10n.text("settings.collections.transfer", fallback: "Transfer"),
                    footnote: L10n.text("settings.collections.transfer_footnote", fallback: "The same JSON the other Nuvio apps import and export.")
                ) {
                    SettingsRow(
                        title: L10n.text("settings.collections.import", fallback: "Import from JSON"),
                        subtitle: L10n.text("settings.collections.import_sub", fallback: "Replaces every collection on this device"),
                        systemImage: "square.and.arrow.down",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { transfer = .importing }
                    )
                    SettingsRow(
                        title: L10n.text("settings.collections.export", fallback: "Export to JSON"),
                        subtitle: "\(collections.collections.count) collection\(collections.collections.count == 1 ? "" : "s")",
                        systemImage: "square.and.arrow.up",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { transfer = .exporting }
                    )
                }
            }
            .padding(.vertical, NuvioTheme.layout.tvSafeVertical)
        }
        .scrollClipDisabled()
        .background(colors.background)
        .sheet(item: $editing) { collection in
            CollectionEditorView(collectionId: collection.id)
        }
        .sheet(isPresented: $isCreating) { createSheet }
        .sheet(item: $transfer) { sheet in
            CollectionTransferView(mode: sheet == .importing ? .importing : .exporting)
        }
    }

    private func subtitle(for collection: MediaCollection) -> String {
        let folders = collection.folders.count
        let sources = collection.folders.reduce(0) { $0 + $1.sources.count }
        return "\(folders) folder\(folders == 1 ? "" : "s") · \(sources) source\(sources == 1 ? "" : "s")"
    }

    private var createSheet: some View {
        SettingsSheet(title: L10n.text("settings.collections.new", fallback: "New collection")) {
            SettingsCard(title: nil) {
                SettingsTextFieldRow(
                    title: L10n.text("settings.collections.name", fallback: "Name"),
                    placeholder: L10n.text("settings.collections.name_hint", fallback: "Saturday night"),
                    text: $newTitle,
                    trailingAction: (
                        label: L10n.text("settings.collections.create", fallback: "Create"),
                        action: {
                            collections.create(title: newTitle)
                            isCreating = false
                        }
                    )
                )
            }
        }
    }
}

// MARK: - Editor

/// Edits one collection: its own settings, then its folders.
///
/// Keyed by id rather than holding the value, so every mutation reads back from the store and
/// two sheets deep into folders and sources cannot drift from what was saved.
struct CollectionEditorView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @Environment(CollectionStore.self) private var collections

    let collectionId: String

    @State private var editingFolder: CollectionFolder?
    @State private var isAddingFolder = false
    @State private var newFolderTitle = ""
    @State private var isConfirmingDelete = false

    private var collection: MediaCollection? { collections.collection(id: collectionId) }

    var body: some View {
        SettingsSheet(title: collection?.title ?? L10n.text("settings.collections.singular", fallback: "Collection")) {
            if let collection {
                SettingsCard(title: L10n.text("settings.collections.details", fallback: "Details")) {
                    SettingsTextFieldRow(
                        title: L10n.text("settings.collections.name", fallback: "Name"),
                        text: Binding(
                            get: { collection.title },
                            set: { collections.rename(collectionId, to: $0) }
                        )
                    )
                    SettingsToggle(
                        title: L10n.text("settings.collections.pin", fallback: "Pin above catalogs"),
                        subtitle: L10n.text("settings.collections.pin_sub", fallback: "Show this collection above every home catalog. Several pinned collections keep the order you created them in."),
                        isOn: binding(\.pinToTop)
                    )
                    SettingsToggle(
                        title: L10n.text("settings.collections.all_tab", fallback: "Show an “All” tab"),
                        subtitle: L10n.text("settings.collections.all_tab_sub", fallback: "Every folder's items together"),
                        isOn: binding(\.showAllTab)
                    )
                    SettingsOptionRow(
                        title: L10n.text("settings.collections.folder_layout", fallback: "Folder layout"),
                        selection: Binding(
                            get: { collection.viewMode },
                            set: { mode in collections.update(collectionId) { $0.viewMode = mode } }
                        )
                    )
                }

                SettingsCard(
                    title: L10n.text("settings.collections.folders", fallback: "Folders"),
                    footnote: L10n.text("settings.collections.folders_footnote", fallback: "Each folder becomes one tile in this collection's row on Home.")
                ) {
                    ForEach(collection.folders) { folder in
                        SettingsRow(
                            title: folder.title,
                            subtitle: "\(folder.sources.count) source\(folder.sources.count == 1 ? "" : "s")",
                            systemImage: folder.coverEmoji == nil ? "folder" : nil,
                            trailing: { SettingsValueLabel(value: folder.coverEmoji ?? "") },
                            action: { editingFolder = folder }
                        )
                    }
                    SettingsRow(
                        title: L10n.text("settings.collections.add_folder", fallback: "Add folder"),
                        systemImage: "plus",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { newFolderTitle = ""; isAddingFolder = true }
                    )
                }

                if collections.collections.count > 1 {
                    SettingsCard(title: L10n.text("settings.collections.order", fallback: "Order"), footnote: L10n.text("settings.collections.order_footnote", fallback: "Where this collection sits on Home.")) {
                        SettingsRow(title: L10n.text("settings.collections.move_up", fallback: "Move up"), systemImage: "arrow.up", trailing: { EmptyView() }) {
                            collections.move(collectionId, by: -1)
                        }
                        SettingsRow(title: L10n.text("settings.collections.move_down", fallback: "Move down"), systemImage: "arrow.down", trailing: { EmptyView() }) {
                            collections.move(collectionId, by: 1)
                        }
                    }
                }

                SettingsCard(title: nil) {
                    SettingsRow(
                        title: L10n.text("settings.collections.delete", fallback: "Delete collection"),
                        systemImage: "trash",
                        trailing: { EmptyView() },
                        action: { isConfirmingDelete = true }
                    )
                }
            }
        }
        .sheet(item: $editingFolder) { folder in
            CollectionFolderEditorView(collectionId: collectionId, folderId: folder.id)
        }
        .sheet(isPresented: $isAddingFolder) {
            SettingsSheet(title: L10n.text("settings.collections.new_folder", fallback: "New folder")) {
                SettingsCard(title: nil) {
                    SettingsTextFieldRow(
                        title: L10n.text("settings.collections.name", fallback: "Name"),
                        placeholder: L10n.text("settings.collections.folder_hint", fallback: "Comedies"),
                        text: $newFolderTitle,
                        trailingAction: (
                            label: L10n.text("settings.collections.add", fallback: "Add"),
                            action: {
                                collections.addFolder(title: newFolderTitle, to: collectionId)
                                isAddingFolder = false
                            }
                        )
                    )
                }
            }
        }
        .alert(L10n.text("settings.collections.delete_title", fallback: "Delete this collection?"), isPresented: $isConfirmingDelete) {
            Button(L10n.text("settings.collections.delete_confirm", fallback: "Delete"), role: .destructive) {
                collections.delete(collectionId)
                dismiss()
            }
            Button(L10n.text("settings.collections.keep", fallback: "Keep"), role: .cancel) {}
        } message: {
            Text(L10n.text("settings.collections.delete_message", fallback: "Its folders and their sources go with it. Nothing in your library is touched."))
        }
    }

    private func binding(_ keyPath: WritableKeyPath<MediaCollection, Bool>) -> Binding<Bool> {
        Binding(
            get: { collections.collection(id: collectionId)?[keyPath: keyPath] ?? false },
            set: { value in collections.update(collectionId) { $0[keyPath: keyPath] = value } }
        )
    }
}

extension CollectionViewMode: SettingsOption {
    var displayName: String {
        switch self {
        case .tabbedGrid: return L10n.text("settings.collections.grid_tabs", fallback: "Grid with tabs")
        case .rows: return L10n.text("settings.collections.rows", fallback: "Rows")
        case .followLayout: return L10n.text("settings.collections.follow_layout", fallback: "Follow my layout")
        }
    }
}
