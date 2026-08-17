import SwiftUI

// MARK: - Rail

/// One collection as a rail, with its own edit affordance at the tail.
struct CollectionRail: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(\.posterMetrics) private var metrics
    @Environment(CollectionStore.self) private var collections
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router

    let collection: MediaCollection

    @State private var isEditing = false

    private var items: [MetaPreview] {
        collections.items(in: collection.id, library: library)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.row.titleBottomSpacing) {
            HStack(spacing: NuvioTheme.spacing.md) {
                Image(systemName: collection.symbol)
                    .font(.system(size: NuvioTheme.sizes.icons.sm))
                    .foregroundStyle(colors.secondary)
                Text(collection.name)
                    .nuvioText(NuvioTextStyles.sectionTitle)
                    .foregroundStyle(colors.textPrimary)
                Text("\(collection.count) title\(collection.count == 1 ? "" : "s")")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: NuvioTheme.components.row.itemSpacing) {
                    ForEach(items, id: \.rowKey) { item in
                        ContentCard(
                            item: item,
                            allowsBackdropExpand: false,
                            action: { router.openDetail(item) }
                        )
                    }

                    Button(action: { isEditing = true }) {
                        VStack(spacing: NuvioTheme.spacing.sm) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: NuvioTheme.sizes.icons.lg))
                            Text("Edit")
                                .nuvioText(NuvioTextStyles.button)
                        }
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: metrics.width, height: metrics.height)
                        .background(colors.backgroundCard)
                    }
                    .buttonStyle(NuvioCardButtonStyle(cornerRadius: metrics.cornerRadius))
                }
                .padding(.horizontal, NuvioTheme.components.row.horizontalPadding)
                .padding(.vertical, NuvioTheme.spacing.sm)
            }
            .scrollClipDisabled()
        }
        .focusSection()
        .sheet(isPresented: $isEditing) { CollectionEditorView(collection: collection) }
    }
}

// MARK: - Editor

/// Create or edit a collection. A nil `collection` means "create".
struct CollectionEditorView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(CollectionStore.self) private var collections
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    let collection: MediaCollection?

    @State private var name = ""
    @State private var symbol = MediaCollection.availableSymbols[0]
    @State private var didLoad = false
    @State private var isConfirmingDelete = false

    private var isEditing: Bool { collection != nil }

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text(isEditing ? "Edit collection" : "New collection")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    SettingsCard(title: "Details") {
                        SettingsTextFieldRow(
                            title: "Name",
                            placeholder: "Collection name",
                            text: $name
                        )
                        symbolPicker
                    }

                    if let collection, !collection.itemKeys.isEmpty {
                        SettingsCard(
                            title: "Titles",
                            footnote: "Select a title to take it out of this collection."
                        ) {
                            ForEach(collections.items(in: collection.id, library: library), id: \.rowKey) { item in
                                SettingsRow(
                                    title: item.name,
                                    subtitle: item.releaseInfo,
                                    systemImage: "minus.circle",
                                    action: { collections.remove(item, from: collection.id) }
                                )
                            }
                        }
                    }

                    actions
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
        .onAppear(perform: loadOnce)
        .alert("Delete this collection?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                if let collection { collections.delete(collection.id) }
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The titles themselves stay in your library.")
        }
    }

    private var symbolPicker: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            Text("Icon")
                .nuvioText(NuvioTextStyles.cardTitle)
                .foregroundStyle(colors.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NuvioTheme.spacing.md) {
                    ForEach(MediaCollection.availableSymbols, id: \.self) { candidate in
                        Button(action: { symbol = candidate }) {
                            Image(systemName: candidate)
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(candidate == symbol ? colors.textInverse : colors.textSecondary)
                                .frame(width: dp(64), height: dp(64))
                                .background {
                                    Circle().fill(
                                        candidate == symbol ? colors.secondary : colors.surfaceVariant
                                    )
                                }
                        }
                        .buttonStyle(NuvioCardButtonStyle(cornerRadius: dp(32), showsRing: true, elevated: false))
                    }
                }
                .padding(.vertical, NuvioTheme.spacing.xs)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private var actions: some View {
        HStack(spacing: NuvioTheme.spacing.md) {
            Button(action: save) {
                Text(isEditing ? "Save" : "Create")
                    .nuvioText(NuvioTextStyles.button)
                    .padding(.horizontal, NuvioTheme.spacing.xl)
                    .frame(height: NuvioTheme.components.buttonHeight)
            }
            .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)

            Button(action: { dismiss() }) {
                Text("Cancel")
                    .nuvioText(NuvioTextStyles.button)
                    .padding(.horizontal, NuvioTheme.spacing.xl)
                    .frame(height: NuvioTheme.components.buttonHeight)
            }
            .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))

            if isEditing {
                Button(action: { isConfirmingDelete = true }) {
                    Text("Delete")
                        .nuvioText(NuvioTextStyles.button)
                        .padding(.horizontal, NuvioTheme.spacing.xl)
                        .frame(height: NuvioTheme.components.buttonHeight)
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .ghost))
            }
        }
        .focusSection()
    }

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        guard let collection else { return }
        name = collection.name
        symbol = collection.symbol
    }

    private func save() {
        if let collection {
            collections.rename(collection.id, to: name)
            collections.setSymbol(symbol, for: collection.id)
        } else {
            collections.create(name: name, symbol: symbol)
        }
        dismiss()
    }
}

// MARK: - Membership picker

/// "Add to collection" sheet, opened from the detail screen.
struct CollectionPickerView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(CollectionStore.self) private var collections
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    let preview: MetaPreview

    @State private var newName = ""

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text("Add to collection")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    Text(preview.name)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)

                    if collections.collections.isEmpty {
                        Text("You have no collections yet — name one below to start.")
                            .nuvioText(NuvioTextStyles.bodyCompact)
                            .foregroundStyle(colors.textTertiary)
                    } else {
                        SettingsCard(title: "Collections") {
                            ForEach(collections.collections) { collection in
                                SettingsToggle(
                                    title: collection.name,
                                    subtitle: "\(collection.count) title\(collection.count == 1 ? "" : "s")",
                                    systemImage: collection.symbol,
                                    isOn: Binding(
                                        get: { collections.contains(preview, in: collection.id) },
                                        set: { _ in
                                            collections.toggle(preview, in: collection.id, library: library)
                                        }
                                    )
                                )
                            }
                        }
                    }

                    SettingsCard(title: "New collection") {
                        SettingsTextFieldRow(
                            title: "Name",
                            placeholder: "Collection name",
                            text: $newName,
                            trailingAction: (label: "Create & add", action: createAndAdd)
                        )
                    }

                    Button(action: { dismiss() }) {
                        Text("Done")
                            .nuvioText(NuvioTextStyles.button)
                            .padding(.horizontal, NuvioTheme.spacing.xl)
                            .frame(height: NuvioTheme.components.buttonHeight)
                    }
                    .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
    }

    private func createAndAdd() {
        guard let created = collections.create(name: newName) else { return }
        collections.add(preview, to: created.id, library: library)
        newName = ""
    }
}
