import SwiftUI

/// Port of `AddonManagerScreen` — install by URL, enable/disable, reorder, remove.
struct AddonManagerView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons

    @State private var urlInput = ""
    @State private var isInstalling = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var configuring: Addon?

    /// Well-known community addons, offered as one-press installs because typing a URL on a
    /// remote is painful. Same list the Android onboarding suggests.
    private static let suggestions: [(name: String, detail: String, url: String)] = [
        ("Cinemeta", "Official Stremio catalog and metadata", "https://v3-cinemeta.strem.io"),
        ("OpenSubtitles v3", "Subtitles for movies and series", "https://opensubtitles-v3.strem.io"),
        ("Torrentio", "Torrent sources (configure for debrid)", "https://torrentio.strem.fun"),
        ("Public Domain Movies", "Freely licensed classics", "https://public-domain-movies.now.sh"),
        ("Anime Kitsu", "Anime catalog and metadata", "https://anime-kitsu.strem.fun")
    ]

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text("Addon Manager")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    installCard
                    if let message {
                        Text(message)
                            .nuvioText(NuvioTextStyles.bodyCompact)
                            .foregroundStyle(messageIsError ? colors.error : colors.success)
                    }
                    installedCard
                    suggestionsCard
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
        .task { await addons.refreshAll() }
        .sheet(item: $configuring) { addon in
            AddonConfiguratorView(addon: addon)
        }
    }

    // MARK: Install

    private var installCard: some View {
        SettingsCard(
            title: "Install from URL",
            footnote: "Paste a Stremio manifest URL. The trailing /manifest.json is optional."
        ) {
            HStack(spacing: NuvioTheme.spacing.md) {
                TextField("https://…", text: $urlInput)
                    .textFieldStyle(.plain)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .padding(.horizontal, NuvioTheme.spacing.lg)
                    .padding(.vertical, NuvioTheme.spacing.md)
                    .background {
                        RoundedRectangle(cornerRadius: NuvioTheme.shapes.field, style: .continuous)
                            .fill(colors.field)
                    }

                Button(action: { Task { await install(urlInput) } }) {
                    Text(isInstalling ? "Installing…" : "Install")
                        .nuvioText(NuvioTextStyles.button)
                        .padding(.horizontal, NuvioTheme.spacing.xl)
                        .frame(height: NuvioTheme.components.buttonHeight)
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))
                .disabled(isInstalling || urlInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, NuvioTheme.spacing.lg)
            .padding(.vertical, NuvioTheme.spacing.sm)
        }
    }

    // MARK: Installed

    private var installedCard: some View {
        SettingsCard(title: "Installed (\(addons.installed.count))") {
            if addons.installed.isEmpty {
                Text("No addons installed.")
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)
                    .padding(NuvioTheme.spacing.lg)
            } else {
                ForEach(Array(addons.installed.enumerated()), id: \.element.id) { index, record in
                    AddonRow(
                        record: record,
                        isFirst: index == 0,
                        isLast: index == addons.installed.count - 1,
                        onToggle: { addons.setEnabled(!record.enabled, baseUrl: record.baseUrl) },
                        onMoveUp: { addons.moveAddon(baseUrl: record.baseUrl, by: -1) },
                        onMoveDown: { addons.moveAddon(baseUrl: record.baseUrl, by: 1) },
                        onRemove: { addons.uninstall(baseUrl: record.baseUrl) },
                        onConfigure: { configuring = record.manifest },
                        onRename: { addons.rename(baseUrl: record.baseUrl, to: $0) }
                    )
                }
            }
        }
    }

    // MARK: Suggestions

    private var suggestionsCard: some View {
        SettingsCard(title: "Popular addons") {
            ForEach(Self.suggestions, id: \.url) { suggestion in
                let installed = addons.installed.contains {
                    $0.baseUrl.caseInsensitiveCompare(StremioURL.canonicalize(suggestion.url)) == .orderedSame
                }
                SettingsRow(
                    title: suggestion.name,
                    subtitle: suggestion.detail,
                    systemImage: "shippingbox.fill",
                    trailing: {
                        Text(installed ? "Installed" : "Install")
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(installed ? colors.success : colors.secondary)
                    },
                    action: {
                        guard !installed else { return }
                        Task { await install(suggestion.url) }
                    }
                )
            }
        }
    }

    private func install(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isInstalling = true
        defer { isInstalling = false }

        switch await addons.install(url: trimmed) {
        case .success(let addon):
            message = "Installed \(addon.displayName) v\(addon.version)."
            messageIsError = false
            urlInput = ""
        case .failure(let error):
            message = error.localizedDescription
            messageIsError = true
        }
    }
}

