import SwiftUI

/// Hands badge-rule management to a phone.
///
/// The thing being typed is a URL, and the thing being read back is a list of packs — neither is
/// remote-control work. The television serves the page, shows a QR pointing at itself, and mirrors
/// what the phone did so the viewer can see it landed without picking the phone back up.
struct StreamBadgeRulesView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    @State private var server = LocalConfigServer()
    /// What the last submission did, shown on both screens. Held here rather than in the page so
    /// the television says the same thing the phone does.
    @State private var notice: String?

    private var rules: StreamBadgeRules { settings.streamBadges.rules }

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text("Badge rules")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    editorCard
                    packsCard
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
        .task { start() }
        .onDisappear { server.stop() }
    }

    private var editorCard: some View {
        SettingsCard(title: "Manage on a phone") {
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
                            Text("Or type this in a browser")
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(colors.textTertiary)
                            Text(address)
                                .nuvioText(NuvioTextStyles.cardTitle)
                                .foregroundStyle(colors.textPrimary)
                                .monospacedDigit()
                        }
                    }
                } else {
                    Text("Starting…")
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

    private var packsCard: some View {
        SettingsCard(title: "Imported") {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
                if rules.hasImport {
                    ForEach(rules.imports) { entry in
                        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                            Text(entry.sourceUrl)
                                .nuvioText(NuvioTextStyles.cardTitle)
                                .foregroundStyle(colors.textPrimary)
                                .lineLimit(2)
                            Text(summary(for: entry))
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(entry.isActive ? colors.secondary : colors.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("No packs yet. Streams show the app's own badges until you add one.")
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textTertiary)
                }
            }
            .padding(NuvioTheme.spacing.lg)
            // The list is what a submission changes, so it has to redraw when one lands.
            .id(server.revision)
        }
    }

    private func summary(for entry: StreamBadgeImport) -> String {
        let count = entry.filters.count == 1 ? "1 rule" : "\(entry.filters.count) rules"
        let enabled = entry.enabledFilterCount == entry.filters.count
            ? ""
            : " · \(entry.enabledFilterCount) on"
        return entry.isActive ? "Applied · \(count)\(enabled)" : "\(count)\(enabled)"
    }

    private var instructions: String {
        """
        This Apple TV is serving a page on your network. Scan the code with a phone on the same \
        Wi-Fi to add a badge pack, choose which one applies, or remove one. The page closes with \
        this screen.
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
            page: { StreamBadgeRulesPage.html(rules: rules, notice: notice) },
            onSubmit: { fields in await handle(fields) }
        )
    }

    private func handle(_ fields: [String: String]) async {
        let url = fields["url"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch fields["action"] {
        case "import", "refresh":
            guard !url.isEmpty else {
                notice = "Enter a link to a badge file."
                return
            }
            do {
                let imported = try await StreamBadgeImporter.load(from: url)
                let existing = settings.streamBadges.rules
                // Re-fetching a pack that is not the applied one must not steal the selection —
                // the viewer asked to update it, not to switch to it.
                let wasKnownAndInactive = existing.imports.contains {
                    $0.sourceUrl.caseInsensitiveCompare(url) == .orderedSame && !$0.isActive
                }
                settings.streamBadges.rules = existing.upserting(
                    imported, activate: !wasKnownAndInactive
                )
                let count = imported.filters.count == 1 ? "1 rule" : "\(imported.filters.count) rules"
                notice = "Imported \(count)."
            } catch {
                notice = error.localizedDescription
            }
        case "activate":
            settings.streamBadges.rules = settings.streamBadges.rules.settingActive(url)
            notice = "Applied that pack."
        case "remove":
            settings.streamBadges.rules = settings.streamBadges.rules.removing(url)
            notice = "Removed that pack."
        default:
            break
        }
    }
}
