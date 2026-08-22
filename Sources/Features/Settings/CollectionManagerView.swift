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
                Text("Collections")
                    .nuvioText(NuvioTextStyles.display)
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

                SettingsCard(
                    title: "Your collections",
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
                        title: "New collection",
                        systemImage: "plus",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { newTitle = ""; isCreating = true }
                    )
                }

                SettingsCard(
                    title: "Transfer",
                    footnote: "The same JSON the other Nuvio apps import and export."
                ) {
                    SettingsRow(
                        title: "Import from JSON",
                        subtitle: "Replaces every collection on this device",
                        systemImage: "square.and.arrow.down",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { transfer = .importing }
                    )
                    SettingsRow(
                        title: "Export to JSON",
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
        SettingsSheet(title: "New collection") {
            SettingsCard(title: nil) {
                SettingsTextFieldRow(
                    title: "Name",
                    placeholder: "Saturday night",
                    text: $newTitle,
                    trailingAction: (
                        label: "Create",
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
        SettingsSheet(title: collection?.title ?? "Collection") {
            if let collection {
                SettingsCard(title: "Details") {
                    SettingsTextFieldRow(
                        title: "Name",
                        text: Binding(
                            get: { collection.title },
                            set: { collections.rename(collectionId, to: $0) }
                        )
                    )
                    SettingsToggle(
                        title: "Pin above catalogs",
                        subtitle: "Show this collection above every home catalog. Several pinned collections keep the order you created them in.",
                        isOn: binding(\.pinToTop)
                    )
                    SettingsToggle(
                        title: "Show an “All” tab",
                        subtitle: "Every folder's items together",
                        isOn: binding(\.showAllTab)
                    )
                    SettingsOptionRow(
                        title: "Folder layout",
                        selection: Binding(
                            get: { collection.viewMode },
                            set: { mode in collections.update(collectionId) { $0.viewMode = mode } }
                        )
                    )
                }

                SettingsCard(
                    title: "Folders",
                    footnote: "Each folder becomes one tile in this collection's row on Home."
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
                        title: "Add folder",
                        systemImage: "plus",
                        trailing: { SettingsValueLabel(value: "") },
                        action: { newFolderTitle = ""; isAddingFolder = true }
                    )
                }

                if collections.collections.count > 1 {
                    SettingsCard(title: "Order", footnote: "Where this collection sits on Home.") {
                        SettingsRow(title: "Move up", systemImage: "arrow.up", trailing: { EmptyView() }) {
                            collections.move(collectionId, by: -1)
                        }
                        SettingsRow(title: "Move down", systemImage: "arrow.down", trailing: { EmptyView() }) {
                            collections.move(collectionId, by: 1)
                        }
                    }
                }

                SettingsCard(title: nil) {
                    SettingsRow(
                        title: "Delete collection",
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
            SettingsSheet(title: "New folder") {
                SettingsCard(title: nil) {
                    SettingsTextFieldRow(
                        title: "Name",
                        placeholder: "Comedies",
                        text: $newFolderTitle,
                        trailingAction: (
                            label: "Add",
                            action: {
                                collections.addFolder(title: newFolderTitle, to: collectionId)
                                isAddingFolder = false
                            }
                        )
                    )
                }
            }
        }
        .alert("Delete this collection?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                collections.delete(collectionId)
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Its folders and their sources go with it. Nothing in your library is touched.")
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
        case .tabbedGrid: return "Grid with tabs"
        case .rows: return "Rows"
        case .followLayout: return "Follow my layout"
        }
    }
}