// MARK: - Row

private struct AddonRow: View {
    @Environment(\.nuvioColors) private var colors

    let record: InstalledAddon
    let isFirst: Bool
    let isLast: Bool
    let onToggle: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void
    let onConfigure: () -> Void
    let onRename: (String?) -> Void

    @State private var isRenaming = false
    @State private var draftName = ""

    private var manifest: Addon? { record.manifest }

    /// Only addons that advertise a configure page get the affordance.
    private var isConfigurable: Bool {
        manifest?.behaviorHints?.configurable == true
    }

    var body: some View {
        HStack(spacing: NuvioTheme.spacing.lg) {
            logo

            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                Text(manifest?.displayName ?? record.baseUrl)
                    .nuvioText(NuvioTextStyles.cardTitle)
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(1)

                Text(detailLine)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: NuvioTheme.spacing.lg)

            HStack(spacing: NuvioTheme.spacing.sm) {
                IconAction(systemImage: "pencil", tint: colors.secondary) {
                    draftName = record.userSetName ?? manifest?.displayName ?? ""
                    isRenaming = true
                }
                if isConfigurable {
                    IconAction(systemImage: "slider.horizontal.3", tint: colors.secondary, action: onConfigure)
                }
                IconAction(systemImage: record.enabled ? "checkmark.circle.fill" : "circle",
                           tint: record.enabled ? colors.success : colors.textTertiary,
                           action: onToggle)
                IconAction(systemImage: "arrow.up", tint: colors.textSecondary, action: onMoveUp)
                    .disabled(isFirst)
                    .opacity(isFirst ? NuvioTheme.effects.disabledAlpha : 1)
                IconAction(systemImage: "arrow.down", tint: colors.textSecondary, action: onMoveDown)
                    .disabled(isLast)
                    .opacity(isLast ? NuvioTheme.effects.disabledAlpha : 1)
                IconAction(systemImage: "trash", tint: colors.error, action: onRemove)
            }
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.components.settings.secondaryCardRadius, style: .continuous)
                .fill(colors.surface.opacity(0.6))
        }
        .opacity(record.enabled ? 1 : 0.6)
        .sheet(isPresented: $isRenaming) {
            RenameSheet(
                heading: "Rename addon",
                explanation: "Shown wherever this addon is named — rails, stream groups, settings.",
                placeholder: "Addon name",
                draft: $draftName,
                onSave: {
                    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    // The manifest's own name typed back means "no override", so refetching the
                    // manifest keeps taking effect.
                    onRename(trimmed.isEmpty || trimmed == manifest?.displayName ? nil : trimmed)
                    isRenaming = false
                },
                onReset: {
                    onRename(nil)
                    isRenaming = false
                }
            )
        }
    }

    private var logo: some View {
        RemoteImage(url: manifest?.logo, contentMode: .fit) {
            ZStack {
                colors.surfaceVariant
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: NuvioTheme.sizes.icons.md))
                    .foregroundStyle(colors.textTertiary)
            }
        }
        .frame(width: NuvioTheme.sizes.avatars.md, height: NuvioTheme.sizes.avatars.md)
        .clipShape(RoundedRectangle(cornerRadius: NuvioTheme.radii.sm, style: .continuous))
    }

    private var detailLine: String {
        guard let manifest else { return "Manifest not loaded — \(record.baseUrl)" }
        var parts: [String] = ["v\(manifest.version)"]
        if !manifest.catalogs.isEmpty { parts.append("\(manifest.catalogs.count) catalogs") }
        let resources = manifest.resources.map(\.name).joined(separator: ", ")
        if !resources.isEmpty { parts.append(resources) }
        return parts.joined(separator: " · ")
    }
}

private struct IconAction: View {
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: NuvioTheme.sizes.icons.sm, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: dp(44), height: dp(44))
                .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.full, scaleOnFocus: true))
    }
}

