import SwiftUI

// MARK: - Settings design system (port of SettingsDesignSystem.kt)

/// Rounded container used for every settings group.
struct SettingsCard<Content: View>: View {
    @Environment(\.nuvioColors) private var colors
    var title: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
            if let title {
                Text(title)
                    .nuvioText(NuvioTextStyles.tab)
                    .foregroundStyle(colors.textTertiary)
            }
            VStack(spacing: NuvioTheme.spacing.xs) {
                content
            }
            .padding(NuvioTheme.components.settings.workspacePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: NuvioTheme.components.settings.containerRadius, style: .continuous)
                    .fill(colors.backgroundCard)
            }
            if let footnote {
                Text(footnote)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(colors.textTertiary)
            }
        }
    }
}

/// A single settings row: label + optional detail, with the standard focus treatment.
struct SettingsRow<Trailing: View>: View {
    @Environment(\.nuvioColors) private var colors
    let title: String
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder var trailing: Trailing
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NuvioTheme.spacing.lg) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: NuvioTheme.sizes.icons.md))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: NuvioTheme.sizes.icons.lg)
                }
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                    Text(title)
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: NuvioTheme.spacing.lg)
                trailing
            }
            .padding(.horizontal, NuvioTheme.spacing.lg)
            .frame(minHeight: NuvioTheme.sizes.settings.rowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.components.settings.secondaryCardRadius, scaleOnFocus: false))
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, trailing: { EmptyView() }, action: action)
    }
}

/// Value indicator on the trailing edge of a row.
struct SettingsValueLabel: View {
    @Environment(\.nuvioColors) private var colors
    let value: String
    var chevron: Bool = true

    var body: some View {
        HStack(spacing: NuvioTheme.spacing.sm) {
            Text(value)
                .nuvioText(NuvioTextStyles.metadata)
                .foregroundStyle(colors.textSecondary)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: NuvioTheme.sizes.icons.xs, weight: .semibold))
                    .foregroundStyle(colors.textTertiary)
            }
        }
    }
}

/// Toggle styled like the Compose switch rows.
struct SettingsToggle: View {
    @Environment(\.nuvioColors) private var colors
    let title: String
    var subtitle: String?
    var systemImage: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            trailing: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? colors.secondary : colors.surfaceVariant)
                        .frame(width: dp(52), height: dp(30))
                    Circle()
                        .fill(.white)
                        .frame(width: dp(24), height: dp(24))
                        .padding(.horizontal, dp(3))
                }
                .animation(NuvioMotion.quickTween, value: isOn)
            },
            action: { isOn.toggle() }
        )
    }
}

// MARK: - Main settings screen (port of SettingsScreen.kt)

struct SettingsView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(SettingsStore.self) private var settings
    @Environment(AddonStore.self) private var addons
    @Environment(Router.self) private var router

    private enum Section: String, CaseIterable, Identifiable {
        case addons, appearance, layout, playback, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .addons: return "Addons"
            case .appearance: return "Appearance"
            case .layout: return "Layout"
            case .playback: return "Playback"
            case .about: return "About"
            }
        }

        var systemImage: String {
            switch self {
            case .addons: return "puzzlepiece.extension.fill"
            case .appearance: return "paintpalette.fill"
            case .layout: return "rectangle.3.group.fill"
            case .playback: return "play.rectangle.fill"
            case .about: return "info.circle.fill"
            }
        }
    }

    @State private var section: Section = .addons

    var body: some View {
        HStack(alignment: .top, spacing: NuvioTheme.spacing.xxl) {
            rail
            workspace
        }
        .padding(.horizontal, NuvioTheme.layout.tvSafeHorizontal)
        .padding(.vertical, NuvioTheme.layout.tvSafeVertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.background)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            Text("Settings")
                .nuvioText(NuvioTextStyles.headline)
                .foregroundStyle(colors.textPrimary)
                .padding(.bottom, NuvioTheme.spacing.md)

            ForEach(Section.allCases) { item in
                Button(action: { section = item }) {
                    HStack(spacing: NuvioTheme.spacing.md) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: NuvioTheme.sizes.icons.sm))
                            .frame(width: NuvioTheme.sizes.icons.lg)
                        Text(item.title)
                            .nuvioText(NuvioTextStyles.nav)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(section == item ? colors.textPrimary : colors.textSecondary)
                    .padding(.horizontal, NuvioTheme.spacing.lg)
                    .frame(height: NuvioTheme.sizes.settings.railItemHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NuvioRowButtonStyle(
                    cornerRadius: NuvioTheme.radii.full,
                    selected: section == item,
                    scaleOnFocus: false
                ))
            }
            Spacer(minLength: 0)
        }
        .frame(width: NuvioTheme.sizes.settings.railWidth, alignment: .leading)
        .focusSection()
    }

    private var workspace: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                switch section {
                case .addons: addonsSection
                case .appearance: ThemeSettingsContent()
                case .layout: LayoutSettingsContent()
                case .playback: PlaybackSettingsContent()
                case .about: AboutContent()
                }
            }
            .padding(.bottom, NuvioTheme.spacing.xxxl)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .focusSection()
    }

    private var addonsSection: some View {
        SettingsCard(title: "Stremio addons") {
            SettingsRow(
                title: "Addon Manager",
                subtitle: "\(addons.installed.count) installed · \(addons.enabledAddons.count) enabled",
                systemImage: "puzzlepiece.extension.fill",
                trailing: { SettingsValueLabel(value: "") },
                action: { router.push(.addonManager) }
            )
            SettingsRow(
                title: "Catalog Order",
                subtitle: "Choose which catalogs appear on Home and in what order",
                systemImage: "list.number",
                trailing: { SettingsValueLabel(value: "") },
                action: { router.push(.catalogOrder) }
            )
        }
    }
}

