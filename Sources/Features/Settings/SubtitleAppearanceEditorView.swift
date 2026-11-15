import SwiftUI

/// Upstream's subtitle appearance editor (1.2.0-beta.1): every control that shapes a text
/// subtitle, in their order, with a preview drawn by the same overlay the player uses — so what
/// is set here is what plays. Fonts are imported from a phone through `LocalConfigServer`, as
/// upstream's font page does.
struct SubtitleAppearanceEditorView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings
    @State private var server = LocalConfigServer()
    @State private var fonts = SubtitleFontStore.shared

    var body: some View {
        @Bindable var player = settings.player
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text(L10n.text("settings.sub_appearance", fallback: "Subtitle Appearance"))
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)
                    Text(L10n.text(
                        "settings.sub_appearance_hint",
                        fallback: "Applies to text subtitles. Styled ASS and image subtitles keep their original appearance."
                    ))
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textSecondary)

                    preview
                    fontCard
                    textCard(player: player)
                    backgroundCard(player: player)
                    outlineAndShadowCard(player: player)
                    positionCard(player: player)
                    importCard
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
        .task { startServer() }
        .onDisappear { server.stop() }
    }

    // MARK: Preview

    /// `SubtitleAppearancePreview`: upstream's gradient backdrop and sample line.
    private var preview: some View {
        SettingsCard(title: L10n.text("settings.sub_preview", fallback: "Preview")) {
            ZStack {
                LinearGradient(
                    colors: [Color(argbHex: "#FF182A35"), Color(argbHex: "#FF53646B"), Color(argbHex: "#FF1C2934")],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                SubtitleOverlay(
                    cues: [SubtitleCue(
                        start: 0, end: 1,
                        text: L10n.text("settings.sub_preview_text", fallback: "Every story begins with a little curiosity.")
                    )],
                    style: settings.subtitleStyle
                )
            }
            .frame(height: dp(280))
            .clipShape(RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous))
            .padding(NuvioTheme.spacing.lg)
        }
    }

    // MARK: Font

    private var fontCard: some View {
        SettingsCard(title: L10n.text("player.sub_font", fallback: "Font")) {
            if SubtitleFontOptions.isMissing(settings.player.subtitleFontId) {
                Text(L10n.text(
                    "settings.sub_font_missing",
                    fallback: "Font unavailable on this device. Using the default font."
                ))
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.warning)
                .padding(.horizontal, NuvioTheme.spacing.lg)
            }
            ForEach(SubtitleFontOptions.ids(imported: fonts.fonts), id: \.self) { id in
                SettingsRow(
                    title: SubtitleFontOptions.label(for: id, imported: fonts.fonts),
                    systemImage: "textformat",
                    trailing: {
                        if settings.player.subtitleFontId == id {
                            Image(systemName: "checkmark").foregroundStyle(colors.secondary)
                        }
                    },
                    action: { settings.player.subtitleFontId = id }
                )
            }
            ForEach(fonts.fonts) { font in
                SettingsRow(
                    title: L10n.format("settings.sub_font_remove", fallback: "Remove %@", font.name),
                    systemImage: "trash",
                    trailing: { EmptyView() },
                    action: {
                        if settings.player.subtitleFontId == font.id {
                            settings.player.subtitleFontId = SubtitleFonts.defaultId
                        }
                        fonts.remove(font.id)
                    }
                )
            }
        }
    }

    // MARK: Text

    private func textCard(player: PlayerSettingsStore) -> some View {
        @Bindable var player = player
        return SettingsCard(title: L10n.text("settings.sub_text", fallback: "Text")) {
            SettingsDecimalStepperRow(
                title: L10n.text("player.sub_size", fallback: "Size"),
                value: $player.subtitleSize,
                range: 0.5...3.0,
                step: 0.1,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            SettingsToggle(
                title: L10n.text("settings.sub_bold", fallback: "Bold"),
                subtitle: L10n.text("settings.sub_bold_sub", fallback: "Use bold font weight for subtitles"),
                isOn: $player.subtitleBold
            )
            SettingsChipSelectRow(
                title: L10n.text("settings.sub_text_color", fallback: "Text Color"),
                chips: SubtitleColors.text.map { ($0.rgb, $0.title) },
                isSelected: { SubtitleColors.rgb(player.subtitleTextColor) == $0 },
                toggle: { player.subtitleTextColor = SubtitleColors.color($0, preservingAlphaFrom: player.subtitleTextColor) }
            )
            SettingsStepperRow(
                title: L10n.text("settings.sub_text_opacity", fallback: "Text Opacity"),
                value: percentBinding(\.subtitleTextColor, player: player, minimum: 10),
                range: 10...100, step: 10,
                format: { "\($0)%" }
            )
        }
    }

    // MARK: Background

    private func backgroundCard(player: PlayerSettingsStore) -> some View {
        @Bindable var player = player
        return SettingsCard(title: L10n.text("player.sub_background", fallback: "Background")) {
            SettingsChipSelectRow(
                title: L10n.text("settings.sub_bg_color", fallback: "Background Color"),
                chips: SubtitleColors.background.map { ($0.rgb, $0.title) },
                isSelected: { SubtitleColors.selectedBackground(player.subtitleBackgroundColor) == $0 },
                toggle: { player.subtitleBackgroundColor = SubtitleColors.background($0, current: player.subtitleBackgroundColor) }
            )
            SettingsStepperRow(
                title: L10n.text("settings.sub_bg_opacity", fallback: "Background Opacity"),
                value: percentBinding(\.subtitleBackgroundColor, player: player, minimum: 0),
                range: 0...100, step: 10,
                format: { "\($0)%" }
            )
            SettingsStepperRow(
                title: L10n.text("player.sub_bg_roundness", fallback: "Corner Roundness"),
                value: $player.subtitleBackgroundRadius,
                range: 0...SubtitleStyle.backgroundRadiusMax, step: 2
            )
        }
    }

    // MARK: Outline and shadow

    private func outlineAndShadowCard(player: PlayerSettingsStore) -> some View {
        @Bindable var player = player
        return SettingsCard(title: L10n.text("settings.sub_outline", fallback: "Outline")) {
            SettingsToggle(
                title: L10n.text("settings.sub_outline", fallback: "Outline"),
                subtitle: L10n.text("settings.sub_outline_sub", fallback: "Add outline around subtitle text for better visibility"),
                isOn: $player.subtitleOutlineEnabled
            )
            if player.subtitleOutlineEnabled {
                SettingsChipSelectRow(
                    title: L10n.text("settings.sub_outline_color", fallback: "Outline Color"),
                    chips: SubtitleColors.outline.map { ($0.rgb, $0.title) },
                    isSelected: { SubtitleColors.rgb(player.subtitleOutlineColor) == $0 },
                    toggle: { player.subtitleOutlineColor = SubtitleColors.color($0, preservingAlphaFrom: player.subtitleOutlineColor) }
                )
            }
            SettingsToggle(
                title: L10n.text("player.sub_shadow", fallback: "Drop Shadow"),
                subtitle: L10n.text("settings.sub_shadow_desc", fallback: "Separate the text from bright scenes"),
                isOn: $player.subtitleShadowEnabled
            )
            if player.subtitleShadowEnabled {
                SettingsStepperRow(
                    title: L10n.text("settings.sub_shadow_opacity", fallback: "Shadow Opacity"),
                    value: $player.subtitleShadowOpacity,
                    range: 0...100, step: 10,
                    format: { "\($0)%" }
                )
                SettingsStepperRow(
                    title: L10n.text("settings.sub_shadow_size", fallback: "Shadow Size"),
                    value: $player.subtitleShadowSize,
                    range: SubtitleStyle.shadowSizeRange
                )
            }
        }
    }

    // MARK: Position and reset

    private func positionCard(player: PlayerSettingsStore) -> some View {
        @Bindable var player = player
        return SettingsCard(title: L10n.text("settings.sub_vertical_offset", fallback: "Vertical Offset")) {
            SettingsDecimalStepperRow(
                title: L10n.text("settings.sub_vertical_offset", fallback: "Vertical Offset"),
                subtitle: L10n.text(
                    "settings.playback.vertical_offset_sub",
                    fallback: "Zero is where every other player puts them. Positive lifts."
                ),
                value: $player.subtitleVerticalOffset,
                range: SubtitlePlacement.offsetRange,
                step: 5,
                format: { String(format: "%+.0f", $0) }
            )
            SettingsRow(
                title: L10n.text("settings.sub_reset_appearance", fallback: "Reset Appearance"),
                systemImage: "arrow.counterclockwise",
                trailing: { EmptyView() },
                action: { player.resetSubtitleAppearance() }
            )
        }
    }

    // MARK: Import

    private var importCard: some View {
        SettingsCard(title: L10n.text("settings.sub_font_import", fallback: "Import from Phone")) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
                Text(L10n.text(
                    "settings.sub_font_import_desc",
                    fallback: "Add a .ttf or .otf font up to 10 MB. Imported fonts stay on this TV."
                ))
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textSecondary)
                if let failure = server.failure {
                    Text(failure)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.error)
                } else if let address = server.address {
                    HStack(alignment: .top, spacing: NuvioTheme.spacing.xl) {
                        if let image = QRCodeRenderer.image(for: address) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: dp(200), height: dp(200))
                                .padding(NuvioTheme.spacing.md)
                                .background {
                                    RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous).fill(.white)
                                }
                        }
                        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xs) {
                            Text(L10n.text(
                                "settings.sub_font_import_qr",
                                fallback: "Scan with your phone to add a .ttf or .otf font"
                            ))
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

    private func startServer() {
        server.start(
            page: { SubtitleFontPage.html() },
            upload: LocalConfigServer.Upload(path: "/api/font", maxBytes: SubtitleFonts.maxBytes) { name, data in
                (try? SubtitleFontStore.shared.importFont(fileName: name, data: data)) != nil
            }
        )
    }

    /// An `#AARRGGBB` colour's opacity as a whole percentage, for the steppers.
    private func percentBinding(
        _ keyPath: ReferenceWritableKeyPath<PlayerSettingsStore, String>,
        player: PlayerSettingsStore,
        minimum: Int
    ) -> Binding<Int> {
        Binding(
            get: { (SubtitleColors.alphaPercent(player[keyPath: keyPath]) / 10) * 10 },
            set: { player[keyPath: keyPath] = SubtitleColors.color(player[keyPath: keyPath], alphaPercent: max(minimum, $0)) }
        )
    }
}