// MARK: - Catalog order (port of CatalogOrderScreen)

struct CatalogOrderView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(CollectionStore.self) private var collections

    /// Only unpinned collections are orderable here. A pinned one is above every catalogue by
    /// definition, so a position among them would be a control with nothing behind it — the
    /// row says so instead of pretending.
    private var orderableCollectionIds: [String] {
        CollectionStore.homePlacement(collections.collections).trailing.map(\.id)
    }

    private var rows: [CatalogOrderEntry] { addons.catalogOrder }

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text("Catalog Order")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    SettingsCard(
                        title: "Home rows",
                        footnote: """
                        Collections sit in this list alongside catalogs, so one can go anywhere \
                        between them. Disabled catalogs stay available in Discover. A collection \
                        pinned above the catalogs is not listed here — pinning already decides \
                        where it goes.
                        """
                    ) {
                        let entries = rows
                        if entries.isEmpty {
                            Text("Nothing to order yet — install an addon that provides a catalog.")
                                .nuvioText(NuvioTextStyles.bodyCompact)
                                .foregroundStyle(colors.textSecondary)
                                .padding(NuvioTheme.spacing.lg)
                        } else {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                CatalogOrderRow(
                                    entry: entry,
                                    label: label(for: entry),
                                    isFirst: index == 0,
                                    isLast: index == entries.count - 1,
                                    collectionIds: orderableCollectionIds
                                )
                            }
                        }
                    }
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
        // A collection created since the last visit has no row yet, and one that was deleted
        // still has a stale one. Reconciled here rather than in the body, which would write to
        // the store while SwiftUI is evaluating it.
        .onAppear { addons.syncHomeOrder(collectionIds: orderableCollectionIds) }
    }

    private func label(for entry: CatalogOrderEntry) -> (title: String, subtitle: String) {
        if let collectionId = entry.collectionId {
            guard let collection = collections.collection(id: collectionId) else {
                return ("Collection", "No longer exists")
            }
            let count = collection.folders.count
            return (collection.title, "Collection · \(count) folder\(count == 1 ? "" : "s")")
        }
        guard let addon = addons.addon(withBaseUrl: entry.addonBaseUrl) else {
            return (entry.catalogKey, entry.addonBaseUrl)
        }
        let catalog = addon.catalogs.first { $0.descriptorKey == entry.catalogKey }
        return (catalog?.name ?? entry.catalogKey, "\(addon.displayName) · \(catalog?.apiType ?? "")")
    }
}

