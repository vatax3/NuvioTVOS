import SwiftUI

/// Hands the custom poster URL to a phone, and keeps the per-screen switches on the television.
///
/// The split is deliberate. The pattern is unreadable and untypeable on a remote, so it goes to
/// the phone; the switches are six toggles that are faster to reach here than to walk to a browser
/// for — and they are the control a viewer actually changes twice, once the pattern is written.
struct CustomPosterView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AppSettings.self) private var settings

    @State private var server = LocalConfigServer()

    private var pattern: String { settings.layout.customPosterUrlPattern }

    private var enabledScreens: Set<CustomPosterScreen> {
        CustomPosterScreen.from(keys: settings.layout.customPosterEnabledScreens)
    }

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text(L10n.text("settings.poster.title", fallback: "Poster artwork"))
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    editorCard
                    patternCard
                    screensCard
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
        .task { start() }
        .onDisappear { server.stop() }
    }

    private var editorCard: some View {
        SettingsCard(title: L10n.text("settings.poster.edit_on_phone", fallback: "Edit on a phone")) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.lg) {
                Text(L10n.text(
                    "settings.poster.instructions",
                    fallback: """
                    This Apple TV is serving a page on your network. Scan the code with a phone on \
                    the same Wi-Fi, paste the URL there, and save. The page closes with this screen.
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

    /// What is stored, and whether it resolves. Shown here as well as on the phone because this is
    /// the screen a viewer comes back to when the posters did not change and they want to know why.
    private var patternCard: some View {
        SettingsCard(title: L10n.text("settings.poster.current", fallback: "Current pattern")) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
                if pattern.isEmpty {
                    Text(L10n.text(
                        "settings.poster.none",
                        fallback: "None — each addon's own artwork is used."
                    ))
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .foregroundStyle(colors.textTertiary)
                } else {
                    Text(pattern)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(CustomPosterPage.previews(pattern: pattern), id: \.label) { preview in
                        VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                            Text(preview.label)
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(colors.textTertiary)
                            Text(preview.resolved ?? L10n.text(
                                "settings.poster.unresolved",
                                fallback: "No URL — the addon's own poster is kept."
                            ))
                            .nuvioText(NuvioTextStyles.bodyCompact)
                            .foregroundStyle(
                                preview.resolved == nil ? colors.warning : colors.textSecondary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: dp(760), alignment: .leading)
            .padding(NuvioTheme.spacing.lg)
            // A save arriving from the phone is the whole point of the screen being open.
            .id(server.revision)
        }
    }

    private var screensCard: some View {
        SettingsCard(
            title: L10n.text("settings.poster.where", fallback: "Where it applies"),
            footnote: L10n.text(
                "settings.poster.where_footnote",
                fallback: "Each screen left on multiplies the requests to the service."
            )
        ) {
            VStack(spacing: 0) {
                ForEach(CustomPosterScreen.allCases, id: \.rawValue) { screen in
                    SettingsToggle(
                        title: screen.displayName,
                        isOn: Binding(
                            get: { enabledScreens.contains(screen) },
                            set: { setScreen(screen, enabled: $0) }
                        )
                    )
                }
            }
            .padding(.vertical, NuvioTheme.spacing.xs)
        }
    }

    /// Turning the last screen off would store an empty list, which `CustomPosterScreen.from`
    /// reads as *every* screen — so it is written as the full set minus that one instead. An
    /// upgrade has to read empty as "all"; a viewer switching everything off means none.
    private func setScreen(_ screen: CustomPosterScreen, enabled: Bool) {
        var screens = enabledScreens
        if enabled { screens.insert(screen) } else { screens.remove(screen) }
        settings.layout.customPosterEnabledScreens = screens.isEmpty
            ? ["none"]
            : CustomPosterScreen.allCases.filter(screens.contains).map(\.rawValue)
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
            // Rebuilt per request, so a phone that reloads sees what is stored rather than what
            // was on screen when this view opened.
            page: {
                CustomPosterPage.html(
                    pattern: settings.layout.customPosterUrlPattern,
                    screens: CustomPosterScreen.allCases.map {
                        ($0.rawValue, $0.displayName, enabledScreens.contains($0))
                    }
                )
            },
            onSubmit: { fields in
                if fields["action"] == "reset" {
                    settings.layout.customPosterUrlPattern = ""
                    return
                }
                settings.layout.customPosterUrlPattern = (fields["pattern"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // An unchecked box is absent from a form post rather than present and false, so
                // the whole set is rewritten from what did arrive.
                let chosen = CustomPosterScreen.allCases
                    .filter { fields["screen_\($0.rawValue)"] != nil }
                settings.layout.customPosterEnabledScreens = chosen.isEmpty
                    ? ["none"] : chosen.map(\.rawValue)
            }
        )
    }
}
