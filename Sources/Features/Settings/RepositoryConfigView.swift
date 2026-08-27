import SwiftUI

/// Hands plugin repository management to a phone, and keeps the decision on the television.
///
/// The phone can only *ask*. Every request lands here as a pending change and waits for whoever
/// is holding the remote — a page served to the whole local network must not be able to install
/// code that then runs against every stream request.
struct RepositoryConfigView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(PluginStore.self) private var plugins

    @State private var server = LocalConfigServer()
    @State private var pending: RepositoryConfigChange?
    @State private var notice: String?

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text(L10n.text("settings.repos.title", fallback: "Plugin repositories"))
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    editorCard
                    repositoriesCard
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
        .task { start() }
        .onDisappear { server.stop() }
        .alert(pending?.prompt ?? "", isPresented: .init(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )) {
            // Decline is first and plain; approve is the one that has to be chosen deliberately.
            Button(L10n.text("settings.repos.not_now", fallback: "Not now"), role: .cancel) { Task { await settle(approved: false) } }
            Button(L10n.text("settings.repos.allow", fallback: "Allow")) { Task { await settle(approved: true) } }
        } message: {
            if let caution = pending?.caution {
                Text(caution)
            }
        }
    }

    private var editorCard: some View {
        SettingsCard(title: L10n.text("settings.repos.manage_on_phone", fallback: "Manage on a phone")) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
                Text(instructions)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)
                    .frame(maxWidth: dp(620), alignment: .leading)

                if let failure = server.failure {
                    Text(failure)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.error)
                } else if let address = server.address {
                    HStack(alignment: .top, spacing: NuvioTheme.spacing.xl) {
                        qrCode(address)
                        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                            Text(L10n.text("settings.repos.or_type", fallback: "Or type this in a browser"))
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(colors.textTertiary)
                            Text(address)
                                .nuvioText(NuvioTextStyles.cardTitle)
                                .foregroundStyle(colors.textPrimary)
                                .monospacedDigit()
                        }
                    }
                } else {
                    Text(L10n.text("settings.repos.starting", fallback: "Starting…"))
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textTertiary)
                }

                if let notice {
                    Text(notice)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textPrimary)
                }
            }
            .padding(NuvioTheme.spacing.lg)
        }
    }

    private var repositoriesCard: some View {
        SettingsCard(title: L10n.text("settings.repos.installed", fallback: "Installed")) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
                if plugins.repositories.isEmpty {
                    Text(L10n.text("settings.repos.none_yet", fallback: "None yet."))
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textTertiary)
                } else {
                    ForEach(plugins.repositories) { repository in
                        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                            Text(repository.name)
                                .nuvioText(NuvioTextStyles.cardTitle)
                                .foregroundStyle(colors.textPrimary)
                            Text(detail(for: repository))
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(repository.enabled ? colors.textSecondary : colors.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(NuvioTheme.spacing.lg)
        }
    }

    private func detail(for repository: PluginRepository) -> String {
        let count = repository.scraperCount == 1 ? "1 scraper" : "\(repository.scraperCount) scrapers"
        return repository.enabled ? count : "\(count) · off"
    }

    private var instructions: String {
        """
        This Apple TV is serving a page on your network. Scan the code with a phone on the same \
        Wi-Fi to add or remove a repository. Nothing changes until you agree here.
        """
    }

    private func qrCode(_ address: String) -> some View {
        Group {
            if let image = QRCodeRenderer.image(for: address) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: dp(200), height: dp(200))
                    .padding(NuvioTheme.spacing.md)
                    .background {
                        RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                            .fill(.white)
                    }
            }
        }
    }

    private func start() {
        server.start(
            page: {
                RepositoryConfigPage.html(
                    rows: plugins.repositories.map {
                        .init(
                            id: $0.id, name: $0.name, manifestUrl: $0.manifestUrl,
                            detail: detail(for: $0), isEnabled: $0.enabled
                        )
                    },
                    notice: notice,
                    isWaiting: pending != nil
                )
            },
            onSubmit: { fields in handle(fields) }
        )
    }

    private func handle(_ fields: [String: String]) {
        // One at a time. A second request while the first is on screen would replace the prompt
        // the viewer is reading, which is how somebody approves the wrong thing.
        guard pending == nil else {
            notice = L10n.text("settings.repos.still_asking", fallback: "The Apple TV is still being asked about the last change.")
            return
        }
        guard let change = RepositoryConfigRequest.change(
            from: fields,
            known: plugins.repositories.map { ($0.id, $0.name, $0.enabled) }
        ) else { return }

        pending = change
        notice = change.pendingNotice
    }

    private func settle(approved: Bool) async {
        guard let change = pending else { return }
        pending = nil

        guard approved else {
            notice = change.settledNotice(approved: false)
            return
        }

        switch change.kind {
        case .add(let url):
            let added = await plugins.addRepository(url: url)
            notice = added
                ? change.settledNotice(approved: true)
                : (plugins.lastError ?? L10n.text("settings.repos.add_failed", fallback: "That repository could not be added."))
        case .remove(let id, _):
            guard let repository = plugins.repositories.first(where: { $0.id == id }) else { return }
            plugins.remove(repository)
            notice = change.settledNotice(approved: true)
        case .setEnabled(let id, _, let enabled):
            guard let repository = plugins.repositories.first(where: { $0.id == id }) else { return }
            plugins.setEnabled(enabled, repository: repository)
            notice = change.settledNotice(approved: true)
        }
    }
}