private struct CatalogOrderRow: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(AppSettings.self) private var settings

    let entry: CatalogOrderEntry
    let label: (title: String, subtitle: String)
    let isFirst: Bool
    let isLast: Bool
    let collectionIds: [String]

    @State private var isRenaming = false
    @State private var draftTitle = ""

    /// Renaming and hero nomination are catalogue ideas. A collection is named in its own editor
    /// and cannot be a hero source, so those two actions are not drawn for one rather than drawn
    /// and refused.
    private var isCollection: Bool { entry.collectionId != nil }

    /// Key shared with `CatalogPresentation` and `CatalogRowState.id`, so a rename or a hero
    /// nomination made here lands on the right rail.
    private var presentationKey: String {
        CatalogPresentation.titleKey(
            addonBaseUrl: StremioURL.canonicalize(entry.addonBaseUrl),
            descriptorKey: entry.catalogKey
        )
    }

    private var customTitle: String? {
        settings.layout.customCatalogTitles[presentationKey]?.nilIfBlank
    }

    private var isHeroSource: Bool {
        settings.layout.heroCatalogKeys.contains(presentationKey)
    }

    var body: some View {
        HStack(spacing: NuvioTheme.spacing.lg) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                Text(customTitle ?? label.title)
                    .nuvioText(NuvioTextStyles.cardTitle)
                    .foregroundStyle(colors.textPrimary)
                Text(customTitle == nil ? label.subtitle : "\(label.subtitle) · renamed from “\(label.title)”")
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
            }

            Spacer(minLength: NuvioTheme.spacing.lg)

            HStack(spacing: NuvioTheme.spacing.sm) {
                if !isCollection {
                    IconAction(
                        systemImage: isHeroSource ? "star.fill" : "star",
                        tint: isHeroSource ? colors.rating : colors.textTertiary,
                        action: toggleHero
                    )
                    IconAction(
                        systemImage: "pencil",
                        tint: colors.textSecondary,
                        action: {
                            draftTitle = customTitle ?? label.title
                            isRenaming = true
                        }
                    )
                }
                IconAction(
                    systemImage: entry.enabled ? "eye.fill" : "eye.slash",
                    tint: entry.enabled ? colors.success : colors.textTertiary,
                    action: { addons.setRowEnabled(!entry.enabled, key: entry.rowKey) }
                )
                IconAction(systemImage: "arrow.up", tint: colors.textSecondary, action: {
                    addons.moveRow(entry.rowKey, by: -1, collectionIds: collectionIds)
                })
                .disabled(isFirst)
                .opacity(isFirst ? NuvioTheme.effects.disabledAlpha : 1)
                IconAction(systemImage: "arrow.down", tint: colors.textSecondary, action: {
                    addons.moveRow(entry.rowKey, by: 1, collectionIds: collectionIds)
                })
                .disabled(isLast)
                .opacity(isLast ? NuvioTheme.effects.disabledAlpha : 1)
            }
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NuvioTheme.components.settings.secondaryCardRadius, style: .continuous)
                .fill(colors.surface.opacity(0.6))
        }
        .opacity(entry.enabled ? 1 : 0.6)
        .sheet(isPresented: $isRenaming) {
            RenameSheet(
                heading: "Rename rail",
                explanation: "Shown instead of “\(label.title)” on Home.",
                placeholder: "Rail title",
                draft: $draftTitle,
                onSave: saveTitle,
                onReset: resetTitle
            )
        }
    }

    private func toggleHero() {
        var keys = settings.layout.heroCatalogKeys
        if let index = keys.firstIndex(of: presentationKey) {
            keys.remove(at: index)
        } else {
            keys.append(presentationKey)
        }
        settings.layout.heroCatalogKeys = keys
    }

    private func saveTitle() {
        var titles = settings.layout.customCatalogTitles
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field, or the original name typed back, means "no override".
        if trimmed.isEmpty || trimmed == label.title {
            titles.removeValue(forKey: presentationKey)
        } else {
            titles[presentationKey] = trimmed
        }
        settings.layout.customCatalogTitles = titles
        isRenaming = false
    }

    private func resetTitle() {
        var titles = settings.layout.customCatalogTitles
        titles.removeValue(forKey: presentationKey)
        settings.layout.customCatalogTitles = titles
        isRenaming = false
    }
}

/// Rename dialog, shared by rails and addons. tvOS presents the system keyboard for the field,
/// so the sheet only has to hold the field plus the two actions.
private struct RenameSheet: View {
    @Environment(\.nuvioColors) private var colors

    let heading: String
    let explanation: String
    let placeholder: String
    @Binding var draft: String
    let onSave: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
            Text(heading)
                .nuvioText(NuvioTextStyles.headline)
                .foregroundStyle(colors.textPrimary)

            Text(explanation)
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textSecondary)

            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .nuvioText(NuvioTextStyles.body)
                .padding(.horizontal, NuvioTheme.spacing.lg)
                .padding(.vertical, NuvioTheme.spacing.md)
                .background {
                    RoundedRectangle(cornerRadius: NuvioTheme.shapes.field, style: .continuous)
                        .fill(colors.field)
                }

            HStack(spacing: NuvioTheme.spacing.md) {
                Button(action: onSave) {
                    Text("Save")
                        .nuvioText(NuvioTextStyles.button)
                        .padding(.horizontal, NuvioTheme.spacing.xl)
                        .frame(height: NuvioTheme.components.buttonHeight)
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))

                Button(action: onReset) {
                    Text("Use original")
                        .nuvioText(NuvioTextStyles.button)
                        .padding(.horizontal, NuvioTheme.spacing.xl)
                        .frame(height: NuvioTheme.components.buttonHeight)
                }
                .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
            }
        }
        .padding(NuvioTheme.components.dialog.contentPadding)
        .frame(maxWidth: NuvioTheme.components.dialog.maxWidth)
    }
}
