import SwiftUI

/// Port of `AddonManagerScreen` — install by URL, enable/disable, reorder, remove.
struct AddonManagerView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons

    @State private var urlInput = ""
    @State private var isInstalling = false
    @State private var message: String?
    @State private var messageIsError = false

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
                        onRemove: { addons.uninstall(baseUrl: record.baseUrl) }
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

    private var manifest: Addon? { record.manifest }

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

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text("Catalog Order")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    SettingsCard(
                        title: "Home catalogs",
                        footnote: "Disabled catalogs stay available in Discover."
                    ) {
                        if addons.catalogOrder.isEmpty {
                            Text("No catalogs available yet — install an addon that provides one.")
                                .nuvioText(NuvioTextStyles.bodyCompact)
                                .foregroundStyle(colors.textSecondary)
                                .padding(NuvioTheme.spacing.lg)
                        } else {
                            ForEach(Array(addons.catalogOrder.enumerated()), id: \.element.id) { index, entry in
                                CatalogOrderRow(
                                    entry: entry,
                                    label: label(for: entry),
                                    isFirst: index == 0,
                                    isLast: index == addons.catalogOrder.count - 1
                                )
                            }
                        }
                    }
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
    }

    private func label(for entry: CatalogOrderEntry) -> (title: String, subtitle: String) {
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

    let entry: CatalogOrderEntry
    let label: (title: String, subtitle: String)
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(spacing: NuvioTheme.spacing.lg) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                Text(label.title)
                    .nuvioText(NuvioTextStyles.cardTitle)
                    .foregroundStyle(colors.textPrimary)
                Text(label.subtitle)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textSecondary)
            }

            Spacer(minLength: NuvioTheme.spacing.lg)

            HStack(spacing: NuvioTheme.spacing.sm) {
                IconAction(
                    systemImage: entry.enabled ? "eye.fill" : "eye.slash",
                    tint: entry.enabled ? colors.success : colors.textTertiary,
                    action: {
                        addons.setCatalogEnabled(!entry.enabled, addonBaseUrl: entry.addonBaseUrl, catalogKey: entry.catalogKey)
                    }
                )
                IconAction(systemImage: "arrow.up", tint: colors.textSecondary, action: {
                    addons.moveCatalog(addonBaseUrl: entry.addonBaseUrl, catalogKey: entry.catalogKey, by: -1)
                })
                .disabled(isFirst)
                .opacity(isFirst ? NuvioTheme.effects.disabledAlpha : 1)
                IconAction(systemImage: "arrow.down", tint: colors.textSecondary, action: {
                    addons.moveCatalog(addonBaseUrl: entry.addonBaseUrl, catalogKey: entry.catalogKey, by: 1)
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
    }
}
