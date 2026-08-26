import SwiftUI

/// Hands the stream-format editor to a phone.
///
/// The alternative is typing `{stream.size::>0["{stream.size::bytes} "||""]}` on a remote
/// control, which is not an alternative. The television serves the form and shows a QR code
/// pointing at itself; whatever the phone saves lands here and the preview updates, so the
/// viewer can see the effect on the screen the rows will actually appear on.
struct StreamFormatEditorView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    @State private var server = LocalConfigServer()

    private var templates: DebridStreamTemplates { settings.debrid.streamTemplates }

    private var preview: DebridStreamFormatter.Rendered {
        DebridStreamFormatter.render(
            stream: DebridFormatterPage.sampleStream,
            attributes: nil,
            service: settings.debrid.activeResolver?.provider ?? .realDebrid,
            isCached: true,
            templates: templates.resolved
        )
    }

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text("Stream format")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    editorCard
                    previewCard
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
        .task { start() }
        .onDisappear { server.stop() }
    }

    private var editorCard: some View {
        SettingsCard(title: "Edit on a phone") {
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
                }
                .padding(NuvioTheme.spacing.lg)
            }

    }

    private var previewCard: some View {
        SettingsCard(title: "Preview") {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                    Text(preview.name.nilIfBlank ?? "—")
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                    Text(preview.description.nilIfBlank ?? "—")
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NuvioTheme.spacing.lg)
                // The preview is what a save is *for*, so it has to redraw when one lands.
                .id(server.revision)
        }
    }

    private var instructions: String {
        """
        This Apple TV is serving a page on your network. Scan the code with a phone on the same \
        Wi-Fi, edit the name and description there, and save. The page closes with this screen.
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
            // Rebuilt on every request, so a phone that reloads sees what the last save stored
            // rather than what was on screen when this view opened.
            page: { DebridFormatterPage.html(templates: templates, preview: preview) },
            onSubmit: { fields in
                if fields["action"] == "reset" {
                    settings.debrid.streamTemplates = .default
                    return
                }
                settings.debrid.streamTemplates = DebridStreamTemplates(
                    name: fields["name"] ?? templates.name,
                    description: fields["description"] ?? templates.description
                )
            }
        )
    }
}
