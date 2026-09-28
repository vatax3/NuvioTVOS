import SwiftUI

/// Sets the custom theme's accent from a phone, and shows what it produces on the television.
///
/// Fifth page on `LocalConfigServer`, and the reason it is a page rather than a picker is the one
/// upstream's colour picker runs into: choosing a hue with a D-pad is slow and imprecise, which is
/// why most people never touch such a control. A hex field on a phone — with the browser's own
/// colour picker beside it — is the same choice made in two seconds.
///
/// The preview is the point of doing it here rather than only there. A palette derived from one
/// colour has to be *looked at* on the screen it will be used on: an accent that reads well on a
/// phone can be unreadable as focus on a television across a room.
struct CustomThemeView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    @State private var server = LocalConfigServer()

    private var accentHex: String { settings.app.customThemeAccentHex }
    private var palette: ThemeColorPalette {
        CustomThemePalette.palette(accentHex: accentHex)
    }

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text(L10n.text("settings.appearance.custom_theme", fallback: "Custom"))
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
        SettingsCard(title: L10n.text("settings.appearance.set_on_phone", fallback: "Set from a phone")) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
                Text(L10n.text(
                    "settings.appearance.custom_instructions",
                    fallback: """
                    This Apple TV is serving a page on your network. Scan the code with a phone on \
                    the same Wi-Fi and pick a colour there. The rest of the palette follows from \
                    it, the way each built-in theme's does.
                    """
                ))
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
                            Text(L10n.text("settings.poster.or_type", fallback: "Or type this in a browser"))
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(colors.textTertiary)
                            Text(address)
                                .nuvioText(NuvioTextStyles.cardTitle)
                                .foregroundStyle(colors.textPrimary)
                                .monospacedDigit()
                        }
                    }
                } else {
                    Text(L10n.text("settings.poster.starting", fallback: "Starting…"))
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textTertiary)
                }
            }
            .padding(NuvioTheme.spacing.lg)
        }
    }

    /// The derived palette, at the size and distance it will actually be seen from.
    private var previewCard: some View {
        SettingsCard(
            title: L10n.text("settings.appearance.custom_preview", fallback: "Preview"),
            footnote: L10n.text(
                "settings.appearance.custom_preview_footnote",
                fallback: "The focus ring is the one to judge — it is what tells you where you are."
            )
        ) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
                Text("#\(accentHex)")
                    .nuvioText(NuvioTextStyles.cardTitle)
                    .foregroundStyle(colors.textPrimary)

                HStack(spacing: NuvioTheme.spacing.md) {
                    swatch(palette.secondary, L10n.text("settings.appearance.swatch_accent", fallback: "Accent"))
                    swatch(palette.secondaryVariant, L10n.text("settings.appearance.swatch_pressed", fallback: "Pressed"))
                    swatch(palette.focusRing, L10n.text("settings.appearance.swatch_focus", fallback: "Focus"))
                    swatch(palette.backgroundCard, L10n.text("settings.appearance.swatch_card", fallback: "Card"))
                }

                // A real card in the real palette, because four squares do not answer the
                // question the viewer is actually asking.
                HStack(spacing: NuvioTheme.spacing.md) {
                    RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                        .fill(palette.backgroundCard)
                        .frame(width: dp(220), height: dp(96))
                        .overlay {
                            RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                                .strokeBorder(palette.focusRing, lineWidth: NuvioTheme.strokes.medium)
                        }
                        .overlay {
                            Text(L10n.text("settings.appearance.swatch_focused", fallback: "Focused"))
                                .nuvioText(NuvioTextStyles.cardTitle)
                                .foregroundStyle(colors.textPrimary)
                        }

                    Text(L10n.text("detail.play", fallback: "Play"))
                        .nuvioText(NuvioTextStyles.button)
                        .foregroundStyle(palette.onSecondary)
                        .padding(.horizontal, NuvioTheme.spacing.xl)
                        .frame(height: NuvioTheme.components.buttonHeight)
                        .background {
                            Capsule().fill(palette.secondary)
                        }
                }
            }
            .padding(NuvioTheme.spacing.lg)
            .id(server.revision)
        }
    }

    private func swatch(_ colour: Color, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
            RoundedRectangle(cornerRadius: NuvioTheme.radii.sm, style: .continuous)
                .fill(colour)
                .frame(width: dp(92), height: dp(52))
            Text(label)
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.textTertiary)
        }
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
            page: { CustomThemePage.html(accentHex: settings.app.customThemeAccentHex) },
            onSubmit: { fields in
                if fields["action"] == "reset" {
                    settings.app.customThemeAccentHex = CustomThemePalette.defaultHex
                    return
                }
                // A half-typed value leaves the previous theme standing rather than resolving to
                // black — the parser refuses it, and refusing is the whole point.
                guard let components = CustomThemePalette.components(
                    fromHex: fields["accent"] ?? ""
                ) else { return }
                settings.app.customThemeAccentHex = CustomThemePalette.hex(components)
            }
        )
    }
}