// MARK: - Standalone wrappers for pushed routes

struct ThemeSettingsView: View {
    var body: some View {
        NuvioScreenBackground {
            ScrollView { ThemeSettingsContent() }
                .scrollClipDisabled()
        }
    }
}

struct LayoutSettingsView: View {
    var body: some View {
        NuvioScreenBackground {
            ScrollView { LayoutSettingsContent() }
                .scrollClipDisabled()
        }
    }
}

struct PlaybackSettingsView: View {
    var body: some View {
        NuvioScreenBackground {
            ScrollView { PlaybackSettingsContent() }
                .scrollClipDisabled()
        }
    }
}

struct AboutView: View {
    var body: some View {
        NuvioScreenBackground {
            ScrollView { AboutContent() }
                .scrollClipDisabled()
        }
    }
}

// MARK: - Appearance (port of ThemeSettingsScreen)

struct ThemeSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Accent theme") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NuvioTheme.spacing.md) {
                        ForEach(AppTheme.allCases) { theme in
                            ThemeSwatch(
                                theme: theme,
                                isSelected: settings.theme == theme,
                                action: { settings.theme = theme }
                            )
                        }
                    }
                    .padding(.vertical, NuvioTheme.spacing.xs)
                }
                .scrollClipDisabled()
            }

            SettingsCard(title: "Typeface") {
                ForEach(AppFont.allCases) { font in
                    SettingsRow(
                        title: font.displayName,
                        subtitle: font == settings.font ? "Currently in use" : nil,
                        trailing: {
                            Image(systemName: settings.font == font ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(settings.font == font ? colors.secondary : colors.textTertiary)
                        },
                        action: { settings.font = font }
                    )
                }
            }

            SettingsCard(title: "Contrast", footnote: "AMOLED mode replaces the near-black background with pure black.") {
                SettingsToggle(
                    title: "AMOLED background",
                    subtitle: "Use pure black for the app background",
                    systemImage: "circle.lefthalf.filled",
                    isOn: $settings.amoledMode
                )
                SettingsToggle(
                    title: "AMOLED surfaces",
                    subtitle: "Also flatten cards and panels to pure black",
                    systemImage: "square.stack.3d.up",
                    isOn: $settings.amoledSurfaces
                )
            }
        }
    }
}

private struct ThemeSwatch: View {
    @Environment(\.nuvioColors) private var colors
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    private var palette: ThemeColorPalette { ThemeColors.palette(for: theme) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: NuvioTheme.spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                        .fill(palette.background)
                    Circle()
                        .fill(palette.secondary)
                        .frame(width: dp(34), height: dp(34))
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: dp(16), weight: .bold))
                            .foregroundStyle(palette.onSecondary)
                    }
                }
                .frame(width: dp(96), height: dp(64))
                .overlay {
                    RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                        .strokeBorder(isSelected ? palette.focusRing : .clear, lineWidth: NuvioTheme.strokes.medium)
                }

                Text(theme.displayName)
                    .nuvioText(NuvioTextStyles.metadata)
                    .foregroundStyle(isSelected ? colors.textPrimary : colors.textSecondary)
            }
        }
        .buttonStyle(NuvioCardButtonStyle(cornerRadius: NuvioTheme.radii.md, showsRing: true, elevated: false))
    }
}

