import SwiftUI

/// Plugins section: install scraper repositories, toggle individual scrapers, refresh.
struct PluginsSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @Environment(PluginStore.self) private var plugins

    @State private var urlInput = ""
    @State private var message: String?

    var body: some View {
        @Bindable var player = settings.player

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(
                title: "Local scrapers",
                footnote: """
                Plugins are JavaScript scrapers from a repository's manifest.json. They run in a \
                sandboxed JS engine with no access to your device, and their results appear \
                alongside addon streams.
                """
            ) {
                SettingsToggle(
                    title: "Enable plugins",
                    systemImage: "puzzlepiece.fill",
                    isOn: $player.pluginsEnabled
                )
                SettingsToggle(
                    title: "Group results by repository",
                    subtitle: "Otherwise plugin streams share one section",
                    isOn: $player.groupPluginStreamsByRepository
                )
            }

            SettingsCard(
                title: "Add repository",
                footnote: "Paste a repository URL. The trailing /manifest.json is optional."
            ) {
                SettingsTextFieldRow(
                    title: "Repository URL",
                    placeholder: "https://…",
                    text: $urlInput,
                    trailingAction: (label: plugins.isBusy ? "Adding…" : "Add", action: add)
                )
            }

            if let message = message ?? plugins.lastError {
                Text(message)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(message.hasPrefix("Added") ? colors.success : colors.error)
            }

            if plugins.repositories.isEmpty {
                Text("No plugin repositories installed.")
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)
            } else {
                ForEach(plugins.repositories) { repository in
                    RepositoryCard(repository: repository)
                }
            }
        }
    }

    private func add() {
        let url = urlInput
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        message = nil
        Task {
            if await plugins.addRepository(url: url) {
                message = "Added."
                urlInput = ""
            }
        }
    }
}

private struct RepositoryCard: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(PluginStore.self) private var plugins

    let repository: PluginRepository

    private var scrapers: [InstalledScraper] {
        plugins.scrapers(inRepository: repository.id)
    }

    var body: some View {
        SettingsCard(title: repository.name, footnote: footnote) {
            SettingsToggle(
                title: "Enabled",
                subtitle: "\(scrapers.count) scraper\(scrapers.count == 1 ? "" : "s") downloaded",
                systemImage: "power",
                isOn: Binding(
                    get: { repository.enabled },
                    set: { plugins.setEnabled($0, repository: repository) }
                )
            )

            ForEach(scrapers) { scraper in
                SettingsToggle(
                    title: scraper.name,
                    subtitle: scraperSubtitle(scraper),
                    isOn: Binding(
                        get: { scraper.enabled },
                        set: { plugins.setEnabled($0, scraper: scraper) }
                    )
                )
                // A scraper the repository author disabled cannot be switched on here.
                .disabled(!scraper.manifestEnabled)
                .opacity(scraper.manifestEnabled ? 1 : NuvioTheme.effects.disabledAlpha)
            }

            SettingsRow(
                title: "Refresh",
                subtitle: "Re-read the manifest and re-download scrapers",
                systemImage: "arrow.clockwise",
                action: { Task { await plugins.refresh(repository) } }
            )
            SettingsRow(
                title: "Remove",
                subtitle: "Delete this repository and its scrapers",
                systemImage: "trash",
                action: { plugins.remove(repository) }
            )
        }
    }

    private var footnote: String {
        var parts: [String] = []
        if let author = repository.author?.nilIfBlank { parts.append("by \(author)") }
        if let version = repository.version?.nilIfBlank { parts.append("v\(version)") }
        if let updated = repository.lastUpdated {
            parts.append("updated \(DateFormatter.nuvioMediumDate.string(from: updated))")
        }
        return parts.joined(separator: " · ")
    }

    private func scraperSubtitle(_ scraper: InstalledScraper) -> String {
        var parts: [String] = []
        if !scraper.manifestEnabled { parts.append("Disabled by the repository") }
        if let version = scraper.version?.nilIfBlank { parts.append("v\(version)") }
        if !scraper.supportedTypes.isEmpty {
            parts.append(scraper.supportedTypes.joined(separator: ", "))
        }
        if !scraper.contentLanguage.isEmpty {
            parts.append(scraper.contentLanguage.joined(separator: "/"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Pushed screen wrapper — Content & Discovery opens plugins as its own page, matching the
/// Android navigation rather than nesting a manager inside the settings workspace.
struct PluginManagerView: View {
    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    PluginsSettingsContent()
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
    }
}