// MARK: - Layout (port of LayoutSettingsScreen)

struct LayoutSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Home layout") {
                ForEach(HomeLayout.allCases) { layout in
                    SettingsRow(
                        title: layout.displayName,
                        subtitle: layout.summary,
                        systemImage: icon(for: layout),
                        trailing: {
                            Image(systemName: settings.homeLayout == layout ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(settings.homeLayout == layout ? colors.secondary : colors.textTertiary)
                        },
                        action: {
                            settings.homeLayout = layout
                            settings.layoutChosen = true
                        }
                    )
                }
            }

            SettingsCard(title: "Navigation") {
                SettingsToggle(
                    title: "Show Discover tab",
                    subtitle: "Browse every catalog your addons expose",
                    systemImage: "square.grid.2x2.fill",
                    isOn: $settings.showDiscoverTab
                )
            }

            SettingsCard(title: "Continue Watching") {
                ForEach(ContinueWatchingCardStyle.allCases) { style in
                    SettingsRow(
                        title: style.displayName,
                        subtitle: style == .landscape ? "Wide cards with progress" : "Poster cards with progress",
                        trailing: {
                            Image(systemName: settings.continueWatchingStyle == style ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(settings.continueWatchingStyle == style ? colors.secondary : colors.textTertiary)
                        },
                        action: { settings.continueWatchingStyle = style }
                    )
                }
            }
        }
    }

    private func icon(for layout: HomeLayout) -> String {
        switch layout {
        case .classic: return "rectangle.grid.1x2.fill"
        case .grid: return "square.grid.3x3.fill"
        case .modern: return "rectangle.inset.filled"
        }
    }
}

// MARK: - Playback (port of PlaybackSettingsScreen)

struct PlaybackSettingsContent: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(SettingsStore.self) private var settings

    private let qualities = ["2160p", "1080p", "720p", "480p", "Any"]

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Playback") {
                SettingsToggle(
                    title: "Auto-play next episode",
                    subtitle: "Continue to the next episode when one finishes",
                    systemImage: "forward.end.fill",
                    isOn: $settings.autoPlayNextEpisode
                )
                SettingsToggle(
                    title: "Skip intro button",
                    subtitle: "Offer a skip control when an intro is detected",
                    systemImage: "forward.fill",
                    isOn: $settings.skipIntroEnabled
                )
            }

            SettingsCard(
                title: "Preferred quality",
                footnote: "Sources are sorted so the closest match to this appears first."
            ) {
                ForEach(qualities, id: \.self) { quality in
                    SettingsRow(
                        title: quality,
                        trailing: {
                            Image(systemName: settings.preferredQuality == quality ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: NuvioTheme.sizes.icons.md))
                                .foregroundStyle(settings.preferredQuality == quality ? colors.secondary : colors.textTertiary)
                        },
                        action: { settings.preferredQuality = quality }
                    )
                }
            }

            SettingsCard(
                title: "Watched threshold",
                footnote: "How far through a video counts as finished: \(Int(settings.resumeThresholdPercent * 100))%."
            ) {
                HStack(spacing: NuvioTheme.spacing.md) {
                    ForEach([0.8, 0.85, 0.9, 0.95], id: \.self) { value in
                        NuvioChip(
                            label: "\(Int(value * 100))%",
                            isSelected: abs(settings.resumeThresholdPercent - value) < 0.001,
                            action: { settings.resumeThresholdPercent = value }
                        )
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, NuvioTheme.spacing.lg)
                .padding(.vertical, NuvioTheme.spacing.sm)
            }
        }
    }
}

// MARK: - About (port of AboutScreen)

struct AboutContent: View {
    @Environment(\.nuvioColors) private var colors

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
            SettingsCard(title: "Nuvio for Apple TV") {
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
                    Text("Nuvio")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)
                    Text("Version \(version)")
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                    Text("""
                    A tvOS client for the Stremio addon ecosystem, built to mirror the NuvioTV \
                    experience on Android TV. Nuvio is a playback interface only: it does not host, \
                    store or distribute any media. All content comes from the addons you install.
                    """)
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                        .frame(maxWidth: dp(720), alignment: .leading)
                }
                .padding(.horizontal, NuvioTheme.spacing.lg)
                .padding(.vertical, NuvioTheme.spacing.sm)
            }
        }
    }
}
